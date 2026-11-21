import AppKit
import Foundation
import Testing

@testable import FudgeCore

// Search Menu Items (FUD-121), over made-up menus. Nothing here reads or presses a real app's menus.

private let app = MenuTarget(pid: 42, bundleID: "com.example.notes", name: "Notes Pro", path: "/Applications/Notes.app")

/// A made-up app: its own menu first (titled as the app gives it), then File, Edit and View.
private let menus: [FixedMenu] = [
    FixedMenu(
        "NotesPro",
        items: [
            FixedMenu("About Notes Pro"), FixedMenu(""),
            FixedMenu("Settings…", shortcut: MenuShortcut(character: ",")),
        ]),
    FixedMenu(
        "File",
        items: [
            FixedMenu("New Note", shortcut: MenuShortcut(character: "N")),
            FixedMenu("New Folder", shortcut: MenuShortcut(character: "N", modifiers: MenuShortcut.shift)),
            FixedMenu(""),
            FixedMenu(
                "Export",
                items: [
                    FixedMenu("As PDF…", shortcut: MenuShortcut(character: "E", modifiers: MenuShortcut.option)),
                    FixedMenu("As Text"),
                ]),
            FixedMenu("Print…", enabled: false, shortcut: MenuShortcut(character: "P")),
            FixedMenu("Share", enabled: false, items: [FixedMenu("Mail")]),
        ]),
    FixedMenu(
        "Edit",
        items: [
            FixedMenu("Delete", shortcut: MenuShortcut(glyph: 0x17)),
            FixedMenu("Find", items: [FixedMenu("Find…", shortcut: MenuShortcut(character: "F"))]),
        ]),
    FixedMenu("View", items: [FixedMenu("Hide Toolbar", shortcut: MenuShortcut(character: "T", modifiers: 0b1010))]),
]

private func read(_ system: FixedMenuSystem, deadline: Duration = .seconds(30)) throws -> MenuItemsListing {
    guard case .listing(let listing) = MenuItemsSearch(reader: MenuReader(system: system)).read(app, deadline: deadline)
    else { throw MenuTestError.noAnswer }
    return listing
}

private enum MenuTestError: Error {
    case noAnswer
}

// MARK: - Reading

@Test func everyEnabledLeafItemIsARowWithItsPath() throws {
    let listing = try read(FixedMenuSystem(menus: menus))
    #expect(listing.complete)
    #expect(
        listing.rows.map(\.title) == [
            "About Notes Pro", "Settings…", "New Note", "New Folder", "As PDF…", "As Text", "Delete", "Find…",
            "Hide Toolbar",
        ])
    // The Apple menu, separators, disabled items (and a disabled submenu's), and items with submenus aren't rows.
    let titles = Set(listing.rows.map(\.title))
    for left in ["About This Mac", "System Settings…", "", "Print…", "Share", "Mail", "Export", "Find"] {
        #expect(!titles.contains(left), "\(left)")
    }
    #expect(listing.rows[4].path == ["File", "Export"])
    #expect(listing.rows[4].subtitle == "File › Export ›")
    #expect(listing.rows[7].path == ["Edit", "Find"])
    // The app's own menu is shown by the app's name, not the title its menu bar gives it.
    #expect(listing.rows[0].path == ["Notes Pro"])
    #expect(listing.rows[1].subtitle == "Notes Pro ›")
}

@Test func keycapsFollowTheMenusModifiersAndKeys() throws {
    let listing = try read(FixedMenuSystem(menus: menus))
    let keycaps = Dictionary(uniqueKeysWithValues: listing.rows.map { ($0.title, $0.keycaps) })
    #expect(keycaps["New Note"] == ["⌘", "N"], "⌘ is implied")
    #expect(keycaps["New Folder"] == ["⇧", "⌘", "N"])
    #expect(keycaps["As PDF…"] == ["⌥", "⌘", "E"])
    #expect(keycaps["As Text"] == [], "no shortcut, no keycaps")
    #expect(keycaps["Delete"] == ["⌘", "⌫"], "a glyph key")
    #expect(keycaps["Hide Toolbar"] == ["⌥", "T"], "NoCommand (8) leaves ⌘ out")
}

@Test func keycapsCoverEveryModifierInMenuOrderAndKeysWithoutACharacter() {
    let all = MenuShortcut.shift | MenuShortcut.option | MenuShortcut.control
    #expect(MenuShortcut(character: "z", modifiers: all).keycaps == ["⌃", "⌥", "⇧", "⌘", "Z"])
    #expect(MenuShortcut(character: ",").keycaps == ["⌘", ","])
    #expect(MenuShortcut(character: " ").keycaps == ["⌘", "Space"])
    #expect(MenuShortcut(glyph: 0x73).keycaps == ["⌘", "F5"])
    #expect(MenuShortcut(glyph: 0x7A).keycaps == ["⌘", "F12"])
    #expect(MenuShortcut(glyph: 0x87).keycaps == ["⌘", "F13"])
    #expect(MenuShortcut(glyph: 0x92).keycaps == ["⌘", "F19"])
    #expect(MenuShortcut(modifiers: MenuShortcut.control, glyph: 0x64).keycaps == ["⌃", "⌘", "←"])
    #expect(MenuShortcut(modifiers: MenuShortcut.noCommand, glyph: 0x1B).keycaps == ["⎋"])
    // The glyph wins over the character the item also carries.
    #expect(MenuShortcut(character: "\u{8}", glyph: 0x17).keycaps == ["⌘", "⌫"])
    // AppKit's private-use characters for function keys, and a virtual key on its own.
    #expect(MenuShortcut(character: "\u{F704}").keycaps == ["⌘", "F1"])
    #expect(MenuShortcut(character: "\u{F701}").keycaps == ["⌘", "↓"])
    #expect(MenuShortcut(virtualKey: 0x60).keycaps == ["⌘", "F5"])
    // Nothing to show: no key, a control character, an unknown glyph or virtual key.
    #expect(MenuShortcut(modifiers: MenuShortcut.shift).keycaps == [])
    #expect(MenuShortcut(character: "\u{1}").keycaps == [])
    #expect(MenuShortcut(glyph: 0x5000).keycaps == [])
    #expect(MenuShortcut(virtualKey: 0x00).keycaps == [])
}

@Test func anAppThatDoesntAnswerIsSaidSo() {
    let system = FixedMenuSystem(menus: menus)
    system.answers = false
    guard case .noAnswer = MenuItemsSearch(reader: MenuReader(system: system)).read(app) else {
        Issue.record("expected no answer")
        return
    }
}

@Test func aReadStoppedAtItsDeadlineListsWhatItFound() throws {
    let system = FixedMenuSystem(menus: menus)
    let reachedEdit = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    system.onRead = { title in
        if title == "Edit" {
            reachedEdit.signal()
            release.wait()
        }
    }
    defer { release.signal() }
    let reader = MenuReader(system: system)
    let walk = reader.start(app.pid)
    #expect(reachedEdit.wait(timeout: .now() + 30) == .success)
    guard case .items(let items, let complete) = walk.finish(within: .zero) else {
        Issue.record("expected items")
        return
    }
    #expect(!complete)
    #expect(items.map(\.title) == ["About Notes Pro", "Settings…", "New Note", "New Folder", "As PDF…", "As Text"])
}

@Test func anAppStillBeingReadIsntAskedAgain() {
    let system = FixedMenuSystem(menus: menus)
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    system.onRead = { title in
        if title == "File" {
            reached.signal()
            release.wait()
        }
    }
    let reader = MenuReader(system: system)
    let first = reader.start(app.pid)
    #expect(reached.wait(timeout: .now() + 30) == .success)
    let readsBefore = system.reads
    guard case .noAnswer = reader.start(app.pid).finish(within: .seconds(30)) else {
        Issue.record("a hung app holds one read at most")
        release.signal()
        return
    }
    #expect(system.reads == readsBefore, "the second read asked nothing")
    release.signal()
    _ = first.finish(within: .seconds(30))
    // Once the first read has ended, the app is asked again.
    system.onRead = nil
    var ended = false
    for _ in 0..<300 where !ended {
        if case .items(_, true) = reader.start(app.pid).finish(within: .seconds(30)) {
            ended = true
        } else {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    #expect(ended)
}

// MARK: - Running

@Test func runningPressesTheItemRead() throws {
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    let row = try #require(listing.rows.firstIndex { $0.title == "As PDF…" })
    guard case .found(let press) = listing.item(row: row, in: app.pid) else {
        Issue.record("expected the item")
        return
    }
    #expect(press() == .pressed)
    #expect(system.pressed == ["As PDF…"])
}

@Test func aStaleItemIsFoundAgainByItsWholePathOnce() throws {
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    let row = try #require(listing.rows.firstIndex { $0.title == "As PDF…" })
    // The app rebuilds its menus: every element is new, the titles the same.
    system.rebuild(menus)
    guard case .found(let press) = listing.item(row: row, in: app.pid) else {
        Issue.record("found again by its path")
        return
    }
    #expect(press() == .pressed)
    #expect(system.pressed == ["As PDF…"])
}

@Test func aStaleItemThatsGoneOrMovedIsntRun() throws {
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    let pdf = try #require(listing.rows.firstIndex { $0.title == "As PDF…" })
    let toolbar = try #require(listing.rows.firstIndex { $0.title == "Hide Toolbar" })
    // "As PDF…" moves to another menu, and the toolbar item becomes "Show Toolbar": neither is the item listed.
    var rebuilt = menus
    rebuilt[1].items![3].items = [FixedMenu("As Text")]
    rebuilt[2].items!.append(FixedMenu("As PDF…"))
    rebuilt[3].items = [FixedMenu("Show Toolbar")]
    system.rebuild(rebuilt)
    for row in [pdf, toolbar] {
        guard case .gone = listing.item(row: row, in: app.pid) else {
            Issue.record("row \(row) should be gone")
            continue
        }
    }
    #expect(system.pressed.isEmpty)
}

@Test func aStaleItemIsFoundUnderAnyMenuWithThatTitle() throws {
    let twice: [FixedMenu] = [
        FixedMenu("App", items: [FixedMenu("About")]),
        FixedMenu("Go", items: [FixedMenu("Recent", items: [FixedMenu("First")])]),
        FixedMenu("Go", items: [FixedMenu("Recent", items: [FixedMenu("Second")])]),
    ]
    let system = FixedMenuSystem(menus: twice)
    let listing = try read(system)
    let row = try #require(listing.rows.firstIndex { $0.title == "Second" })
    system.rebuild(twice)
    guard case .found(let press) = listing.item(row: row, in: app.pid) else {
        Issue.record("the second Go › Recent holds it")
        return
    }
    #expect(press() == .pressed)
    #expect(system.pressed == ["Second"])
}

@Test func anItemPressedAfterTheMenusChangedSaysItsGone() throws {
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    guard case .found(let press) = listing.item(row: 2, in: app.pid) else {
        Issue.record("expected the item")
        return
    }
    system.rebuild(menus)
    #expect(press() == .gone)
    #expect(system.pressed.isEmpty)
}

@Test func anAppThatStopsAnsweringBeforeARunIsSaidSo() throws {
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    system.answers = false
    guard case .noAnswer = listing.item(row: 0, in: app.pid) else {
        Issue.record("expected no answer")
        return
    }
    guard case .gone = listing.item(row: listing.rows.count, in: app.pid) else {
        Issue.record("past the last row there's nothing")
        return
    }
}

// MARK: - The list

@Test func theListShowsTitlesPathsKeycapsAndTheAppsIcon() throws {
    let listing = try read(FixedMenuSystem(menus: menus))
    let view = MenuItemsList.view(rows: listing.rows, app: app, complete: true)
    let list = ListContent(view, searchText: "")
    #expect(list.items.count == listing.rows.count)
    let folder = try #require(list.items.first { $0.title == "New Folder" })
    #expect(folder.subtitle == "File ›")
    #expect(folder.icon == .object(["fileIcon": .string("/Applications/Notes.app")]))
    #expect(folder.accessories.map(\.keycaps) == [["⇧", "⌘", "N"]])
    let text = try #require(list.items.first { $0.title == "As Text" })
    #expect(text.accessories.isEmpty)
    #expect(view.string("navigationTitle") == MenuItemsList.title)
    #expect(
        MenuItemsList.view(rows: listing.rows, app: app, complete: false).string("navigationTitle")
            == MenuItemsList.incomplete)
}

@Test func searchMatchesTheTitleAndThePath() throws {
    let listing = try read(FixedMenuSystem(menus: menus))
    var list = ListContent(MenuItemsList.view(rows: listing.rows, app: app, complete: true), searchText: "")
    list.search("export pdf")
    #expect(list.items.first?.title == "As PDF…")
    list.search("file new")
    #expect(Array(list.items.map(\.title).prefix(2)) == ["New Note", "New Folder"])
    list.search("hide toolbar")
    #expect(list.items.first?.title == "Hide Toolbar")
    list.search("notes pro settings")
    #expect(list.items.first?.title == "Settings…")
}

@Test func onlyARowsRunActionRunsIt() throws {
    let listing = try read(FixedMenuSystem(menus: menus))
    let list = ListContent(MenuItemsList.view(rows: listing.rows, app: app, complete: true), searchText: "")
    let item = try #require(list.items.dropFirst(3).first)
    let entries = ActionPanelReader.sections(of: item.actions).flatMap(\.entries)
    #expect(entries.map(\.title) == ["Run Menu Item"])
    guard case .node(let node) = entries[0].target else {
        Issue.record("expected a node")
        return
    }
    #expect(MenuItemsList.target(of: node, rows: listing.rows.count) == .run(row: 3))
    #expect(MenuItemsList.target(of: item.id, rows: listing.rows.count) == nil, "the item itself runs nothing")
    #expect(MenuItemsList.target(of: node, rows: 3) == nil, "past the last row")
    #expect(MenuItemsList.itemNode(3) == item.id)
}

@Test func theListsOtherViewsSayWhyThereAreNoRows() throws {
    let accessibility = ListContent(MenuItemsList.accessibilityNeeded(), searchText: "")
    #expect(accessibility.emptyView?.title == AccessibilitySettingsAlert.title)
    let open = try #require(ActionPanelReader.sections(of: accessibility.emptyView?.actions).first?.entries.first)
    guard case .node(let openNode) = open.target else {
        Issue.record("expected a node")
        return
    }
    #expect(MenuItemsList.target(of: openNode, rows: 0) == .openAccessibilitySettings)

    let silent = ListContent(MenuItemsList.noAnswer(app: app), searchText: "")
    #expect(silent.emptyView?.title == "Notes Pro Didn't Answer")
    let again = try #require(ActionPanelReader.sections(of: silent.emptyView?.actions).first?.entries.first)
    guard case .node(let againNode) = again.target else {
        Issue.record("expected a node")
        return
    }
    #expect(MenuItemsList.target(of: againNode, rows: 0) == .tryAgain)

    #expect(ListContent(MenuItemsList.noApp(), searchText: "").emptyView?.title == "No App to Search")
    #expect(MenuItemsList.loading().bool("isLoading") == true)
    let none = ListContent(MenuItemsList.view(rows: [], app: app, complete: true), searchText: "")
    #expect(none.emptyView?.title == "No Menu Items")
}

@Test func fudgeItselfIsNeverSearched() {
    let fudge = MenuTarget(pid: 7, bundleID: "io.github.jakeobsen.fudge", name: "Fudge")
    #expect(MenuTarget.searched(frontmost: fudge, ownPid: 7) == nil)
    #expect(MenuTarget.searched(frontmost: app, ownPid: 7) == app)
    #expect(MenuTarget.searched(frontmost: nil, ownPid: 7) == nil)
}

@Test func theSelectionStaysOnTheSameItemWhenTheMenusAreReadAgain() {
    let old = [
        MenuItemsList.Row(title: "New", path: ["File"]), MenuItemsList.Row(title: "Open", path: ["File"]),
        MenuItemsList.Row(title: "Open", path: ["Go"]),
    ]
    let new = [
        MenuItemsList.Row(title: "Close", path: ["File"]), MenuItemsList.Row(title: "New", path: ["File"]),
        MenuItemsList.Row(title: "Open", path: ["Go"]), MenuItemsList.Row(title: "Open", path: ["File"]),
    ]
    #expect(MenuItemsList.place(of: 0, in: old, among: new) == 1)
    #expect(MenuItemsList.place(of: 1, in: old, among: new) == 3, "the whole path, not just the title")
    #expect(MenuItemsList.place(of: 2, in: old, among: new) == 2)
    #expect(MenuItemsList.place(of: 0, in: old, among: Array(new.dropFirst(2))) == nil)
    #expect(MenuItemsList.place(of: 5, in: old, among: new) == nil)
}

// MARK: - Menu titles stay in memory (the review's MUST)

@Test func rowsAreKnownByPlaceNeverByTitle() throws {
    let listing = try read(FixedMenuSystem(menus: menus))
    // The same places with other titles, paths and shortcuts.
    let other = listing.rows.enumerated().map { index, _ in
        MenuItemsList.Row(title: "Other \(index)", path: ["Somewhere"], keycaps: ["⌘", "K"])
    }
    let first = MenuItemsList.view(rows: listing.rows, app: app, complete: true)
    let second = MenuItemsList.view(rows: other, app: app, complete: true)
    func ids(_ node: UINode) -> [String] {
        var found = [String(node.id)]
        if case .string(let id) = node.props["id"] { found.append(id) }
        for key in node.props.keys.sorted() {
            if let inner = node.props[key].flatMap(UINode.init(json:)) { found += ids(inner) }
        }
        return found + node.children.flatMap(ids)
    }
    #expect(ids(first) == ids(second), "every id is the same for the same places")
    let titles = listing.rows.flatMap { [$0.title] + $0.path } + ["Notes Pro"]
    for id in ids(first) {
        for title in titles { #expect(!id.contains(title), "\(id) holds \(title)") }
    }
    let items = ListContent(first, searchText: "").items
    #expect(items.map(\.itemId) == items.indices.map { String($0) })
}

@Test func menuReadsCantBeWrittenAnywhere() {
    // Nothing of a read can be encoded, so nothing of it reaches a file, the history or the protocol.
    #expect(!(MenuItemsList.Row.self is any Encodable.Type))
    #expect(!(MenuItemsListing.self is any Encodable.Type))
    #expect(!(FoundMenuItem<FixedMenuHandle>.self is any Encodable.Type))
    #expect(!(MenuTarget.self is any Encodable.Type))
}

@Test func theCacheKeepsTheMostRecentlyReadApps() {
    var cache = MenuItemsCache<Int>()
    for number in 0..<10 { cache.set(number, for: "app-\(number)") }
    #expect(cache.keys.count == MenuItemsCache<Int>.limit)
    #expect(cache.value(for: "app-0") == nil, "the oldest went first")
    #expect(cache.value(for: "app-9") == 9)
    cache.set(20, for: "app-3")
    #expect(cache.keys.first == "app-3")
    #expect(cache.value(for: "app-3") == 20)
    #expect(cache.keys.count == MenuItemsCache<Int>.limit)
    #expect(app.cacheKey == "com.example.notes")
    #expect(MenuTarget(pid: 9, name: "Tool").cacheKey == "pid:9")
}

// MARK: - The command and the snapshot file

@Test func searchMenuItemsIsTheAppsGroupsCommand() throws {
    #expect(BuiltInCommandGroup.all.contains(.apps))
    let found = try #require(BuiltInCommandGroup.command(group: ":apps", command: MenuItemsList.commandName))
    #expect(found.command.title == "Search Menu Items")
    #expect(NSImage(systemSymbolName: found.command.symbol, accessibilityDescription: nil) != nil)
    #expect(BuiltInCommandGroup.commandIDs().contains(":apps/search-menu-items"))
    // Fudge's own session, never one the host could have started (`SessionID.make()` gives `s-…`).
    #expect(MenuItemsList.session.hasPrefix("fudge:"))
}

@Test func aSnapshotsMadeUpMenusComeFromAFile() throws {
    let json = """
        { "app": "TextEdit", "path": "/System/Applications/TextEdit.app",
          "menus": [
            { "title": "TextEdit", "items": [{ "title": "Settings…", "key": "," }] },
            { "title": "Format", "items": [
              { "title": "Font", "items": [{ "title": "Show Fonts", "key": "T" }] },
              { "title": "Make Plain Text", "key": "T", "modifiers": 1, "enabled": false },
              { "title": "Delete", "glyph": 23, "modifiers": 8 }
            ] }
          ] }
        """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("menus-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try #require(FixedMenuFile.load(url))
    #expect(file.target.name == "TextEdit")
    let search = MenuItemsSearch(reader: MenuReader(system: FixedMenuSystem(menus: file.menus)))
    guard case .listing(let listing) = search.read(file.target) else {
        Issue.record("expected a listing")
        return
    }
    #expect(listing.rows.map(\.title) == ["Settings…", "Show Fonts", "Delete"])
    #expect(listing.rows.map(\.keycaps) == [["⌘", ","], ["⌘", "T"], ["⌫"]])
    #expect(listing.rows[1].subtitle == "Format › Font ›")
}

@Test func theKeycapsAccessoryIsRead() {
    let item = UINode(
        id: 1, type: "List.Item",
        props: [
            "title": .string("Row"),
            "accessories": .array([.object(["keycaps": .array([.string("⌥"), .string("⌘"), .string("E")])])]),
        ])
    let list = ListContent(UINode(id: 0, type: "List", children: [item]), searchText: "")
    #expect(list.items.first?.accessories.map(\.keycaps) == [["⌥", "⌘", "E"]])
    #expect(list.items.first?.accessories.first?.text == nil)
}

// MARK: - Running, when the list may have gone (the review's REQUIRED item on #123)

/// What a run did, in order, and the list's lifetime, which dismissing moves on.
@MainActor
private final class RunProbe {
    var generation = MenuItemsGeneration()
    var done: [String] = []
}

/// Runs row `row` of `listing` as the launcher does: found off the main thread, current while `probe`'s generation is
/// the one the run started in.
@MainActor
private func runItem(_ row: Int, of listing: MenuItemsListing, probe: RunProbe) async -> MenuItemRun.Outcome {
    let started = probe.generation
    return await MenuItemRun.run(
        find: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: listing.item(row: row, in: app.pid)) }
            }
        },
        isCurrent: { probe.generation == started },
        hide: { probe.done.append("hide") },
        activate: { probe.done.append("activate") },
        press: { press in
            probe.done.append("press")
            return press()
        })
}

@MainActor
@Test func aRunDismissedWhileItsItemIsFoundDoesNothing() async throws {
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    let row = try #require(listing.rows.firstIndex { $0.title == "As PDF…" })
    let probe = RunProbe()
    // The app is slow to answer for the item; while it waits, the user dismisses the panel. Then it answers.
    let finding = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    system.onRead = { title in
        guard title == "As PDF…" else { return }
        finding.signal()
        release.wait()
    }
    Thread {
        finding.wait()
        Task { @MainActor in
            probe.generation.dismissed()
            release.signal()
        }
    }.start()
    let outcome = await runItem(row, of: listing, probe: probe)
    #expect(outcome == .dismissed)
    #expect(probe.done.isEmpty, "nothing hidden, activated or pressed")
    #expect(system.pressed.isEmpty)
}

@MainActor
@Test func aCurrentRunHidesActivatesThenPresses() async throws {
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    let row = try #require(listing.rows.firstIndex { $0.title == "New Folder" })
    let probe = RunProbe()
    #expect(await runItem(row, of: listing, probe: probe) == .pressed(.pressed))
    #expect(probe.done == ["hide", "activate", "press"])
    #expect(system.pressed == ["New Folder"])

    // Gone by the time it's found: nothing hidden or pressed; the launcher says so.
    var rebuilt = menus
    rebuilt[1].items!.removeAll { $0.title == "New Folder" }
    system.rebuild(rebuilt)
    let gone = RunProbe()
    #expect(await runItem(row, of: listing, probe: gone) == .gone)
    #expect(gone.done.isEmpty)
    var hidden = MenuItemsGeneration()
    let before = hidden
    hidden.dismissed()
    #expect(hidden != before)
}

// MARK: - Alike items, items turned off, and a dropped read (SPEC-107 §1)

/// Two windows titled alike under Window, as Terminal shows them.
private let alike: [FixedMenu] = [
    FixedMenu("Terminal", items: [FixedMenu("Settings…")]),
    FixedMenu("Window", items: [FixedMenu("Minimize"), FixedMenu("bash"), FixedMenu("bash")]),
]

@MainActor
@Test func alikeItemsArePressedByTheirPlaceAmongThem() async throws {
    let system = FixedMenuSystem(menus: alike)
    let listing = try read(system)
    let rows = listing.rows.indices.filter { listing.rows[$0].title == "bash" }
    #expect(rows.count == 2)
    // The app rebuilds its menus (new elements, same items): the second row presses the second "bash".
    system.rebuild(alike)
    #expect(await runItem(rows[1], of: listing, probe: RunProbe()) == .pressed(.pressed))
    #expect(system.pressedElements == [system.items(titled: "bash")[1]])
    // And the first row the first, after another rebuild.
    system.rebuild(alike)
    #expect(await runItem(rows[0], of: listing, probe: RunProbe()) == .pressed(.pressed))
    #expect(system.pressedElements.last == system.items(titled: "bash")[0])
}

@MainActor
@Test func whenAlikeItemsChangeInNumberNoneIsPressed() async throws {
    let system = FixedMenuSystem(menus: alike)
    let listing = try read(system)
    let rows = listing.rows.indices.filter { listing.rows[$0].title == "bash" }
    // The first of the two windows closed: the second row's place now points at nothing, and the first's at
    // another window.
    system.rebuild([alike[0], FixedMenu("Window", items: [FixedMenu("Minimize"), FixedMenu("bash")])])
    #expect(await runItem(rows[1], of: listing, probe: RunProbe()) == .gone)
    #expect(await runItem(rows[0], of: listing, probe: RunProbe()) == .gone)
    #expect(system.pressed.isEmpty)
}

@MainActor
@Test func anItemTurnedOffSinceTheReadIsntPressed() async throws {
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    let row = try #require(listing.rows.firstIndex { $0.title == "As PDF…" })
    system.setEnabled(false, titled: "As PDF…")
    let probe = RunProbe()
    #expect(await runItem(row, of: listing, probe: probe) == .disabled)
    #expect(probe.done.isEmpty, "nothing hidden, activated or pressed")
    // Found again by its path after a rebuild, still off.
    system.rebuild(menus)
    system.setEnabled(false, titled: "As PDF…")
    #expect(await runItem(row, of: listing, probe: probe) == .disabled)
    #expect(system.pressed.isEmpty)
    #expect(MenuItemsList.turnedOff == "That menu item is turned off right now.")
}

@MainActor
@Test func anItemWhoseStateTheAppDoesntGiveIsListedButNotPressed() async throws {
    let system = FixedMenuSystem(menus: menus)
    system.setEnabled(nil, titled: "As PDF…")
    let listing = try read(system)
    let row = try #require(
        listing.rows.firstIndex { $0.title == "As PDF…" }, "listed: only an item said to be off isn't")
    let probe = RunProbe()
    #expect(await runItem(row, of: listing, probe: probe) == .noAnswer)
    #expect(probe.done.isEmpty, "nothing hidden, activated or pressed")
    // Found again by its path, still unknown.
    system.rebuild(menus)
    system.setEnabled(nil, titled: "As PDF…")
    #expect(await runItem(row, of: listing, probe: probe) == .noAnswer)
    #expect(system.pressed.isEmpty)
}

@Test func aCancelledReadDoesntHoldUpTheNextOne() throws {
    let system = FixedMenuSystem(menus: menus)
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    system.onRead = { title in
        if title == "File" {
            reached.signal()
            release.wait()
        }
    }
    let search = MenuItemsSearch(reader: MenuReader(system: system))
    let cancel = MenuReadCancel()
    let dropped = Thread { _ = search.read(app, deadline: .seconds(30), cancel: cancel) }
    dropped.start()
    #expect(reached.wait(timeout: .now() + 30) == .success)
    // The list goes while the app is mid-answer: the read is cancelled. The list opens again at once.
    cancel.cancel()
    system.onRead = nil
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
    guard case .listing(let listing) = search.read(app, deadline: .seconds(30)) else {
        Issue.record("the new read waited for the cancelled one, rather than saying the app didn't answer")
        return
    }
    #expect(listing.rows.map(\.title).contains("As PDF…"))
}

// MARK: - Twins in another state at the read than at the press (SPEC-118 §2)

/// Three windows titled alike under Window, the first one's item turned on or off.
private func threeAlike(firstEnabled: Bool) -> [FixedMenu] {
    [
        alike[0],
        FixedMenu(
            "Window",
            items: [FixedMenu("Minimize")] + [firstEnabled, true, true].map { FixedMenu("bash", enabled: $0) }),
    ]
}

/// What the read found, with each item's place among its twins and their number.
private func found(_ system: FixedMenuSystem) throws -> [FoundMenuItem<FixedMenuHandle>] {
    guard case .items(let items, _) = MenuReader(system: system).start(app.pid).finish(within: .seconds(30)) else {
        throw MenuTestError.noAnswer
    }
    return items
}

@Test func everyTwinCountsWhateverItsStateButOnlyTheOnesNotOffAreListed() throws {
    let system = FixedMenuSystem(menus: threeAlike(firstEnabled: false))
    // The second's state is unknown (the app didn't say): listed, and counted.
    system.setEnabled(nil, element: system.items(titled: "bash")[1])
    let twins = try found(system).filter { $0.title == "bash" }
    #expect(twins.map(\.place) == [1, 2], "the first is off: not listed, but it holds place 0")
    #expect(twins.map(\.count) == [3, 3])
}

@MainActor
@Test func aTwinOffAtTheReadAndOnAtThePressLeavesTheOthersPressedByTheirPlace() async throws {
    let system = FixedMenuSystem(menus: threeAlike(firstEnabled: false))
    let listing = try read(system)
    let rows = listing.rows.indices.filter { listing.rows[$0].title == "bash" }
    try #require(rows.count == 2)
    // The first window's item comes on, and the app rebuilds its menus: each row still presses its own window.
    system.rebuild(threeAlike(firstEnabled: true))
    #expect(await runItem(rows[0], of: listing, probe: RunProbe()) == .pressed(.pressed))
    #expect(system.pressedElements == [system.items(titled: "bash")[1]])
    system.rebuild(threeAlike(firstEnabled: true))
    #expect(await runItem(rows[1], of: listing, probe: RunProbe()) == .pressed(.pressed))
    #expect(system.pressedElements.last == system.items(titled: "bash")[2])
}

@MainActor
@Test func aTwinOnAtTheReadAndOffAtThePressIsntPressedAndTheOthersAre() async throws {
    let system = FixedMenuSystem(menus: threeAlike(firstEnabled: true))
    let listing = try read(system)
    let rows = listing.rows.indices.filter { listing.rows[$0].title == "bash" }
    try #require(rows.count == 3)
    system.rebuild(threeAlike(firstEnabled: false))
    #expect(await runItem(rows[0], of: listing, probe: RunProbe()) == .disabled)
    #expect(await runItem(rows[1], of: listing, probe: RunProbe()) == .pressed(.pressed))
    #expect(system.pressedElements == [system.items(titled: "bash")[1]])
}

@MainActor
@Test func aTwinWhoseStateIsUnknownAtTheReadCountsAsATwin() async throws {
    let system = FixedMenuSystem(menus: alike)
    system.setEnabled(nil, element: system.items(titled: "bash")[0])
    let listing = try read(system)
    let rows = listing.rows.indices.filter { listing.rows[$0].title == "bash" }
    try #require(rows.count == 2, "an unknown state is listed")
    system.rebuild(alike)
    #expect(await runItem(rows[1], of: listing, probe: RunProbe()) == .pressed(.pressed))
    #expect(system.pressedElements == [system.items(titled: "bash")[1]])
}

@MainActor
@Test func whenATwinThatWasOffGoesTheNumberChangedAndNoneIsPressed() async throws {
    let system = FixedMenuSystem(menus: threeAlike(firstEnabled: false))
    let listing = try read(system)
    let rows = listing.rows.indices.filter { listing.rows[$0].title == "bash" }
    // The window whose item was off closed: two are left of the three the read counted, so each row's place may now
    // mean another window.
    system.rebuild([
        alike[0], FixedMenu("Window", items: [FixedMenu("Minimize"), FixedMenu("bash"), FixedMenu("bash")]),
    ])
    #expect(await runItem(rows[0], of: listing, probe: RunProbe()) == .gone)
    #expect(await runItem(rows[1], of: listing, probe: RunProbe()) == .gone)
    #expect(system.pressed.isEmpty)
}

@MainActor
@Test func aTwinInAMenuTurnedOffIsntCountedAtTheReadOrThePress() async throws {
    // Two Window menus, the second turned off: the read doesn't enter it, and neither does the press.
    let menus: [FixedMenu] = [
        alike[0], FixedMenu("Window", items: [FixedMenu("bash"), FixedMenu("bash")]),
        FixedMenu("Window", enabled: false, items: [FixedMenu("bash")]),
    ]
    let system = FixedMenuSystem(menus: menus)
    let listing = try read(system)
    let rows = listing.rows.indices.filter { listing.rows[$0].title == "bash" }
    try #require(rows.count == 2)
    system.rebuild(menus)
    #expect(await runItem(rows[1], of: listing, probe: RunProbe()) == .pressed(.pressed))
    #expect(system.pressedElements == [system.items(titled: "bash")[1]])
}
