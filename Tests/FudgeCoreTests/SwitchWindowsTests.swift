import CoreGraphics
import Foundation
import Testing

@testable import FudgeCore

// Switch Windows (FUD-120). A fake system: these tests never read, raise, close or quit a real window or app.

private final class FakeSwitch: WindowSwitchSystem, @unchecked Sendable {
    typealias Handle = Int

    var appList: [SwitcherApp] = []
    var recent: [Int32] = []
    var frontmost: Int32?
    var listed: [ListedWindow] = []
    var screenList = [NamedScreen(name: "Built-in Display", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))]
    var ax: [Int32: [SwitchableWindow<Int>]] = [:]
    /// Apps whose read says they didn't answer.
    var silent: Set<Int32> = []
    /// Apps whose read waits until the semaphore is signalled, or 5 s.
    var slow: [Int32: DispatchSemaphore] = [:]
    /// Apps whose read, as it starts, signals the semaphore.
    var signals: [Int32: DispatchSemaphore] = [:]
    /// Actions that throw.
    var refusing: Set<String> = []
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedReads: [Int32] = []

    var calls: [String] { lock.withLock { recordedCalls } }
    var reads: [Int32] { lock.withLock { recordedReads } }

    func apps() -> [SwitcherApp] { appList }
    func recentlyActive() -> [Int32] { recent }
    func frontmostPid() -> Int32? { frontmost }
    func listedWindows() -> [ListedWindow] { listed }
    func screens() -> [NamedScreen] { screenList }

    func windows(of pid: Int32) -> AppWindowsRead<Int> {
        lock.withLock { recordedReads.append(pid) }
        signals[pid]?.signal()
        _ = slow[pid]?.wait(timeout: .now() + 5)
        return silent.contains(pid) ? .noAnswer : .answered(ax[pid] ?? [])
    }

    private func record(_ call: String) throws {
        lock.withLock { recordedCalls.append(call) }
        if let name = call.split(separator: " ").first, refusing.contains(String(name)) {
            throw WindowManagementError.failed("\(name) refused")
        }
    }

    func unminimize(_ window: Int) throws { try record("unminimize \(window)") }
    func raise(_ window: Int) throws { try record("raise \(window)") }
    func activate(pid: Int32) throws { try record("activate \(pid)") }
    func close(_ window: Int) throws { try record("close \(window)") }

    func terminate(pid: Int32) -> Bool {
        try? record("terminate \(pid)")
        return true
    }
}

private let me: Int32 = 100
private let textEdit: Int32 = 200
private let safari: Int32 = 300
private let mail: Int32 = 400
private let notes: Int32 = 500

private let editor = CGRect(x: 100, y: 80, width: 800, height: 600)
private let browser = CGRect(x: 200, y: 50, width: 1000, height: 800)
private let inbox = CGRect(x: 300, y: 120, width: 900, height: 700)
private let docs = CGRect(x: 400, y: 300, width: 600, height: 400)
private let fonts = CGRect(x: 950, y: 100, width: 250, height: 400)

/// On screen, front to back: TextEdit's Notes.txt (focused, TextEdit frontmost), Safari's Start Page, Mail's Inbox,
/// a window of Fudge's own, Safari's Docs, TextEdit's Fonts panel, and a menu bar extra. Minimized: Safari's Recipes
/// and Notes' Groceries. Mail also has a sheet. Notes was active more recently than Safari, Safari than Mail.
private func desk() -> FakeSwitch {
    let system = FakeSwitch()
    system.appList = [
        SwitcherApp(pid: me, name: "Fudge"),
        SwitcherApp(pid: mail, name: "Mail", path: "/System/Applications/Mail.app"),
        SwitcherApp(pid: safari, name: "Safari", path: "/Applications/Safari.app"),
        SwitcherApp(pid: textEdit, name: "TextEdit", path: "/System/Applications/TextEdit.app"),
        SwitcherApp(pid: notes, name: "Notes", path: "/System/Applications/Notes.app"),
    ]
    system.recent = [textEdit, notes, safari, mail]
    system.frontmost = textEdit
    system.listed = [
        ListedWindow(number: 5, pid: textEdit, layer: 25, bounds: CGRect(x: 1300, y: 0, width: 30, height: 24)),
        ListedWindow(number: 11, pid: textEdit, bounds: editor),
        ListedWindow(number: 12, pid: safari, bounds: browser),
        ListedWindow(number: 13, pid: mail, bounds: inbox),
        ListedWindow(number: 7, pid: me, bounds: CGRect(x: 400, y: 200, width: 750, height: 475)),
        ListedWindow(number: 14, pid: safari, bounds: docs),
        ListedWindow(number: 15, pid: textEdit, bounds: fonts),
    ]
    system.ax = [
        me: [SwitchableWindow(handle: 70, title: "Fudge", frame: CGRect(x: 400, y: 200, width: 750, height: 475))],
        textEdit: [
            SwitchableWindow(handle: 1, title: "Notes.txt", frame: editor, focused: true),
            SwitchableWindow(handle: 2, title: "Fonts", frame: fonts, standard: false),
        ],
        safari: [
            SwitchableWindow(handle: 3, title: "Start Page", frame: browser),
            SwitchableWindow(handle: 4, title: "Docs", frame: docs),
            SwitchableWindow(handle: 5, title: "Recipes", frame: browser, minimized: true),
        ],
        mail: [
            SwitchableWindow(handle: 6, title: "Inbox", frame: inbox),
            SwitchableWindow(handle: 7, title: "Save?", frame: inbox, standard: false),
        ],
        notes: [SwitchableWindow(handle: 8, title: "Groceries", frame: editor, minimized: true)],
    ]
    return system
}

private func switcher(_ system: FakeSwitch, inFlight: WindowReadsInFlight = WindowReadsInFlight())
    -> WindowSwitcher<FakeSwitch>
{
    WindowSwitcher(system: system, ownPid: me, inFlight: inFlight)
}

private func titles(_ listing: SwitcherListing<Int>) -> [String] {
    listing.windows.map(\.row.title)
}

// MARK: - What's listed, and in which order

@Test func theWindowYouWereInComesSecondAfterTheOneBehindIt() {
    // On screen front to back would be [z1 Notes.txt, z2 Start Page, z3 Inbox, z4 Docs]; then the rest by app, most
    // recently active first: Notes' Groceries, then Safari's Recipes. The window the user was in, z1, comes second.
    let listing = switcher(desk()).read()
    #expect(titles(listing) == ["Start Page", "Notes.txt", "Inbox", "Docs", "Groceries", "Recipes"])
    #expect(listing.windows.map(\.handle) == [3, 1, 6, 4, 8, 5])
    #expect(listing.silentApps.isEmpty)
}

@Test func theWindowYouWereInMovesToSecondFromWhereverItIs() {
    let system = desk()
    system.frontmost = mail
    system.recent = [mail, textEdit, notes, safari]
    #expect(titles(switcher(system).read()) == ["Notes.txt", "Inbox", "Start Page", "Docs", "Groceries", "Recipes"])
}

@Test func withoutAFocusedStandardWindowTheFrontmostAppsFrontWindowIsTheOneYouWereIn() {
    // TextEdit's Fonts panel has the keyboard: the user was in its Notes.txt, which still comes second.
    let system = desk()
    system.ax[textEdit]?[0].focused = false
    system.ax[textEdit]?[1].focused = true
    #expect(titles(switcher(system).read()).prefix(2) == ["Start Page", "Notes.txt"])
}

@Test func withNoWindowOfTheFrontmostAppTheOrderStays() {
    let system = desk()
    system.frontmost = 999
    #expect(titles(switcher(system).read()).prefix(3) == ["Notes.txt", "Start Page", "Inbox"])
    system.frontmost = notes  // its only window is minimized: it isn't the one the user was in
    #expect(titles(switcher(system).read()).prefix(3) == ["Notes.txt", "Start Page", "Inbox"])
}

@Test func aLoneWindowStaysFirst() {
    let system = FakeSwitch()
    system.appList = [SwitcherApp(pid: textEdit, name: "TextEdit")]
    system.frontmost = textEdit
    system.listed = [ListedWindow(number: 11, pid: textEdit, bounds: editor)]
    system.ax = [textEdit: [SwitchableWindow(handle: 1, title: "Notes.txt", frame: editor, focused: true)]]
    #expect(titles(switcher(system).read()) == ["Notes.txt"])
}

@Test func onlyStandardWindowsOfOtherAppsAreListed() {
    let listing = switcher(desk()).read()
    let handles = Set(listing.windows.map(\.handle))
    #expect(!handles.contains(70), "Fudge's own window")
    #expect(!handles.contains(2) && !handles.contains(7), "a panel and a sheet")
    #expect(!listing.windows.contains { $0.app.pid == me })
}

@Test func appsWithNoWindowOnScreenFollowTheMostRecentlyActive() {
    let system = desk()
    system.recent = [textEdit, safari, notes, mail]
    #expect(titles(switcher(system).read()).suffix(2) == ["Recipes", "Groceries"])
    // Apps Fudge hasn't seen become active: by their front window on screen, then as the system lists them.
    system.recent = []
    system.frontmost = nil
    #expect(titles(switcher(system).read()) == ["Notes.txt", "Start Page", "Inbox", "Docs", "Recipes", "Groceries"])
}

@Test func aWindowTheWindowListCantPairIsListedWithItsAppsOthers() {
    let system = desk()
    // Safari's Docs moved since the window list was read: it's no longer paired, so it's listed after those on screen.
    system.ax[safari]?[1].frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    #expect(titles(switcher(system).read()) == ["Start Page", "Notes.txt", "Inbox", "Groceries", "Docs", "Recipes"])
}

@Test func eachRowShowsTheTitleTheAppAndMinimizedOrTheScreen() {
    let system = desk()
    system.ax[mail]?[0].title = ""
    var rows = switcher(system).read().windows.map(\.row)
    #expect(
        rows[0] == SwitchWindowsList.Row(title: "Start Page", appName: "Safari", appPath: "/Applications/Safari.app"))
    #expect(rows[2].title == "Mail", "an untitled window shows its app's name")
    #expect(rows[2].appName == "Mail")
    #expect(rows.map(\.accessory) == [nil, nil, nil, nil, "Minimized", "Minimized"], "one screen: no screen names")

    system.screenList = [
        NamedScreen(name: "Built-in Display", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        NamedScreen(name: "Studio Display", bounds: CGRect(x: 1440, y: 0, width: 2560, height: 1440)),
    ]
    system.ax[safari]?[1].frame = CGRect(x: 1500, y: 100, width: 600, height: 400)
    system.listed[5].bounds = CGRect(x: 1500, y: 100, width: 600, height: 400)
    rows = switcher(system).read().windows.map(\.row)
    #expect(
        rows.map(\.accessory) == [
            "Built-in Display", "Built-in Display", "Built-in Display", "Studio Display", "Minimized", "Minimized",
        ])
}

// MARK: - Apps that don't answer

@Test func anAppThatDoesntAnswerIsLeftOutAndNamedInTheFooter() {
    let system = desk()
    system.silent = [mail]
    let listing = switcher(system).read()
    #expect(!titles(listing).contains("Inbox"))
    #expect(listing.silentApps == ["Mail"])
    let view = SwitchWindowsList.view(rows: listing.windows.map(\.row), silentApps: listing.silentApps)
    #expect(view.string("navigationTitle") == "Some apps didn't answer: Mail", "in the bottom bar")
    #expect(SwitchWindowsList.footer(silentApps: ["Mail", "Xcode"]) == "Some apps didn't answer: Mail, Xcode")
    #expect(SwitchWindowsList.footer(silentApps: []) == nil)
    #expect(SwitchWindowsList.view(rows: [], silentApps: []).string("navigationTitle") == "Switch Windows")
}

@Test func anAppTooSlowForTheDeadlineIsLeftOutAndTriedAgainNextTime() async throws {
    let system = desk()
    let gate = DispatchSemaphore(value: 0)
    system.slow = [safari: gate]
    let inFlight = WindowReadsInFlight()
    let first = switcher(system, inFlight: inFlight).read(deadline: .milliseconds(300))
    #expect(first.silentApps == ["Safari"])
    #expect(titles(first) == ["Inbox", "Notes.txt", "Groceries"])

    // Still being read: it isn't asked again, and it's named again.
    let second = switcher(system, inFlight: inFlight).read(deadline: .milliseconds(300))
    #expect(second.silentApps == ["Safari"])
    #expect(system.reads.filter { $0 == safari }.count == 1)

    // Its read ends; the next read asks it again, and it answers.
    system.slow = [:]
    gate.signal()
    for _ in 0..<200 where inFlight.reading.contains(safari) { try await Task.sleep(for: .milliseconds(10)) }
    let third = switcher(system, inFlight: inFlight).read(deadline: .seconds(1))
    #expect(third.silentApps.isEmpty)
    #expect(titles(third) == ["Start Page", "Notes.txt", "Inbox", "Docs", "Groceries", "Recipes"])
    #expect(system.reads.filter { $0 == safari }.count == 2)
}

@Test func aReadWaitsOnTheAppsReadInFlightAndTakesItsAnswer() async throws {
    // SPEC-102 §1: Safari's read outlives the first read's deadline, so that read names it.
    let system = desk()
    let gate = DispatchSemaphore(value: 0)
    system.slow = [safari: gate]
    let inFlight = WindowReadsInFlight()
    let first = switcher(system, inFlight: inFlight).read(deadline: .milliseconds(50))
    #expect(first.silentApps == ["Safari"])

    // A second read, with time to spare, waits on that read instead of asking again, and Safari answers meanwhile.
    let second = Task.detached {
        let listing = switcher(system, inFlight: inFlight).read(deadline: .seconds(20))
        return (titles: titles(listing), silent: listing.silentApps)
    }
    for _ in 0..<2000 where inFlight.waiting(on: safari) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(inFlight.waiting(on: safari) == 1, "waiting on the read in flight")
    gate.signal()
    let listing = await second.value
    #expect(listing.silent.isEmpty, "not named: it answered within this read's second")
    #expect(listing.titles == ["Start Page", "Notes.txt", "Inbox", "Docs", "Groceries", "Recipes"])
    #expect(system.reads.filter { $0 == safari }.count == 1, "asked once")

    // The answer went to the read that waited, and no further: the next read asks again.
    system.slow = [:]
    for _ in 0..<200 where inFlight.reading.contains(safari) { try await Task.sleep(for: .milliseconds(10)) }
    _ = switcher(system, inFlight: inFlight).read(deadline: .seconds(5))
    #expect(system.reads.filter { $0 == safari }.count == 2)
}

@Test func appsAreReadAtOnceNotOneAfterAnother() {
    // Mail's read waits for Notes' to start, and Notes comes after Mail: read one after another, Mail would miss the
    // deadline.
    let system = desk()
    let started = DispatchSemaphore(value: 0)
    system.slow = [mail: started]
    system.signals = [notes: started]
    let listing = switcher(system).read(deadline: .seconds(2))
    #expect(listing.silentApps.isEmpty)
    #expect(Set(system.reads) == [mail, safari, textEdit, notes], "Fudge's own app is never read")
}

// MARK: - Search and the list

@Test func searchMatchesTheTitleAndTheAppsName() {
    let rows = switcher(desk()).read().windows.map(\.row)
    var list = ListContent(SwitchWindowsList.view(rows: rows, silentApps: []), searchText: "")
    #expect(list.items.map(\.title) == ["Start Page", "Notes.txt", "Inbox", "Docs", "Groceries", "Recipes"])
    #expect(list.items.map(\.subtitle) == ["Safari", "TextEdit", "Mail", "Safari", "Notes", "Safari"])
    #expect(list.items[0].icon == .object(["fileIcon": .string("/Applications/Safari.app")]))
    #expect(list.items[4].accessories.map(\.text) == ["Minimized"])
    list.search("safari")
    #expect(Set(list.items.map(\.title)) == ["Start Page", "Docs", "Recipes"])
    list.search("groc")
    #expect(list.items.map(\.title) == ["Groceries"])
    list.search("nothing like it")
    #expect(list.items.isEmpty)
    #expect(list.emptyView?.title == "No Windows")
}

@Test func rowIdsArePlacesAndCarryNoTitle() throws {
    let secret = SwitchWindowsList.Row(title: "Salary review 2026.pages", appName: "Pages")
    let other = SwitchWindowsList.Row(title: "Private Browsing", appName: "Safari")
    let rows = [secret, other, SwitchWindowsList.Row(title: "Pages", appName: "Pages")]
    let view = SwitchWindowsList.view(rows: rows, silentApps: [])
    let list = ListContent(view, searchText: "")
    #expect(list.items.map(\.itemId) == ["0", "1", "2"])
    // The same places with other titles have the same ids, nodes included: nothing about a row comes from its window.
    let renamed = rows.map { SwitchWindowsList.Row(title: "x" + $0.title, appName: "y" + $0.appName) }
    let again = ListContent(SwitchWindowsList.view(rows: renamed, silentApps: []), searchText: "")
    #expect(again.items.map(\.itemId) == list.items.map(\.itemId))
    #expect(again.items.map(\.id) == list.items.map(\.id))
    func ids(_ node: UINode) -> [Int] { [node.id] + node.children.flatMap(ids) }
    let actionIds = list.items.compactMap(\.actions).flatMap(ids)
    #expect(actionIds == again.items.compactMap(\.actions).flatMap(ids))
    for item in list.items {
        let id = try #require(item.itemId)
        #expect(Int(id) != nil, "a place")
        #expect(!rows.contains { id.contains($0.title) || id.contains($0.appName) })
    }
}

@Test func itsActionsAreSwitchCloseAndQuit() throws {
    let rows = switcher(desk()).read().windows.map(\.row)
    let list = ListContent(SwitchWindowsList.view(rows: rows, silentApps: []), searchText: "")
    let second = try #require(list.items.dropFirst().first)
    let entries = ActionPanelReader.sections(of: second.actions).flatMap(\.entries)
    #expect(entries.map(\.title) == ["Switch to Window", "Close Window", "Quit App"])
    #expect(entries.map(\.shortcut) == [nil, SwitchWindowsList.closeShortcut, SwitchWindowsList.quitShortcut])
    #expect(SwitchWindowsList.closeShortcut.description == "⌃X")
    #expect(SwitchWindowsList.quitShortcut.description == "⌃⌥X")
    #expect(entries[2].destructive)
    let targets = entries.map { entry -> SwitchWindowsList.Target? in
        guard case .node(let node) = entry.target else { return nil }
        return SwitchWindowsList.target(of: node, rows: rows.count)
    }
    #expect(targets == [.switchTo(row: 1), .close(row: 1), .quit(row: 1)])
    #expect(SwitchWindowsList.target(of: second.id, rows: rows.count) == nil, "the item itself runs nothing")
    #expect(SwitchWindowsList.target(of: 100 + 10 * rows.count + 3, rows: rows.count) == nil, "past the last row")
}

@Test func withoutAccessibilityTheListOffersItsSettings() throws {
    let list = ListContent(SwitchWindowsList.accessibilityNeeded(), searchText: "")
    #expect(list.items.isEmpty)
    let empty = try #require(list.emptyView)
    #expect(empty.title == AccessibilitySettingsAlert.title)
    let open = try #require(ActionPanelReader.sections(of: empty.actions).first?.entries.first)
    #expect(open.title == "Open Accessibility Settings")
    guard case .node(let node) = open.target else {
        Issue.record("not a node")
        return
    }
    #expect(SwitchWindowsList.target(of: node, rows: 0) == .openAccessibilitySettings)
}

@Test func whileReadingTheListIsLoading() {
    let list = ListContent(SwitchWindowsList.loading(), searchText: "")
    #expect(list.isLoading && list.items.isEmpty && list.emptyView == nil)
}

// MARK: - The actions

@Test func switchingUnminimizesRaisesAndActivates() {
    let system = desk()
    let listing = switcher(system).listing()
    #expect(listing.rows.map(\.title) == ["Start Page", "Notes.txt", "Inbox", "Docs", "Groceries", "Recipes"])
    #expect(listing.switchTo(row: 0) == nil)
    #expect(system.calls == ["raise 3", "activate 300"])
    #expect(listing.switchTo(row: 5) == nil)
    #expect(system.calls.suffix(3) == ["unminimize 5", "raise 5", "activate 300"])
    #expect(listing.switchTo(row: 6) == nil)
    #expect(system.calls.count == 5, "no row there")
}

@Test func aFailedStepStillActivatesTheApp() {
    let system = desk()
    system.refusing = ["raise"]
    let listing = switcher(system).listing()
    #expect(listing.switchTo(row: 1) == "raise refused")
    #expect(system.calls == ["raise 1", "activate 200"])
}

@Test func closeAndQuitCallTheSystem() {
    let system = desk()
    let listing = switcher(system).listing()
    #expect(listing.close(row: 2) == nil)
    #expect(listing.quit(row: 2))
    #expect(system.calls == ["close 6", "terminate 400"])
    system.refusing = ["close"]
    #expect(listing.close(row: 0) == "close refused")
    #expect(!listing.quit(row: 9))
    #expect(WindowListing.empty.rows.isEmpty && WindowListing.empty.switchTo(row: 0) == nil)
}

// MARK: - Made-up windows for snapshots

@Test func afterCloseWindowTheSelectionFollowsItsWindowNotItsPlace() {
    let system = desk()
    let before = switcher(system).listing()
    #expect(before.rows.map(\.title) == ["Start Page", "Notes.txt", "Inbox", "Docs", "Groceries", "Recipes"])
    // ⌃X on Inbox, then ↓ to Docs, then the re-read arrives without Inbox.
    #expect(before.close(row: 2) == nil)
    system.listed.removeAll { $0.number == 13 }
    system.ax[mail] = [SwitchableWindow(handle: 7, title: "Save?", frame: inbox, standard: false)]
    let after = switcher(system).listing()
    #expect(after.rows.map(\.title) == ["Start Page", "Notes.txt", "Docs", "Groceries", "Recipes"])
    #expect(after.row(sameWindowAs: 3, in: before) == 2, "Docs, not Groceries, which is in Docs' old place")
    #expect(after.row(sameWindowAs: 4, in: before) == 3)
    #expect(after.row(sameWindowAs: 0, in: before) == 0)
    #expect(after.row(sameWindowAs: 2, in: before) == nil, "Inbox is gone, so the selection keeps its place")
    #expect(after.row(sameWindowAs: 9, in: before) == nil)
    #expect(WindowListing.empty.row(sameWindowAs: 0, in: before) == nil)
    #expect(after.row(sameWindowAs: 0, in: .empty) == nil)
}

@Test func snapshotWindowsAreMadeUpFromTheFile() throws {
    let json = """
        [
          { "app": "Notes", "path": "/System/Applications/Notes.app", "title": "Groceries", "screen": "Built-in" },
          { "app": "Safari", "path": "/Applications/Safari.app", "title": "Trip ideas", "screen": "Studio" },
          { "app": "Notes", "title": "Book list", "minimized": true },
          { "app": "Xcode", "answers": false },
          { "app": "Safari", "title": "" , "screen": "Built-in" }
        ]
        """
    let system = FixedWindowSystem(json: Data(json.utf8))
    let listing = WindowSwitcher(system: system, ownPid: me, inFlight: WindowReadsInFlight()).listing()
    #expect(listing.rows.map(\.title) == ["Trip ideas", "Groceries", "Safari", "Book list"])
    #expect(listing.rows.map(\.accessory) == ["Studio", "Built-in", "Built-in", "Minimized"])
    #expect(listing.rows[0].appPath == "/Applications/Safari.app")
    #expect(listing.silentApps == ["Xcode"])
    // Its actions do nothing.
    #expect(listing.switchTo(row: 0) == nil && listing.close(row: 0) == nil && !listing.quit(row: 0))
    #expect(FixedWindowSystem(json: Data("not json".utf8)).apps().isEmpty)
}

@Test func manyMadeUpWindowsStayOnTheirScreensAndNoneIsTakenForFudge() throws {
    // SPEC-102 §2: 40 windows of 4 apps across two screens, in a run whose own pid is one the made-up apps would get.
    let entries = (0..<40).map { index in
        #"{ "app": "App \#(index % 4)", "title": "Window \#(index)", "screen": "\#(index % 2 == 0 ? "Left" : "Right")" }"#
    }
    let json = Data(("[" + entries.joined(separator: ",") + "]").utf8)
    let ownPid: Int32 = 1001
    let system = FixedWindowSystem(json: json, ownPid: ownPid)
    #expect(system.apps().count == 4 && !system.apps().contains { $0.pid == ownPid })
    let listing = WindowSwitcher(system: system, ownPid: ownPid, inFlight: WindowReadsInFlight()).listing()
    #expect(listing.rows.count == 40, "no made-up app is left out as Fudge's own")
    for (row, title) in zip(listing.rows, listing.rows.map(\.title)) {
        let index = try #require(Int(title.dropFirst("Window ".count)))
        #expect(row.accessory == (index % 2 == 0 ? "Left" : "Right"), "\(title) keeps its screen's name")
    }
}

@Test func recentAppsKeepTheLatestFirst() {
    var recent = RecentApps()
    recent.activated(1)
    recent.activated(2)
    recent.activated(1)
    #expect(recent.pids == [1, 2])
    for pid in 0..<Int32(RecentApps.limit + 5) { recent.activated(pid) }
    #expect(recent.pids.count == RecentApps.limit)
    #expect(recent.pids.first == Int32(RecentApps.limit + 4))
}

@Test func switchWindowsIsAWindowManagementCommand() {
    let group = BuiltInCommandGroup.windowManagement
    let command = group.commands.first { $0.name == SwitchWindowsList.commandName }
    #expect(command?.title == "Switch Windows")
    #expect(group.commandID(command!) == ":window-management/switch-windows")
    let found = RootSearch.rank(RootItem.builtInCommands(of: group), query: "switch", history: LaunchHistory())
    #expect(found.first?.title == "Switch Windows")
}
