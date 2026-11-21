import CoreGraphics
import Foundation

// Switch Windows (FUD-120): every window of every regular app, read through the Accessibility API, to switch to,
// close, or quit the app of. The logic lives here; the app reads the system behind `WindowSwitchSystem`, and tests
// and snapshot runs supply made-up windows (`FixedWindowSystem`). Window titles are often private (document names,
// mail subjects, private browsing), so nothing here logs or writes them: a listing lives in memory while its list is
// on screen, and its rows are known by their place in it, never by anything taken from a window.

/// A regular running app (one with a Dock icon), as Switch Windows lists its windows.
public struct SwitcherApp: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// Its bundle, whose icon its rows show.
    public var path: String?

    public init(pid: Int32, name: String, path: String? = nil) {
        self.pid = pid
        self.name = name
        self.path = path
    }
}

/// A screen with the name System Settings gives it (`NSScreen.localizedName`), and its bounds in the window list's
/// coordinates.
public struct NamedScreen: Sendable, Equatable {
    public var name: String
    public var bounds: CGRect

    public init(name: String, bounds: CGRect) {
        self.name = name
        self.bounds = bounds
    }
}

/// One of an app's windows as the Accessibility API lists it (`kAXWindowsAttribute`). `handle` is the system's own
/// reference to it, an `AXUIElement` in the app.
public struct SwitchableWindow<Handle> {
    public var handle: Handle
    /// `kAXTitleAttribute`.
    public var title: String?
    /// `kAXPositionAttribute` and `kAXSizeAttribute`, in the window list's coordinates; nil when either is missing.
    public var frame: CGRect?
    /// `kAXMinimizedAttribute`.
    public var minimized: Bool
    /// Whether its subrole is `kAXStandardWindowSubrole`: a window, not a panel, sheet, dialog or popover.
    public var standard: Bool
    /// Whether it's the app's `kAXFocusedWindowAttribute`.
    public var focused: Bool

    public init(
        handle: Handle, title: String? = nil, frame: CGRect? = nil, minimized: Bool = false, standard: Bool = true,
        focused: Bool = false
    ) {
        self.handle = handle
        self.title = title
        self.frame = frame
        self.minimized = minimized
        self.standard = standard
        self.focused = focused
    }
}

extension SwitchableWindow: Sendable where Handle: Sendable {}

/// What reading one app's windows gave.
public enum AppWindowsRead<Handle> {
    case answered([SwitchableWindow<Handle>])
    /// The app didn't answer within the Accessibility API's timeout.
    case noAnswer
}

extension AppWindowsRead: Sendable where Handle: Sendable {}

/// What Switch Windows reads and does. The app's reads the system, and its window reads wait on other apps, so
/// `WindowSwitcher` calls them off the main thread, several apps at once.
public protocol WindowSwitchSystem: Sendable {
    associatedtype Handle
    /// The regular apps running (with a Dock icon).
    func apps() -> [SwitcherApp]
    /// Pids, the most recently active app first, as far as Fudge has seen.
    func recentlyActive() -> [Int32]
    /// The frontmost app: the one the user was in, since the launcher never makes Fudge active.
    func frontmostPid() -> Int32?
    /// The windows on screen, front to back (`CGWindowListCopyWindowInfo`).
    func listedWindows() -> [ListedWindow]
    func screens() -> [NamedScreen]
    /// The app's windows, front to back, as `kAXWindowsAttribute` has them. Blocks while the app answers.
    func windows(of pid: Int32) -> AppWindowsRead<Handle>
    /// Sets `kAXMinimizedAttribute` to false.
    func unminimize(_ window: Handle) throws
    /// Performs `kAXRaiseAction`.
    func raise(_ window: Handle) throws
    /// Makes the app the active one.
    func activate(pid: Int32) throws
    /// Presses the window's close button (`kAXCloseButtonAttribute`, then `kAXPressAction`).
    func close(_ window: Handle) throws
    /// Asks the app to quit (`NSRunningApplication.terminate()`); false when it can't be asked.
    func terminate(pid: Int32) -> Bool
    /// Whether two handles are the same window, in two reads (`CFEqual` for Accessibility elements).
    func sameWindow(_ one: Handle, _ other: Handle) -> Bool
}

extension WindowSwitchSystem where Handle: Equatable {
    public func sameWindow(_ one: Handle, _ other: Handle) -> Bool { one == other }
}

/// The apps most recently made active, the latest first, by pid: in memory, for the run, from the system's notices.
/// Switch Windows orders apps with no window on screen by it.
public struct RecentApps: Sendable, Equatable {
    public static let limit = 64
    public private(set) var pids: [Int32] = []

    public init() {}

    public mutating func activated(_ pid: Int32) {
        pids.removeAll { $0 == pid }
        pids.insert(pid, at: 0)
        if pids.count > Self.limit { pids.removeLast(pids.count - Self.limit) }
    }
}

/// The apps whose windows are being read, across reads. An app still being read isn't asked again until that read
/// ends, so a hung app holds one thread at most: a read that wants it waits on the read in flight and shares its
/// answer, if it comes within that read's deadline (SPEC-102 §1). The answer goes only to the reads that were waiting
/// for it, and is kept no longer; once the read ends, the next read asks again.
public final class WindowReadsInFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Int32: Flight] = [:]

    public init() {}

    /// One app's read: its answer, once it comes, for the reads waiting on it.
    final class Flight: @unchecked Sendable {
        let done = DispatchGroup()
        private let lock = NSLock()
        private var stored: Any?
        fileprivate(set) var waiting = 0

        init() { done.enter() }

        /// The answer, type-erased since one registry serves every `WindowSwitchSystem`.
        var answer: Any? { lock.withLock { stored } }

        fileprivate func finish(_ answer: Any) {
            lock.withLock { stored = answer }
            done.leave()
        }
    }

    /// `pid`'s read in flight, and whether the caller starts it (then it must `end` it) or waits on it.
    func begin(_ pid: Int32) -> (flight: Flight, starts: Bool) {
        lock.withLock {
            if let flight = reads[pid] {
                flight.waiting += 1
                return (flight, false)
            }
            let flight = Flight()
            reads[pid] = flight
            return (flight, true)
        }
    }

    /// Ends `pid`'s read with its answer: the reads waiting on it get it, and the next read asks again.
    func end(_ pid: Int32, _ flight: Flight, with answer: Any) {
        lock.withLock { if reads[pid] === flight { reads[pid] = nil } }
        flight.finish(answer)
    }

    var reading: Set<Int32> { lock.withLock { Set(reads.keys) } }

    /// How many reads are waiting on `pid`'s read, for tests.
    func waiting(on pid: Int32) -> Int { lock.withLock { reads[pid]?.waiting ?? 0 } }
}

/// A window as Switch Windows lists it.
public struct SwitcherEntry<Handle> {
    public var handle: Handle
    public var app: SwitcherApp
    public var title: String?
    public var minimized: Bool
    /// The name of the screen holding most of it, when there are several and it isn't minimized.
    public var screen: String?

    /// Its row: the title, else the app's name; the app's name under it; and "Minimized", or the screen's name.
    public var row: SwitchWindowsList.Row {
        SwitchWindowsList.Row(
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? app.name, appName: app.name, appPath: app.path,
            accessory: minimized ? SwitchWindowsList.minimized : screen)
    }
}

/// Where a window is in a read: its app, and its index among the app's AX windows.
private struct WindowPlace: Hashable {
    var pid: Int32
    var index: Int
}

/// One read: the windows in the order the list shows them, and the apps that didn't answer in time, by name.
public struct SwitcherListing<Handle> {
    public var windows: [SwitcherEntry<Handle>]
    public var silentApps: [String]
}

/// Switch Windows over a `WindowSwitchSystem`: reading the windows, ordering them, and the actions.
public struct WindowSwitcher<System: WindowSwitchSystem>: Sendable {
    public let system: System
    /// Fudge's own windows are never listed.
    public let ownPid: Int32
    /// Shared by every read of the run.
    public let inFlight: WindowReadsInFlight

    public init(system: System, ownPid: Int32, inFlight: WindowReadsInFlight) {
        self.system = system
        self.ownPid = ownPid
        self.inFlight = inFlight
    }

    /// Reads every app's windows at once, each on its own thread, and waits `deadline` (about a second) for them all.
    /// An app that hasn't answered by then, or said it couldn't (the Accessibility API's own timeout for each app),
    /// is left out and named in `silentApps`. One an earlier read is still reading isn't asked again: this read waits
    /// on that one's answer, without a thread of its own, and takes it if it comes in time. Blocks: call it off the
    /// main thread.
    public func read(deadline: Duration = .seconds(1)) -> SwitcherListing<System.Handle> {
        let apps = system.apps().filter { $0.pid != ownPid }
        let answers = Answers<System.Handle>()
        let group = DispatchGroup()
        for app in apps {
            let pid = app.pid
            let (flight, starts) = inFlight.begin(pid)
            group.enter()
            if starts {
                DispatchQueue.global(qos: .userInitiated).async { [system, inFlight] in
                    let answer = system.windows(of: pid)
                    answers.set(answer, for: pid)
                    inFlight.end(pid, flight, with: answer)
                    group.leave()
                }
            } else {
                flight.done.notify(queue: .global(qos: .userInitiated)) {
                    if let answer = flight.answer as? AppWindowsRead<System.Handle> { answers.set(answer, for: pid) }
                    group.leave()
                }
            }
        }
        _ = group.wait(timeout: .now() + .milliseconds(Int(deadline / .milliseconds(1))))
        let reads = answers.all
        var windows: [Int32: [SwitchableWindow<System.Handle>]] = [:]
        for app in apps {
            if case .answered(let list) = reads[app.pid] { windows[app.pid] = list }
        }
        let listed = system.listedWindows()
        let frontmost = system.frontmostPid()
        let ranked = Self.ranked(apps, recent: system.recentlyActive(), frontmost: frontmost, listed: listed)
        return SwitcherListing(
            windows: Self.order(
                ranked, windows: windows, listed: listed, screens: system.screens(), frontmost: frontmost),
            silentApps: ranked.filter { windows[$0.pid] == nil }.map(\.name))
    }

    /// The apps, most recently active first: the frontmost, then as `recent` has them, then by their front window
    /// on screen, then as the system listed them.
    static func ranked(_ apps: [SwitcherApp], recent: [Int32], frontmost: Int32?, listed: [ListedWindow])
        -> [SwitcherApp]
    {
        func rank(_ app: SwitcherApp) -> (Int, Int) {
            if app.pid == frontmost { return (0, -1) }
            if let index = recent.firstIndex(of: app.pid) { return (0, index) }
            if let index = listed.firstIndex(where: { $0.pid == app.pid }) { return (1, index) }
            return (2, 0)
        }
        return apps.enumerated().sorted {
            let (left, right) = (rank($0.element), rank($1.element))
            return (left.0, left.1, $0.offset) < (right.0, right.1, $1.offset)
        }.map(\.element)
    }

    /// The order the list shows: first the windows on screen, front to back, each the AX window its listed window is
    /// paired with (`WindowMatch.pairs`); then every other window, by app as `apps` ranks them, each app's front to
    /// back. Only standard windows are listed. Last, the window the user was in (the frontmost app's focused window,
    /// else its front window on screen) moves to second place, so the first row is the window before it and ↵ goes
    /// back there, as ⌘Tab does for apps.
    static func order(
        _ apps: [SwitcherApp], windows: [Int32: [SwitchableWindow<System.Handle>]], listed: [ListedWindow],
        screens: [NamedScreen], frontmost: Int32?
    ) -> [SwitcherEntry<System.Handle>] {
        let onScreen = listed.filter { $0.layer == 0 && $0.alpha > 0 && windows[$0.pid] != nil }
        var pairing: [Int: WindowPlace] = [:]
        for (pid, axWindows) in windows {
            let mine = onScreen.filter { $0.pid == pid }
            // A minimized window isn't in the window list, so it takes no part.
            let candidates = axWindows.map { (frame: $0.minimized ? nil : $0.frame, title: $0.title) }
            for (window, index) in zip(mine, WindowMatch.pairs(mine, among: candidates)) {
                if let index { pairing[window.number] = WindowPlace(pid: pid, index: index) }
            }
        }
        var used = Set<WindowPlace>()
        var places: [WindowPlace] = []
        for window in onScreen {
            guard let place = pairing[window.number], windows[place.pid]?[place.index].standard == true,
                used.insert(place).inserted
            else { continue }
            places.append(place)
        }
        let shownOnScreen = places.count
        for app in apps {
            for (index, window) in (windows[app.pid] ?? []).enumerated() where window.standard {
                let place = WindowPlace(pid: app.pid, index: index)
                if used.insert(place).inserted { places.append(place) }
            }
        }
        if let frontmost {
            let current =
                places.firstIndex { $0.pid == frontmost && windows[$0.pid]?[$0.index].focused == true }
                ?? places.prefix(shownOnScreen).firstIndex { $0.pid == frontmost }
            if let current, places.count > 1 {
                places.insert(places.remove(at: current), at: 1)
            }
        }
        let byPid = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return places.compactMap { place in
            guard let app = byPid[place.pid], let window = windows[place.pid]?[place.index] else { return nil }
            var screen: String?
            if screens.count > 1, !window.minimized, let frame = window.frame,
                let index = PanelScreen.mostOf(frame, on: screens.map(\.bounds))
            {
                screen = screens[index].name
            }
            return SwitcherEntry(
                handle: window.handle, app: app, title: window.title, minimized: window.minimized, screen: screen)
        }
    }

    /// ↵ Switch to Window: un-minimizes it if it's minimized, raises it, and makes its app active. Each step is tried
    /// even when one before it failed; the first failure is what's said. Blocks: call it off the main thread.
    public func switchTo(_ entry: SwitcherEntry<System.Handle>) -> String? {
        var problem: Error?
        if entry.minimized {
            do { try system.unminimize(entry.handle) } catch { problem = error }
        }
        do { try system.raise(entry.handle) } catch { problem = problem ?? error }
        do { try system.activate(pid: entry.app.pid) } catch { problem = problem ?? error }
        return problem.map { String(describing: $0) }
    }

    /// ⌃X Close Window: presses its close button. Blocks: call it off the main thread.
    public func close(_ entry: SwitcherEntry<System.Handle>) -> String? {
        do {
            try system.close(entry.handle)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// ⌃⌥X Quit App, once the user has confirmed: asks the window's app to quit.
    public func quit(_ entry: SwitcherEntry<System.Handle>) -> Bool {
        system.terminate(pid: entry.app.pid)
    }

    /// `read` with its actions, the window handles out of sight: what the launcher keeps while the list is on screen.
    public func listing(deadline: Duration = .seconds(1)) -> WindowListing {
        let read = read(deadline: deadline)
        let entries = read.windows
        func entry(_ row: Int) -> SwitcherEntry<System.Handle>? { entries.indices.contains(row) ? entries[row] : nil }
        return WindowListing(
            rows: entries.map(\.row), silentApps: read.silentApps,
            switchTo: { row in entry(row).flatMap(switchTo) },
            close: { row in entry(row).flatMap(close) },
            quit: { row in entry(row).map(quit) ?? false },
            window: { row in entry(row).map { $0.handle as Any } },
            row: { [system] handle in
                guard let handle = handle as? System.Handle else { return nil }
                return entries.firstIndex { system.sameWindow($0.handle, handle) }
            })
    }

    /// Each app's answer, set from the threads reading them.
    private final class Answers<Handle>: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [Int32: AppWindowsRead<Handle>] = [:]

        func set(_ read: AppWindowsRead<Handle>, for pid: Int32) { lock.withLock { reads[pid] = read } }

        var all: [Int32: AppWindowsRead<Handle>] { lock.withLock { reads } }
    }
}

/// One read of the windows and what its rows do, by their place in it: what the launcher keeps while Switch Windows
/// is on screen, in memory only. The actions wait on other apps, so they're called off the main thread.
public final class WindowListing: @unchecked Sendable {
    public let rows: [SwitchWindowsList.Row]
    /// The apps that didn't answer in time, by name.
    public let silentApps: [String]
    private let switchToRow: (Int) -> String?
    private let closeRow: (Int) -> String?
    private let quitRow: (Int) -> Bool
    /// A row's window handle, to find it in a later read; the handle's type stays the system's.
    private let windowAt: (Int) -> Any?
    /// The row showing a window handle from another read of the same system, if any.
    private let rowOfWindow: (Any) -> Int?

    init(
        rows: [SwitchWindowsList.Row], silentApps: [String], switchTo: @escaping (Int) -> String?,
        close: @escaping (Int) -> String?, quit: @escaping (Int) -> Bool, window: @escaping (Int) -> Any?,
        row: @escaping (Any) -> Int?
    ) {
        self.rows = rows
        self.silentApps = silentApps
        switchToRow = switchTo
        closeRow = close
        quitRow = quit
        windowAt = window
        rowOfWindow = row
    }

    /// A listing with nothing in it.
    public static let empty = WindowListing(
        rows: [], silentApps: [], switchTo: { _ in nil }, close: { _ in nil }, quit: { _ in false },
        window: { _ in nil }, row: { _ in nil })

    /// The row in this read showing the window that `row` showed in `previous`, an earlier read; nil when it's gone.
    /// After Close Window or Quit App, the list reads again and the selection follows the window it was on.
    public func row(sameWindowAs row: Int, in previous: WindowListing) -> Int? {
        previous.windowAt(row).flatMap(rowOfWindow)
    }

    /// Switch to Window on `row`; what went wrong, if anything.
    public func switchTo(row: Int) -> String? { switchToRow(row) }

    /// Close Window on `row`; what went wrong, if anything.
    public func close(row: Int) -> String? { closeRow(row) }

    /// Quit App on `row`'s app; false when it couldn't be asked to.
    public func quit(row: Int) -> Bool { quitRow(row) }
}

/// Made-up windows for snapshot runs (`--windows <file>`), so a snapshot never reads the real window list or the
/// Accessibility API, and its actions do nothing. The file is a JSON array of windows, front to back:
/// `{ "app": "Notes", "path": "/System/Applications/Notes.app", "title": "Groceries", "screen": "Studio Display",
/// "minimized": false }`, every key but `app` optional. The first window that isn't minimized is the one the user
/// was in, and its app is frontmost; apps are most recently active in the order they first appear. An entry with
/// `"answers": false` is an app that doesn't answer in time. Each screen named gets a place beside the one before.
public struct FixedWindowSystem: WindowSwitchSystem {
    public typealias Handle = Int

    struct Entry: Decodable {
        var app: String
        var path: String?
        var title: String?
        var minimized: Bool?
        var screen: String?
        var answers: Bool?
    }

    private let appList: [SwitcherApp]
    private let silent: Set<Int32>
    private let axWindows: [Int32: [SwitchableWindow<Int>]]
    private let listed: [ListedWindow]
    private let screenList: [NamedScreen]
    private let frontmost: Int32?

    public init(json: Data) {
        let entries = (try? JSONDecoder().decode([Entry].self, from: json)) ?? []
        var apps: [SwitcherApp] = []
        var silent = Set<Int32>()
        var pids: [String: Int32] = [:]
        var screens: [NamedScreen] = []
        for entry in entries {
            if pids[entry.app] == nil {
                let pid = Int32(1000 + apps.count)
                pids[entry.app] = pid
                apps.append(SwitcherApp(pid: pid, name: entry.app, path: entry.path))
            }
            if entry.answers == false, let pid = pids[entry.app] { silent.insert(pid) }
            if let name = entry.screen, !screens.contains(where: { $0.name == name }) {
                screens.append(
                    NamedScreen(name: name, bounds: CGRect(x: 1920 * screens.count, y: 0, width: 1920, height: 1080)))
            }
        }
        if screens.isEmpty {
            screens = [NamedScreen(name: "Display", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        }
        var axWindows: [Int32: [SwitchableWindow<Int>]] = [:]
        var listed: [ListedWindow] = []
        var frontmost: Int32?
        for (index, entry) in entries.enumerated() where entry.answers != false {
            guard let pid = pids[entry.app] else { continue }
            let screen = screens.first { $0.name == entry.screen } ?? screens[0]
            let frame = CGRect(
                x: screen.bounds.minX + CGFloat(40 * index), y: CGFloat(40 * index), width: 800, height: 600)
            let minimized = entry.minimized == true
            let focused = !minimized && frontmost == nil
            if focused { frontmost = pid }
            axWindows[pid, default: []].append(
                SwitchableWindow(
                    handle: index, title: entry.title, frame: frame, minimized: minimized, focused: focused))
            if !minimized { listed.append(ListedWindow(number: index + 1, pid: pid, bounds: frame)) }
        }
        appList = apps
        self.silent = silent
        self.axWindows = axWindows
        self.listed = listed
        screenList = screens
        self.frontmost = frontmost
    }

    /// The windows in `file`; none when it can't be read.
    public static func load(from file: URL) -> FixedWindowSystem {
        FixedWindowSystem(json: (try? Data(contentsOf: file)) ?? Data())
    }

    public func apps() -> [SwitcherApp] { appList }
    public func recentlyActive() -> [Int32] { appList.map(\.pid) }
    public func frontmostPid() -> Int32? { frontmost }
    public func listedWindows() -> [ListedWindow] { listed }
    public func screens() -> [NamedScreen] { screenList }

    public func windows(of pid: Int32) -> AppWindowsRead<Int> {
        silent.contains(pid) ? .noAnswer : .answered(axWindows[pid] ?? [])
    }

    public func unminimize(_ window: Int) throws {}
    public func raise(_ window: Int) throws {}
    public func activate(pid: Int32) throws {}
    public func close(_ window: Int) throws {}
    public func terminate(pid: Int32) -> Bool { false }
}
