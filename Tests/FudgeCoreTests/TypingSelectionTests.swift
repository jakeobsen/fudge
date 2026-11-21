import Foundation
import Testing

@testable import FudgeCore

/// A `filtering={false}` List whose items are `(node id, id prop)`.
private func list(_ items: [(Int, String)], loading: Bool = false) throws -> ListContent {
    let children = items.map { node, id in
        #"{"id":\#(node),"type":"List.Item","props":{"id":"\#(id)","title":"\#(id)"},"children":[]}"#
    }
    let json = #"""
        {"id":1,"type":"List","props":{"filtering":false,"isLoading":\#(loading),"onSearchTextChange":{"$fn":["onSearchTextChange"]}},
        "children":[\#(children.joined(separator: ","))]}
        """#
    return ListContent(try JSONDecoder().decode(UINode.self, from: Data(json.utf8)), searchText: "")
}

/// What `LauncherModel` does with the selection: typing, telling the extension, renders, the user's moves.
private struct FakeApp {
    var list: ListContent
    var selected: Int?
    var followed: String?
    var typing = TypingSelection()

    init(_ list: ListContent) {
        self.list = list
        selected = list.items.first?.id
    }

    /// The user types: the first item it has is selected at once; a throttled search tells the extension later.
    mutating func type(told: Bool = true) {
        selected = list.items.first?.id
        typing.typed()
        if told { tell() }
    }

    /// A throttled search's text goes out.
    mutating func tell() {
        typing.told(items: list.items.map(\.id))
    }

    mutating func render(_ next: ListContent, selectedItemId: String? = nil) {
        let previous = list.items.first { $0.id == selected }
        let typed = typing.rendered(items: next.items.map(\.id))
        let selection = next.selection(
            selectedItemId: selectedItemId, followed: followed, selectFirst: typed, node: selected,
            itemId: previous?.itemId)
        list = next
        selected = selection.node
        followed = selection.followed
    }

    mutating func select(_ node: Int) {
        selected = node
        typing.cancel()
    }
}

struct TypingSelectionTests {
    // The empty search's results, and "report"'s: the old first file (node 10) is third now.
    let before = [(10, "a.txt"), (11, "b.txt"), (12, "c.txt")]
    let after = [(20, "report.pdf"), (21, "report-2.pdf"), (10, "a.txt")]

    /// FUD-107: the results of what the user typed select their first item, even when the item selected before is
    /// still among them.
    @Test func theResultsOfTypingSelectTheirFirstItem() throws {
        var app = FakeApp(try list(before))
        app.type()
        // The extension marks itself loading, with the old items: nothing moves yet.
        app.render(try list(before, loading: true))
        #expect(app.selected == 10)
        app.render(try list(after))
        #expect(app.selected == 20)
    }

    /// The same items in another order are new results too.
    @Test func reorderedItemsAreNewResults() throws {
        var app = FakeApp(try list(before))
        app.select(12)
        app.type()
        app.render(try list([(12, "c.txt"), (10, "a.txt"), (11, "b.txt")]))
        #expect(app.selected == 12, "the first item")
    }

    /// With `throttle`, the text goes out 250 ms later. A render the extension sent before (the empty search's own
    /// results arriving late) is left alone, and the results of the typed text still select their first item.
    @Test func aRenderBeforeTheExtensionHeardTheTextDoesntCount() throws {
        var app = FakeApp(try list([], loading: true))
        app.type(told: false)
        app.render(try list(before))  // the empty search's results, late
        app.select(11)
        #expect(!app.typing.isWaiting, "the user picked from those")
        // Typing again, throttled, then the late render of the old query comes first.
        app.type(told: false)
        app.render(try list(before))
        #expect(app.typing.isWaiting)
        app.tell()
        app.render(try list(after))
        #expect(app.selected == 20)
    }

    /// Renders that don't follow typing keep the selection: an update, an accessory changing, a loading flag.
    @Test func otherRendersKeepTheSelection() throws {
        var app = FakeApp(try list(before))
        app.select(11)
        app.render(try list(before, loading: true))
        app.render(try list([(11, "b.txt"), (10, "a.txt"), (12, "c.txt")]))
        #expect(app.selected == 11)
        // After typing's results came, later renders keep the selection too: the reset is once.
        app.type()
        app.render(try list(after))
        app.select(21)
        app.render(try list([(30, "new.pdf")] + after))
        #expect(app.selected == 21)
    }

    /// A page appended after the user asked for more (`onLoadMore`) never moves the selection.
    @Test func aNextPageKeepsTheSelection() throws {
        var app = FakeApp(try list(before))
        app.type()
        app.select(12)  // the user moved, scrolling to the end, then the app asked for the next page
        app.typing.cancel()
        app.render(try list(before + [(13, "d.txt"), (14, "e.txt")]))
        #expect(app.selected == 12)
    }

    /// The user moving the selection after typing, before the results come, keeps what they picked when it's there.
    @Test func aMoveAfterTypingKeepsWhatTheUserPicked() throws {
        var app = FakeApp(try list(before))
        app.type()
        app.select(10)
        app.render(try list(after))
        #expect(app.selected == 10)
    }

    /// The extension's `selectedItemId` wins over typing's reset.
    @Test func selectedItemIdWins() throws {
        var app = FakeApp(try list(before))
        app.type()
        app.render(try list(after), selectedItemId: "a.txt")
        #expect(app.selected == 10)
        #expect(app.followed == "a.txt")
    }
}
