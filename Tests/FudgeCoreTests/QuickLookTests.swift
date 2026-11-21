import Foundation
import Testing

@testable import FudgeCore

private func node(_ json: String) throws -> UINode {
    try JSONDecoder().decode(UINode.self, from: Data(json.utf8))
}

private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

private func read(_ json: String) throws -> QuickLookItem? {
    QuickLookItem.read(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), home: home)
}

// MARK: - Reading quickLook

@Test func readsAQuickLookPathAndItsTitle() throws {
    #expect(
        try read(#"{"path":"/Users/someone/Pictures/cat.png","name":"My Cat"}"#)
            == QuickLookItem(url: URL(fileURLWithPath: "/Users/someone/Pictures/cat.png"), title: "My Cat"))
    // Without a name, or with an empty or non-string one, the file's name.
    #expect(try read(#"{"path":"/tmp/report.pdf"}"#)?.title == "report.pdf")
    #expect(try read(#"{"path":"/tmp/report.pdf","name":""}"#)?.title == "report.pdf")
    #expect(try read(#"{"path":"/tmp/report.pdf","name":null}"#)?.title == "report.pdf")
    #expect(try read(#"{"path":"/tmp/report.pdf","name":3}"#)?.title == "report.pdf")
    // Paths are standardized.
    #expect(try read(#"{"path":"/tmp/./a/../b.txt"}"#)?.url == URL(fileURLWithPath: "/tmp/b.txt"))
}

@Test func aQuickLookPathCanStartWithATildeOrBeAFileURL() throws {
    #expect(try read(#"{"path":"~/Notes/todo.md"}"#)?.url == URL(fileURLWithPath: "/Users/someone/Notes/todo.md"))
    #expect(try read(#"{"path":"~"}"#)?.url.path == "/Users/someone")
    // A URL object arrives as its href, percent-encoded.
    let url = try read(#"{"path":"file:///tmp/a%20b/%C3%BC.txt"}"#)
    #expect(url == QuickLookItem(url: URL(fileURLWithPath: "/tmp/a b/ü.txt"), title: "ü.txt"))
    #expect(try read(#"{"path":"file://localhost/tmp/x.png"}"#)?.url == URL(fileURLWithPath: "/tmp/x.png"))
    #expect(try read(#"{"path":"FILE:///tmp/x.png"}"#)?.url == URL(fileURLWithPath: "/tmp/x.png"))
}

@Test func anythingElseIsNoQuickLook() throws {
    for json in [
        #"{"path":""}"#, #"{"path":"relative/file.png"}"#, #"{"path":"https://example.com/a.png"}"#,
        #"{"path":"file://server/share/a.png"}"#, #"{"path":"~someone/a.png"}"#, #"{"path":3}"#,
        #"{"path":null}"#, #"{"name":"x"}"#, #""/tmp/a.png""#, "null",
    ] {
        #expect(try read(json) == nil, "\(json)")
    }
    #expect(QuickLookItem.read(nil) == nil)
}

@Test func listAndGridItemsCarryTheirQuickLook() throws {
    let list = ListContent(
        try node(
            #"""
            {"id":1,"type":"List","props":{},"children":[
              {"id":2,"type":"List.Item","props":{"title":"a","quickLook":{"path":"/tmp/a.png","name":"A"}},"children":[]},
              {"id":3,"type":"List.Item","props":{"title":"b"},"children":[]},
              {"id":4,"type":"List.Item","props":{"title":"c","quickLook":{"path":"nope"}},"children":[]}
            ]}
            """#), searchText: "")
    #expect(
        list.items.map(\.quickLook) == [QuickLookItem(url: URL(fileURLWithPath: "/tmp/a.png"), title: "A"), nil, nil])

    let grid = ListContent(
        try node(
            #"""
            {"id":1,"type":"Grid","props":{},"children":[
              {"id":2,"type":"Grid.Item","props":{"content":"x","quickLook":{"path":"file:///tmp/g.png"}},"children":[]}
            ]}
            """#), searchText: "")
    #expect(grid.items.first?.quickLook == QuickLookItem(url: URL(fileURLWithPath: "/tmp/g.png"), title: "g.png"))
}

@Test func toggleQuickLookIsAnActionTheAppPerforms() throws {
    let panel = try node(
        #"""
        {"id":1,"type":"ActionPanel","props":{},"children":[
          {"id":2,"type":"Action","props":{"title":"Quick Look","fudgeBuiltIn":"toggleQuickLook",
            "shortcut":{"modifiers":["cmd"],"key":"y"}},"children":[]},
          {"id":3,"type":"Action","props":{"title":"Open","onAction":{"$fn":["onAction"]}},"children":[]},
          {"id":4,"type":"Action","props":{"title":"Other","fudgeBuiltIn":"somethingElse"},"children":[]}
        ]}
        """#)
    let entries = ActionPanelReader.flat(ActionPanelReader.sections(of: panel))
    #expect(entries.map(\.target) == [.toggleQuickLook, .node(3), .node(4)])
    #expect(entries[0].shortcut == KeyShortcut(key: "y", modifiers: ["cmd"]))
}

// MARK: - The state

private let png = QuickLookItem(url: URL(fileURLWithPath: "/tmp/a.png"), title: "a.png")
private let pdf = QuickLookItem(url: URL(fileURLWithPath: "/tmp/b.pdf"), title: "B")
private let gone = QuickLookItem(url: URL(fileURLWithPath: "/tmp/gone.txt"), title: "gone.txt")
private func exists(_ url: URL) -> Bool { url != gone.url }

/// Runs a mutating call outside `#expect`, which can't hold one.
private func step<T>(_ body: () -> T) -> T { body() }

@Test func toggleOpensTheSelectedItemsFileAndClosesIt() {
    var state = QuickLookState()
    #expect(!state.isOpen)
    #expect(step { state.toggle(selected: png, in: "s1/1", exists: exists) } == .opened)
    #expect(state.shown == png)
    #expect(step { state.toggle(selected: png, in: "s1/1", exists: exists) } == .closed)
    #expect(state.shown == nil)
    // Open again; a toggle closes it whatever is selected now.
    _ = state.toggle(selected: png, in: "s1/1", exists: exists)
    #expect(step { state.toggle(selected: nil, in: "s1/1", exists: exists) } == .closed)
}

@Test func toggleOpensNothingWithoutAFileToPreview() {
    var state = QuickLookState()
    #expect(step { state.toggle(selected: nil, in: "s1/1", exists: exists) } == .nothingToPreview)
    #expect(step { state.toggle(selected: gone, in: "s1/1", exists: exists) } == .missing("gone.txt"))
    #expect(!state.isOpen)
}

@Test func theOpenPreviewFollowsTheSelection() {
    var state = QuickLookState()
    state.follow(selected: pdf, in: "s1/1", exists: exists)
    #expect(!state.isOpen, "a closed preview stays closed")

    _ = state.toggle(selected: png, in: "s1/1", exists: exists)
    state.follow(selected: pdf, in: "s1/1", exists: exists)
    #expect(state.shown == pdf)
    state.follow(selected: pdf, in: "s1/1", exists: { _ in false })
    #expect(state.shown == pdf, "the same item stays, even if its file has gone since")
    state.follow(selected: nil, in: "s1/1", exists: exists)
    #expect(!state.isOpen, "an item without quickLook closes it")

    _ = state.toggle(selected: png, in: "s1/1", exists: exists)
    state.follow(selected: gone, in: "s1/1", exists: exists)
    #expect(!state.isOpen, "an item whose file doesn't exist closes it")
}

@Test func anotherViewClosesThePreview() {
    for other: String? in ["s1/2", "s2/1", nil] {
        var state = QuickLookState()
        _ = state.toggle(selected: png, in: "s1/1", exists: exists)
        state.follow(selected: png, in: other, exists: exists)
        #expect(!state.isOpen, "\(other ?? "root search")")
        // And the next toggle opens it in the new view.
        #expect(step { state.toggle(selected: pdf, in: other, exists: exists) } == .opened)
    }
}

@Test func closingIsEscTheLauncherHidingOrTheUsersOwnClose() {
    var state = QuickLookState()
    _ = state.toggle(selected: png, in: "s1/1", exists: exists)
    state.close()
    #expect(!state.isOpen)
    #expect(step { state.toggle(selected: png, in: "s1/1", exists: exists) } == .opened, "the next toggle opens it")
}

@Test(arguments: EscapeBehavior.allCases)
func escClosesQuickLookAfterThePopoversAndDoesNothingElse(behavior: EscapeBehavior) {
    let screens: [EscapeAction.State.Screen] = [
        .command(depth: 1, searchEmpty: true, isForm: false), .command(depth: 2, searchEmpty: false, isForm: false),
        .command(depth: 1, searchEmpty: true, isForm: true),
    ]
    for screen in screens {
        #expect(
            EscapeAction.next(behavior: behavior, state: .init(quickLookOpen: true, screen: screen)) == .closeQuickLook)
        #expect(
            EscapeAction.next(behavior: behavior, state: .init(dropdownOpen: true, quickLookOpen: true, screen: screen))
                == .closeDropdown)
        #expect(
            EscapeAction.next(
                behavior: behavior, state: .init(actionPanelOpen: true, quickLookOpen: true, screen: screen))
                == .closeActionPanel)
    }
}

@Test func theLauncherStaysWhenTheQuickLookPreviewTakesTheKeyboard() {
    #expect(LauncherResign.decide(sheetAttached: false, quickLookTookKey: false) == .hide)
    #expect(LauncherResign.decide(sheetAttached: true, quickLookTookKey: false) == .stay)
    #expect(LauncherResign.decide(sheetAttached: false, quickLookTookKey: true) == .takeKeyBack)
    #expect(LauncherResign.decide(sheetAttached: true, quickLookTookKey: true) == .stay)
}
