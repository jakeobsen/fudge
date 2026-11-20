import Foundation

/// A menu-bar command's manifest `interval` ("10s", "5m", "1h", "1d"): how often it refreshes in the background.
public enum MenuBarInterval {
    /// Shorter intervals are raised to this.
    public static let floor: TimeInterval = 10

    /// The interval in seconds, at least `floor`; nil when there's none or it can't be read.
    public static func seconds(_ text: String?) -> TimeInterval? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(),
            let match = text.wholeMatch(of: /(\d+(?:\.\d+)?)([smhd])/),
            let value = Double(match.1)
        else { return nil }
        let unit: TimeInterval =
            switch match.2 {
            case "s": 1
            case "m": 60
            case "h": 3_600
            default: 86_400
            }
        return max(floor, value * unit)
    }
}

/// The menu-bar commands the user activated, by command id (`FudgeSettings.commandID`), in the order they were
/// activated. Stored in `menu-bar.json` as `{ "active": [ "<extension>/<command>", … ] }`.
public struct MenuBarStore: Sendable, Equatable {
    /// fudge shows at most this many menu bar items.
    public static let limit = 50

    public private(set) var active: [String]

    public init(active: [String] = []) {
        self.active = active
    }

    public struct LimitReached: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "fudge shows at most \(MenuBarStore.limit) menu bar items. Deactivate one first."
        }
    }

    public func isActive(_ id: String) -> Bool { active.contains(id) }

    /// The active commands fudge puts in the menu bar: those in `installed` (command ids of menu-bar commands) that
    /// `settings` has enabled, in the order they were activated. A disabled command, or one of a disabled extension,
    /// stays active here, so turning it back on in Settings brings its item back.
    public func shown(installed: Set<String>, settings: FudgeSettings) -> [String] {
        active.filter { installed.contains($0) && settings.isEnabled(commandID: $0) }
    }

    /// A command's status item's autosave name. macOS keeps each status item's position and whether it's shown under
    /// that name, so it must belong to the command: unnamed items are `Item-0`, `Item-1`, … in the order they're
    /// made, and would take over another item's saved state.
    public static func autosaveName(_ id: String) -> String { "menubar:\(id)" }

    /// Adds a command. Throws `LimitReached` when `limit` are active already; an active command is left as it is.
    public mutating func activate(_ id: String) throws {
        guard !active.contains(id) else { return }
        guard active.count < Self.limit else { throw LimitReached() }
        active.append(id)
    }

    /// Removes a command. Returns whether it was active.
    @discardableResult
    public mutating func deactivate(_ id: String) -> Bool {
        guard let index = active.firstIndex(of: id) else { return false }
        active.remove(at: index)
        return true
    }

    /// Drops the commands that aren't in `installed` (command ids of menu-bar commands). Returns whether any were.
    /// An empty `installed` drops nothing: it more likely means the extensions folder couldn't be read than that
    /// every menu-bar command is gone, and deactivating them all would lose the user's choices.
    @discardableResult
    public mutating func prune(keeping installed: Set<String>) -> Bool {
        guard !installed.isEmpty else { return false }
        let kept = active.filter { installed.contains($0) }
        guard kept.count != active.count else { return false }
        active = kept
        return true
    }

    /// Reads the file tolerantly: a missing or unreadable file has nothing active, and only strings count.
    public static func load(from file: URL) -> MenuBarStore {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let active = object["active"] as? [Any]
        else { return MenuBarStore() }
        var seen = Set<String>()
        return MenuBarStore(active: active.compactMap { $0 as? String }.filter { seen.insert($0).inserted })
    }

    /// Writes the file atomically.
    public func save(to file: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["active": active], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

/// One active menu-bar command's loads and unloads (SPEC-004 B3). At most one instance is loaded at a time. It's
/// unloaded once it has rendered without `isLoading`, no menu of it is open, and no `onAction` it started is still
/// running. The app tells it what happened and asks `takeUnload()` after each step.
public struct MenuBarLifecycle: Sendable, Equatable {
    /// Why the command should run now.
    public enum Trigger: Sendable, Equatable {
        /// fudge started with the command active.
        case startup
        /// Its menu was opened.
        case click
        /// Its manifest `interval` passed.
        case interval
        /// Run from root search (or a hotkey), activating it if needed.
        case rootSearch
        /// `launchCommand` of the command, with `LaunchType.Background` or `UserInitiated`.
        case launchCommand(userInitiated: Bool)

        /// UserInitiated launches show errors in the HUD; Background ones only log them.
        public var isUserInitiated: Bool {
            switch self {
            case .startup, .interval: false
            case .click, .rootSearch: true
            case .launchCommand(let userInitiated): userInitiated
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Start an instance, as UserInitiated or Background.
        case launch(userInitiated: Bool)
        /// An instance is loaded: nothing starts. A click just opens the menu, and a tick is skipped.
        case alreadyLoaded
        /// An instance is being unloaded: this one starts once it has exited (`exited` returns it).
        case queued
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case loaded(session: String)
        case unloading(session: String)
    }

    public private(set) var phase: Phase = .idle
    /// The launch waiting for an unloading instance to exit.
    public private(set) var queued: Trigger?
    /// Whether the loaded instance was launched UserInitiated.
    public private(set) var isUserInitiated = false
    /// Whether the loaded instance has rendered yet. Until it has, the menu shows the last tree, whose items
    /// belong to an instance that's gone: picks wait for the first render.
    public private(set) var hasRendered = false
    public private(set) var isLoading = false
    public private(set) var isMenuOpen = false
    /// `onAction`s sent to the loaded instance that haven't settled.
    public private(set) var runningEvents = 0
    /// A Background launch failed, and no later render has succeeded.
    public private(set) var lastRefreshFailed = false
    private var failed = false

    public init() {}

    /// The loaded instance's session.
    public var session: String? {
        if case .loaded(let session) = phase { return session }
        return nil
    }

    /// Whether `session` is the loaded instance, with a render the menu can pick from.
    public func isLive(_ session: String?) -> Bool {
        session != nil && self.session == session && hasRendered
    }

    /// The command should run: says whether to start an instance.
    public mutating func request(_ trigger: Trigger) -> Decision {
        switch phase {
        case .idle:
            return .launch(userInitiated: trigger.isUserInitiated)
        case .loaded:
            return .alreadyLoaded
        case .unloading:
            // A UserInitiated wish outranks a Background one.
            if queued == nil || (trigger.isUserInitiated && queued?.isUserInitiated == false) { queued = trigger }
            return .queued
        }
    }

    /// An instance was started as `session`.
    public mutating func launched(_ session: String, userInitiated: Bool) {
        phase = .loaded(session: session)
        isUserInitiated = userInitiated
        hasRendered = false
        isLoading = false
        runningEvents = 0
        failed = false
    }

    /// The instance rendered. Returns false for a render that doesn't count: from another session, or after the
    /// instance failed (React unmounts a root that threw, which would otherwise look like an empty render).
    public mutating func rendered(_ session: String, isLoading: Bool) -> Bool {
        guard self.session == session, !failed else { return false }
        hasRendered = true
        self.isLoading = isLoading
        lastRefreshFailed = false
        return true
    }

    /// The instance failed (a fatal error). It's unloaded; a Background failure marks the item. Returns whether the
    /// failure is UserInitiated, which shows in the HUD.
    public mutating func failed(_ session: String) -> Bool {
        guard self.session == session else { return false }
        failed = true
        if !isUserInitiated { lastRefreshFailed = true }
        return isUserInitiated
    }

    public mutating func menuOpened() { isMenuOpen = true }
    public mutating func menuClosed() { isMenuOpen = false }

    /// An `onAction` was sent to `session`.
    public mutating func eventSent(_ session: String) {
        if self.session == session { runningEvents += 1 }
    }

    /// The worker answered an event (`eventSettled`).
    public mutating func eventSettled(_ session: String) {
        if self.session == session, runningEvents > 0 { runningEvents -= 1 }
    }

    /// The session to unload now, if the loaded instance is done: it failed, or it has rendered without
    /// `isLoading`, no menu is open and no `onAction` is running. The phase moves to unloading.
    public mutating func takeUnload() -> String? {
        guard case .loaded(let session) = phase else { return nil }
        let idle = hasRendered && !isLoading && !isMenuOpen && runningEvents == 0
        guard failed || idle else { return nil }
        phase = .unloading(session: session)
        return session
    }

    /// The instance exited (unloaded or crashed). Returns the launch queued meanwhile, which should start now.
    public mutating func exited(_ session: String) -> Trigger? {
        switch phase {
        case .loaded(let current) where current == session, .unloading(let current) where current == session:
            phase = .idle
            runningEvents = 0
            let next = queued
            queued = nil
            return next
        default:
            return nil
        }
    }

    /// The instance couldn't be started: back to idle.
    public mutating func launchFailed() {
        phase = .idle
        queued = nil
    }
}
