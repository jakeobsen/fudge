import Foundation

/// Registers global hotkeys with the system. The app's is Carbon's `RegisterEventHotKey`; tests use a fake, so no
/// test ever registers a real hotkey.
public protocol HotKeyRegistering: AnyObject {
    /// Registers `spec` under `id`. False when the system refuses, usually because another app has it.
    func register(_ spec: HotKeySpec, id: UInt32) -> Bool
    func unregister(id: UInt32)
}

/// fudge's global hotkeys: the launcher's, and one per command. It registers and unregisters only what changed,
/// and can suspend all of them while a hotkey is being recorded, so pressing one records it instead of firing.
public final class HotKeyRegistry {
    public static let launcherID: UInt32 = 1

    private let registrar: HotKeyRegistering
    public private(set) var launcher: HotKeySpec?
    /// The command hotkeys wanted, by command id, registered or not.
    public private(set) var commands: [String: HotKeySpec] = [:]
    /// Command ids whose hotkey the system refused.
    public private(set) var refused: Set<String> = []
    public private(set) var isSuspended = false
    private var ids: [String: UInt32] = [:]
    private var nextID: UInt32 = 2

    public init(registrar: HotKeyRegistering) {
        self.registrar = registrar
    }

    /// Sets the launcher's hotkey. False when the system refuses it.
    @discardableResult
    public func setLauncher(_ spec: HotKeySpec?) -> Bool {
        if launcher != nil, !isSuspended { registrar.unregister(id: Self.launcherID) }
        launcher = spec
        guard let spec, !isSuspended else { return true }
        return registrar.register(spec, id: Self.launcherID)
    }

    /// Makes the registered command hotkeys `wanted`, touching only those that changed.
    public func apply(_ wanted: [String: HotKeySpec]) {
        let old = commands
        commands = wanted
        guard !isSuspended else { return }
        for (command, spec) in old where wanted[command] != spec {
            if let id = ids[command] { registrar.unregister(id: id) }
            refused.remove(command)
        }
        for (command, spec) in wanted where old[command] != spec || refused.contains(command) {
            register(spec, for: command)
        }
    }

    /// The command a pressed hotkey id belongs to; nil for the launcher's or an unknown id.
    public func command(for id: UInt32) -> String? {
        ids.first { $0.value == id && commands[$0.key] != nil }?.key
    }

    /// Unregisters everything, e.g. while a hotkey is being recorded.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        if launcher != nil { registrar.unregister(id: Self.launcherID) }
        for command in commands.keys where !refused.contains(command) {
            if let id = ids[command] { registrar.unregister(id: id) }
        }
    }

    /// Registers everything again.
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if let launcher { _ = registrar.register(launcher, id: Self.launcherID) }
        refused = []
        for (command, spec) in commands { register(spec, for: command) }
    }

    private func register(_ spec: HotKeySpec, for command: String) {
        let id = ids[command] ?? nextID
        if ids[command] == nil {
            ids[command] = id
            nextID += 1
        }
        if registrar.register(spec, id: id) { refused.remove(command) } else { refused.insert(command) }
    }
}

/// Why a recorded hotkey can't be a command's.
public enum HotKeyConflict: Sendable, Equatable {
    /// It needs one of ⌘ ⌥ ⌃, unless it's an F-key.
    case needsModifier
    /// It's the launcher's own hotkey.
    case launcher
    /// Another command has it.
    case command(String)

    /// Checks `spec` for `commandID` against the launcher's hotkey and the other commands'.
    public static func check(
        _ spec: HotKeySpec, for commandID: String, launcher: HotKeySpec, commands: [String: HotKeySpec]
    ) -> HotKeyConflict? {
        guard spec.isAllowed else { return .needsModifier }
        if spec.sameKeys(as: launcher) { return .launcher }
        if let other = commands.first(where: { $0.key != commandID && $0.value.sameKeys(as: spec) }) {
            return .command(other.key)
        }
        return nil
    }
}

/// What pressing a command's hotkey does.
public enum HotKeyLaunch: Sendable, Equatable {
    /// Opens it as root search would: a view command shows the panel; a no-view command runs without it.
    case open
    /// The view command already on screen: pressing its hotkey again hides the panel.
    case hidePanel
    /// A required argument needs a value: show root search with the command selected and its fields.
    case askForArguments

    public static func action(mode: String, hasRequiredArgument: Bool, isOnScreen: Bool) -> HotKeyLaunch {
        if mode == "view", isOnScreen { return .hidePanel }
        if hasRequiredArgument { return .askForArguments }
        return .open
    }
}

/// Where a launch came from, for what happens when a no-view command finishes.
public enum LaunchOrigin: Sendable, Equatable {
    case rootSearch
    case hotkey

    /// A no-view command run from root search clears the query and hides the panel when it finishes. One run by
    /// its hotkey leaves root search alone, so the user's last query isn't wiped.
    public var clearsRootSearchWhenFinished: Bool { self == .rootSearch }
}
