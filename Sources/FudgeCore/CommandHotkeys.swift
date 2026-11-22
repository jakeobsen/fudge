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
    /// Whether the system refused `launcher`, usually because another app has it. It's tried again on `resume`.
    public private(set) var launcherRefused = false
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

    /// Sets the launcher's hotkey; false when the system refuses it. A refused change keeps the old hotkey, which
    /// is registered again and stays `launcher`. With no old one (at launch), the refused hotkey becomes `launcher`
    /// anyway, marked `launcherRefused`.
    @discardableResult
    public func setLauncher(_ spec: HotKeySpec) -> Bool {
        guard !isSuspended else {
            launcher = spec
            return true
        }
        let old = launcher
        if old != nil, !launcherRefused { registrar.unregister(id: Self.launcherID) }
        if registrar.register(spec, id: Self.launcherID) {
            launcher = spec
            launcherRefused = false
            return true
        }
        if let old {
            launcherRefused = !registrar.register(old, id: Self.launcherID)
        } else {
            launcher = spec
            launcherRefused = true
        }
        return false
    }

    /// What changing the launcher's hotkey came to.
    public enum LauncherChange: Sendable, Equatable {
        case changed
        /// The system refused it; the old hotkey stays (`setLauncher`).
        case inUse
        /// It couldn't be saved; everything is as it was before.
        case notSaved
    }

    /// Changes the launcher's hotkey: registered first, then `save`d. A refusal keeps the old one. A save that
    /// fails puts back exactly what was there before, so the registration and the file agree: the old hotkey
    /// registered, or, if it was refused at launch, still wanted and still marked refused.
    public func changeLauncher(to spec: HotKeySpec, save: () -> Bool) -> LauncherChange {
        let before = (spec: launcher, refused: launcherRefused)
        guard setLauncher(spec) else { return .inUse }
        guard save() else {
            restoreLauncher(before.spec, refused: before.refused)
            return .notSaved
        }
        return .changed
    }

    private func restoreLauncher(_ spec: HotKeySpec?, refused: Bool) {
        if !isSuspended, launcher != nil, !launcherRefused { registrar.unregister(id: Self.launcherID) }
        launcher = spec
        launcherRefused = refused
        guard !isSuspended, let spec, !refused else { return }
        launcherRefused = !registrar.register(spec, id: Self.launcherID)
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
        if launcher != nil, !launcherRefused { registrar.unregister(id: Self.launcherID) }
        for command in commands.keys where !refused.contains(command) {
            if let id = ids[command] { registrar.unregister(id: id) }
        }
    }

    /// Registers everything again.
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if let launcher { launcherRefused = !registrar.register(launcher, id: Self.launcherID) }
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

    /// Checks `spec` for `commandID` against the launcher's hotkey and the other commands'. With `installed`, only
    /// installed commands' hotkeys count: an uninstalled one's saved hotkey gives way (`displaced`).
    public static func check(
        _ spec: HotKeySpec, for commandID: String, launcher: HotKeySpec, commands: [String: HotKeySpec],
        installed: Set<String>? = nil
    ) -> HotKeyConflict? {
        guard spec.isAllowed else { return .needsModifier }
        if spec.sameKeys(as: launcher) { return .launcher }
        let holders = commands.filter { $0.key != commandID && $0.value.sameKeys(as: spec) }
        if let other = holders.keys.filter({ installed?.contains($0) ?? true }).min() { return .command(other) }
        return nil
    }

    /// Checks `spec` as the launcher's hotkey against the commands'. With `installed`, only installed commands'
    /// hotkeys count.
    public static func check(
        launcher spec: HotKeySpec, commands: [String: HotKeySpec], installed: Set<String>? = nil
    ) -> HotKeyConflict? {
        guard spec.isAllowed else { return .needsModifier }
        let holders = commands.filter { $0.value.sameKeys(as: spec) && (installed?.contains($0.key) ?? true) }
        if let other = holders.keys.min() { return .command(other) }
        return nil
    }

    /// "Removed from <commands>, which isn't installed", for the hotkeys a new one took over (`displaced`), each named by
    /// `title`; a deleted quicklink's key (`QuicklinkCommands.nameWhenGone`) is named as one, never as uninstalled.
    /// Nil for none.
    public static func displacedNote(_ displaced: [String], title: (String) -> String) -> String? {
        let quicklinks = displaced.filter { QuicklinkCommands.nameWhenGone($0) != nil }.count
        let commands = displaced.filter { QuicklinkCommands.nameWhenGone($0) == nil }.map(title)
        var parts: [String] = []
        if !commands.isEmpty {
            let names = commands.formatted(.list(type: .and))
            parts.append(commands.count == 1 ? "\(names), which isn't installed" : "\(names), which aren't installed")
        }
        if quicklinks > 0 {
            parts.append(quicklinks == 1 ? QuicklinkCommands.deletedName : "\(quicklinks) deleted quicklinks")
        }
        return parts.isEmpty ? nil : "Removed from " + parts.joined(separator: ", and from ")
    }

    /// The commands that aren't installed whose saved hotkey is `spec`'s keys: taking those keys clears theirs.
    public static func displaced(
        by spec: HotKeySpec, except commandID: String? = nil, commands: [String: HotKeySpec], installed: Set<String>
    ) -> [String] {
        commands.filter { $0.key != commandID && !installed.contains($0.key) && $0.value.sameKeys(as: spec) }
            .keys.sorted()
    }
}

/// How messages name a command: its title, with its extension's (or built-in group's) title when another command has
/// the same title ("Search Projects (VS Code Project Manager)").
public enum CommandNames {
    /// Nil when `commandID` is neither an installed command nor one of Fudge's own in `groups`.
    public static func name(
        of commandID: String, in installed: [InstalledExtension],
        groups: [BuiltInCommandGroup] = BuiltInCommandGroup.all
    ) -> String? {
        var titles: [(id: String, title: String, extensionTitle: String)] = []
        for group in groups {
            for command in group.commands { titles.append((group.commandID(command), command.title, group.title)) }
        }
        for item in installed {
            for command in item.manifest.commands {
                titles.append(
                    (
                        FudgeSettings.commandID(owner: .extension(item.id), command: command.name), command.title,
                        item.displayTitle
                    ))
            }
        }
        guard let found = titles.first(where: { $0.id == commandID }) else { return nil }
        let shared = titles.contains { $0.id != commandID && $0.title == found.title }
        return shared ? "\(found.title) (\(found.extensionTitle))" : found.title
    }
}

/// Which hotkey is being recorded, if any, and when that means suspending or resuming Fudge's hotkeys. A recording
/// ends with no change on Esc, when the window closes, and when the page or onboarding step changes, so hotkeys are
/// never left suspended behind a recording that's no longer on screen.
public struct HotKeyRecorder: Sendable, Equatable {
    public private(set) var recording: String?

    public init() {}

    /// Starts recording `id`. True when hotkeys must be suspended: nothing was recording yet.
    public mutating func start(_ id: String) -> Bool {
        defer { recording = id }
        return recording == nil
    }

    /// Ends the recording without a change. True when hotkeys must resume.
    public mutating func end() -> Bool {
        guard recording != nil else { return false }
        recording = nil
        return true
    }

    /// The page (or onboarding step) changed from `old` to `new`: a recording ends. True when hotkeys must resume.
    public mutating func pageChanged(from old: String?, to new: String?) -> Bool {
        old == new ? false : end()
    }
}

/// What a key press means while a hotkey is being recorded, on the Commands page and the General page alike: Esc
/// alone cancels, ⌫ or ⌦ alone clears, and anything else is the new hotkey, checked afterwards (`HotKeyConflict`).
public enum HotKeyRecording: Sendable, Equatable {
    case cancel
    case clear
    case record(HotKeySpec)

    public init(keyCode: UInt32, command: Bool, option: Bool, control: Bool, shift: Bool) {
        let modified = command || option || control || shift
        let deletes = [HotKeySpec.keyCodes["delete"], HotKeySpec.keyCodes["forwarddelete"]]
        if !modified, keyCode == HotKeySpec.keyCodes["escape"] {
            self = .cancel
        } else if !modified, deletes.contains(keyCode) {
            self = .clear
        } else {
            self = .record(
                HotKeySpec(keyCode: keyCode, command: command, option: option, control: control, shift: shift))
        }
    }

    /// What it does to the launcher's hotkey, which can't be empty: clearing sets the default ⌥Space instead. A
    /// command's hotkey wins over a new launcher hotkey, so that one is refused.
    public func launcherEdit(commands: [String: HotKeySpec], installed: Set<String>? = nil) -> LauncherHotkeyEdit {
        let spec: HotKeySpec
        switch self {
        case .cancel: return .keep
        case .clear: spec = .default
        case .record(let recorded): spec = recorded
        }
        if let conflict = HotKeyConflict.check(launcher: spec, commands: commands, installed: installed) {
            return .refused(conflict)
        }
        return .set(spec)
    }
}

/// A recording's outcome for the launcher's hotkey.
public enum LauncherHotkeyEdit: Sendable, Equatable {
    case keep
    case set(HotKeySpec)
    case refused(HotKeyConflict)
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
