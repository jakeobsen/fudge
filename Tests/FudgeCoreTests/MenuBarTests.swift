import Foundation
import Testing

@testable import FudgeCore

/// Runs a mutating call where `#expect` can't: it takes its subject apart to show values, as an immutable copy.
private func step<T>(_ body: () -> T) -> T { body() }

private let action: JSONValue = .object(["$fn": .array([.string("onAction")])])

private func node(_ id: Int, _ type: String, _ props: [String: JSONValue] = [:], _ children: [UINode] = []) -> UINode {
    UINode(id: id, type: type, props: props, children: children)
}

private func json(_ node: UINode) -> JSONValue {
    .object([
        "id": .number(Double(node.id)), "type": .string(node.type), "props": .object(node.props),
        "children": .array(node.children.map(json)),
    ])
}

/// A MenuBarExtra with a heading, a section with an alternate and a shortcut, a separator and a submenu.
private func sample(title: String = "Add", isLoading: Bool = false) -> UINode {
    let alternate = node(9, "MenuBarExtra.Item", ["title": .string("Add Ten"), "onAction": action])
    return node(
        1, "MenuBarExtra", ["title": .string("3"), "tooltip": .string("Counter"), "isLoading": .bool(isLoading)],
        [
            node(2, "MenuBarExtra.Item", ["title": .string("Heading")]),
            node(
                3, "MenuBarExtra.Section", ["title": .string("Counter")],
                [
                    node(
                        4, "MenuBarExtra.Item",
                        [
                            "title": .string(title), "subtitle": .string("one"), "onAction": action,
                            "shortcut": .object(["modifiers": .array([.string("cmd")]), "key": .string("a")]),
                            "alternate": json(alternate),
                        ]),
                    node(5, "MenuBarExtra.Item", ["title": .string("Reset"), "onAction": action]),
                ]),
            node(6, "MenuBarExtra.Separator"),
            node(
                7, "MenuBarExtra.Submenu", ["title": .string("More")],
                [node(8, "MenuBarExtra.Item", ["title": .string("Deep"), "onAction": action])]),
        ])
}

// MARK: - The tree

@Test func aMenuBarExtraReadsIntoItemsSectionsSubmenusAndPaths() throws {
    let content = try #require(MenuBarContent(sample()))
    #expect(content.title == "3")
    #expect(content.tooltip == "Counter")
    #expect(!content.isLoading)
    #expect(!content.isEmpty)

    guard content.entries.count == 7,
        case .item(let heading) = content.entries[0],
        case .separator = content.entries[1],
        case .heading("Counter") = content.entries[2],
        case .item(let add) = content.entries[3],
        case .item(let reset) = content.entries[4],
        case .separator = content.entries[5],
        case .submenu(let more) = content.entries[6]
    else {
        Issue.record("unexpected entries: \(content.entries)")
        return
    }
    #expect(!heading.isEnabled, "an item without onAction is a disabled heading")
    #expect(heading.path == MenuBarPath([0]))

    #expect(add.isEnabled)
    #expect(add.path == MenuBarPath([1, 0]), "paths go through sections")
    #expect(add.subtitle == "one")
    #expect(add.shortcut == KeyShortcut(key: "a", modifiers: ["cmd"]))
    #expect(add.alternate?.title == "Add Ten")
    #expect(add.alternate?.node == 9)
    #expect(add.alternate?.path == MenuBarPath([1, 0], alternate: true))
    #expect(reset.path == MenuBarPath([1, 1]))

    #expect(more.title == "More")
    #expect(more.path == MenuBarPath([3]))
    guard case .item(let deep) = more.entries.first else {
        Issue.record("the submenu has no item")
        return
    }
    #expect(deep.path == MenuBarPath([3, 0]), "and through submenus")
}

@Test func sectionsAreSeparatedWithoutDoubleOrDanglingSeparators() throws {
    let sectioned = node(
        1, "MenuBarExtra", [:],
        [
            node(2, "MenuBarExtra.Section", [:], [node(3, "MenuBarExtra.Item", ["title": .string("A")])]),
            node(4, "MenuBarExtra.Separator"),
            node(5, "MenuBarExtra.Section", [:], [node(6, "MenuBarExtra.Item", ["title": .string("B")])]),
            node(7, "MenuBarExtra.Section", ["title": .string("")], []),
        ])
    let entries = try #require(MenuBarContent(sectioned)).entries
    #expect(entries.count == 3)
    #expect(entries[1] == .separator)
    if case .item(let a) = entries[0], case .item(let b) = entries[2] {
        #expect([a.title, b.title] == ["A", "B"])
    } else {
        Issue.record("unexpected entries: \(entries)")
    }
}

@Test func aMenuBarExtraWithNothingToShowIsEmpty() throws {
    #expect(MenuBarContent(nil) == nil, "a command that renders null shows no item")
    #expect(MenuBarContent(node(1, "List")) == nil)
    #expect(try #require(MenuBarContent(node(1, "MenuBarExtra"))).isEmpty)
    #expect(try #require(MenuBarContent(node(1, "MenuBarExtra", ["title": .string("")]))).isEmpty)
    #expect(try !#require(MenuBarContent(node(1, "MenuBarExtra", ["icon": .string("icon.png")]))).isEmpty)
    #expect(try !#require(MenuBarContent(node(1, "MenuBarExtra", ["title": .string("x")]))).isEmpty)
    let onlyItems = node(1, "MenuBarExtra", [:], [node(2, "MenuBarExtra.Item", ["title": .string("A")])])
    #expect(try !#require(MenuBarContent(onlyItems)).isEmpty)
}

@Test func aQueuedPickMatchesTheNewTreeByPathAndTitle() throws {
    let new = try #require(MenuBarContent(sample()))
    #expect(new.item(matching: MenuBarPath([1, 0]), title: "Add")?.node == 4, "same path and title")
    #expect(new.item(matching: MenuBarPath([1, 0], alternate: true), title: "Add Ten")?.node == 9)
    #expect(new.item(matching: MenuBarPath([3, 0]), title: "Deep")?.node == 8)
    #expect(new.item(matching: MenuBarPath([1, 0]), title: "Remove") == nil, "the title changed")
    #expect(new.item(matching: MenuBarPath([1, 5]), title: "Add") == nil, "the path is gone")
    #expect(new.item(matching: MenuBarPath([0]), title: "Heading") == nil, "a disabled item can't be picked")

    let renamed = try #require(MenuBarContent(sample(title: "Plus")))
    #expect(renamed.item(matching: MenuBarPath([1, 0]), title: "Add") == nil)
}

// MARK: - Intervals

@Test func intervalsAreReadWithATenSecondFloor() {
    #expect(MenuBarInterval.seconds("10s") == 10)
    #expect(MenuBarInterval.seconds("90s") == 90)
    #expect(MenuBarInterval.seconds("5m") == 300)
    #expect(MenuBarInterval.seconds("1h") == 3_600)
    #expect(MenuBarInterval.seconds(" 2D ") == 172_800)
    #expect(MenuBarInterval.seconds("1.5m") == 90)
    #expect(MenuBarInterval.seconds("1s") == 10, "below 10 s is raised to 10 s")
    #expect(MenuBarInterval.seconds("0s") == 10)
    #expect(MenuBarInterval.seconds(nil) == nil)
    #expect(MenuBarInterval.seconds("") == nil)
    #expect(MenuBarInterval.seconds("10") == nil)
    #expect(MenuBarInterval.seconds("10 minutes") == nil)
    #expect(MenuBarInterval.seconds("-5m") == nil)
}

@Test func theManifestCarriesTheInterval() throws {
    let manifest = try JSONDecoder().decode(
        ExtensionManifest.self,
        from: Data(
            #"{"name": "x", "commands": [{"name": "a", "title": "A", "mode": "menu-bar", "interval": "1m"}, {"name": "b", "title": "B", "interval": 5}]}"#
                .utf8))
    #expect(manifest.commands.map(\.interval) == ["1m", nil])
}

// MARK: - The store

@Test func theMenuBarStoreWritesReadsDeactivatesAndPrunes() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("nested/menu-bar.json")
    #expect(MenuBarStore.load(from: file) == MenuBarStore())

    var store = MenuBarStore()
    try store.activate("a/one")
    try store.activate("b/two")
    try store.activate("a/one")
    #expect(store.active == ["a/one", "b/two"], "activating an active command changes nothing")
    try store.save(to: file)
    #expect(MenuBarStore.load(from: file) == store)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String]]
    #expect(json == ["active": ["a/one", "b/two"]])

    #expect(step { store.deactivate("a/one") })
    #expect(!step { store.deactivate("a/one") })
    #expect(!store.isActive("a/one"))
    #expect(store.isActive("b/two"))

    var pruned = MenuBarStore(active: ["a/one", "gone/x", "b/two"])
    let dropped = pruned.prune(keeping: ["a/one", "b/two"])
    #expect(dropped)
    #expect(pruned.active == ["a/one", "b/two"])

    try Data(#"{"active": ["a/one", 3, "a/one", "c/three"]}"#.utf8).write(to: file)
    #expect(MenuBarStore.load(from: file).active == ["a/one", "c/three"], "read tolerantly, without duplicates")
    try Data("[]".utf8).write(to: file)
    #expect(MenuBarStore.load(from: file) == MenuBarStore())
}

@Test func atMostFiftyMenuBarItemsCanBeActive() throws {
    var store = MenuBarStore()
    for index in 0..<MenuBarStore.limit { try store.activate("x/c\(index)") }
    #expect(throws: MenuBarStore.LimitReached()) { try store.activate("x/c50") }
    #expect(store.active.count == 50)
    #expect(
        MenuBarStore.LimitReached().description
            == "fudge shows at most 50 menu bar items. Deactivate one first.")
    try store.activate("x/c0")
    store.deactivate("x/c1")
    try store.activate("x/c50")
    #expect(store.active.last == "x/c50")
}

// MARK: - Loading and unloading

@Test func aLoadedCommandIsntStartedTwice() {
    var lifecycle = MenuBarLifecycle()
    #expect(step { lifecycle.request(.startup) } == .launch(userInitiated: false))
    lifecycle.launched("s1", userInitiated: false)
    #expect(step { lifecycle.request(.interval) } == .alreadyLoaded, "a tick while loaded is skipped")
    #expect(step { lifecycle.request(.click) } == .alreadyLoaded, "a click while loaded just opens the menu")
    #expect(step { lifecycle.request(.rootSearch) } == .alreadyLoaded)
    #expect(step { lifecycle.request(.launchCommand(userInitiated: false)) } == .alreadyLoaded)
    #expect(lifecycle.session == "s1")
}

@Test func launchTypesFollowTheTrigger() {
    let types: [(MenuBarLifecycle.Trigger, Bool)] = [
        (.startup, false), (.interval, false), (.click, true), (.rootSearch, true),
        (.launchCommand(userInitiated: false), false), (.launchCommand(userInitiated: true), true),
    ]
    for (trigger, userInitiated) in types {
        var lifecycle = MenuBarLifecycle()
        #expect(step { lifecycle.request(trigger) } == .launch(userInitiated: userInitiated), "\(trigger)")
    }
}

@Test func aCommandUnloadsOnlyOnceItIsIdle() {
    var lifecycle = MenuBarLifecycle()
    lifecycle.launched("s1", userInitiated: true)
    lifecycle.menuOpened()
    #expect(step { lifecycle.takeUnload() } == nil, "not before its first render")

    #expect(step { lifecycle.rendered("s1", isLoading: true) })
    #expect(step { lifecycle.takeUnload() } == nil, "not while it's loading")
    #expect(step { lifecycle.rendered("s1", isLoading: false) })
    #expect(step { lifecycle.takeUnload() } == nil, "not while its menu is open")

    lifecycle.eventSent("s1")
    lifecycle.menuClosed()
    #expect(step { lifecycle.takeUnload() } == nil, "not while an onAction it started is running")
    lifecycle.eventSettled("s1")
    #expect(step { lifecycle.takeUnload() } == "s1")
    #expect(lifecycle.phase == .unloading(session: "s1"))
    #expect(step { lifecycle.takeUnload() } == nil, "once")
}

@Test func messagesFromAnotherSessionDontCount() {
    var lifecycle = MenuBarLifecycle()
    lifecycle.launched("s2", userInitiated: false)
    #expect(!step { lifecycle.rendered("s1", isLoading: false) })
    lifecycle.eventSent("s1")
    #expect(lifecycle.runningEvents == 0)
    #expect(step { lifecycle.exited("s1") } == nil)
    #expect(lifecycle.session == "s2")
    #expect(!lifecycle.isLive("s1"))
    #expect(!lifecycle.isLive("s2"), "nothing to pick from before the first render")
    #expect(step { lifecycle.rendered("s2", isLoading: false) })
    #expect(lifecycle.isLive("s2"))
}

@Test func aLaunchWhileUnloadingWaitsForTheExit() {
    var lifecycle = MenuBarLifecycle()
    lifecycle.launched("s1", userInitiated: false)
    _ = lifecycle.rendered("s1", isLoading: false)
    #expect(step { lifecycle.takeUnload() } == "s1")
    #expect(step { lifecycle.request(.interval) } == .queued)
    #expect(step { lifecycle.request(.click) } == .queued)
    #expect(step { lifecycle.request(.interval) } == .queued)
    #expect(lifecycle.queued == .click, "a UserInitiated launch outranks a Background one")
    #expect(step { lifecycle.exited("s1") } == .click)
    #expect(lifecycle.phase == .idle)
    #expect(lifecycle.queued == nil)
}

@Test func aBackgroundFailureMarksTheItemUntilALaterRenderSucceeds() {
    var lifecycle = MenuBarLifecycle()
    lifecycle.launched("s1", userInitiated: false)
    _ = lifecycle.rendered("s1", isLoading: true)
    lifecycle.menuOpened()
    #expect(!step { lifecycle.failed("s1") }, "a Background failure isn't shown in the HUD")
    #expect(lifecycle.lastRefreshFailed)
    #expect(!step { lifecycle.rendered("s1", isLoading: false) }, "React's unmount after the error isn't a render")
    #expect(step { lifecycle.takeUnload() } == "s1", "a failed instance is unloaded, even with its menu open")
    _ = lifecycle.exited("s1")

    lifecycle.launched("s2", userInitiated: true)
    #expect(lifecycle.lastRefreshFailed, "still marked until a render succeeds")
    #expect(step { lifecycle.rendered("s2", isLoading: false) })
    #expect(!lifecycle.lastRefreshFailed)
    #expect(step { lifecycle.failed("s2") }, "a UserInitiated failure shows in the HUD")
    #expect(!lifecycle.lastRefreshFailed, "and doesn't mark the item")
}

@Test func aCrashOrAFailedStartGoesBackToIdle() {
    var lifecycle = MenuBarLifecycle()
    lifecycle.launched("s1", userInitiated: true)
    #expect(step { lifecycle.exited("s1") } == nil)
    #expect(lifecycle.phase == .idle)
    #expect(step { lifecycle.request(.click) } == .launch(userInitiated: true))
    lifecycle.launchFailed()
    #expect(lifecycle.phase == .idle)
}
