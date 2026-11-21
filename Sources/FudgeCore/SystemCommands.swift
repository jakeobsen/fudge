import Foundation

// The System group of Fudge's own commands (SPEC-087): Lock Screen, Sleep, Restart, Shut Down, Log Out, Empty Trash,
// Eject All Disks, Toggle Dark Mode, Hide All Apps and Quit All Apps. Every decision lives here; the app does the
// system's part through `SystemActions`, and tests use a fake that only records, so no test locks, sleeps, restarts,
// logs out, empties the Trash, ejects, changes the appearance, hides or quits anything.

/// One of the System group's commands, named by its raw value in `settings.json` (`:system/<raw value>`).
public enum SystemCommand: String, CaseIterable, Sendable {
    case lockScreen = "lock-screen"
    case sleep
    case restart
    case shutDown = "shut-down"
    case logOut = "log-out"
    case emptyTrash = "empty-trash"
    case ejectAllDisks = "eject-all-disks"
    case toggleDarkMode = "toggle-dark-mode"
    case hideAllApps = "hide-all-apps"
    case quitAllApps = "quit-all-apps"

    /// Whether it asks through Fudge's confirm alert before doing anything.
    public var asksFirst: Bool {
        switch self {
        case .restart, .shutDown, .logOut, .emptyTrash, .quitAllApps: true
        default: false
        }
    }

    /// The command's title, extra search words and SF Symbol.
    var presentation: (String, [String], String) {
        switch self {
        case .lockScreen: ("Lock Screen", ["lock", "away"], "lock")
        case .sleep: ("Sleep", ["sleep", "suspend"], "moon.zzz")
        case .restart: ("Restart", ["reboot", "restart"], "arrow.clockwise")
        case .shutDown: ("Shut Down", ["shutdown", "power off", "turn off"], "power")
        case .logOut: ("Log Out", ["logout", "sign out"], "rectangle.portrait.and.arrow.right")
        case .emptyTrash: ("Empty Trash", ["trash", "bin", "delete"], "trash")
        case .ejectAllDisks: ("Eject All Disks", ["eject", "unmount", "drive", "volume"], "eject")
        case .toggleDarkMode:
            (
                "Toggle Dark Mode", ["dark", "light", "appearance", "theme", "system appearance"],
                "circle.lefthalf.filled"
            )
        case .hideAllApps: ("Hide All Apps", ["hide", "desktop"], "eye.slash")
        case .quitAllApps: ("Quit All Apps", ["quit", "close", "apps"], "xmark.rectangle")
        }
    }
}

extension BuiltInCommandGroup {
    /// System: one command per `SystemCommand`, named by its raw value.
    public static let system = BuiltInCommandGroup(
        name: ":system", title: "System",
        commands: SystemCommand.allCases.map { command in
            let (title, keywords, symbol) = command.presentation
            return BuiltInCommand(
                name: command.rawValue, title: title, keywords: keywords + ["system"], symbol: symbol)
        })
}

/// The key that types "q" with ⌘ held, so Lock Screen's ⌃⌘Q is the shortcut on any keyboard layout, as ⌘C and ⌘V
/// are (`CopyKey`).
public enum LockScreenKey {
    /// `kVK_ANSI_Q`.
    public static let ansiKeyCode: UInt16 = 12

    public static func keyCode(translate: (UInt16) -> String?) -> UInt16 {
        CommandKey.keyCode(typing: "q", ansiKeyCode: ansiKeyCode, translate: translate)
    }
}

/// An app that's running, as Hide All Apps and Quit All Apps see it.
public struct RunningApp: Sendable, Equatable {
    public var pid: Int32
    public var bundleIdentifier: String?
    /// Whether it's a regular app, one with a Dock icon (`NSApplication.ActivationPolicy.regular`).
    public var isRegular: Bool

    public init(pid: Int32, bundleIdentifier: String?, isRegular: Bool) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.isRegular = isRegular
    }

    public static let finder = "com.apple.finder"

    /// What Hide All Apps hides: every regular app but Fudge.
    public static func toHide(_ apps: [RunningApp], ownPid: Int32) -> [RunningApp] {
        apps.filter { $0.isRegular && $0.pid != ownPid }
    }

    /// What Quit All Apps quits: every regular app but Fudge and Finder.
    public static func toQuit(_ apps: [RunningApp], ownPid: Int32) -> [RunningApp] {
        toHide(apps, ownPid: ownPid).filter { $0.bundleIdentifier != finder }
    }
}

/// A mounted volume, as Eject All Disks sees it (`URLResourceValues`).
public struct MountedVolume: Sendable, Equatable {
    public var url: URL
    public var name: String
    public var isEjectable: Bool
    public var isRemovable: Bool
    public var isLocal: Bool
    public var isRootFileSystem: Bool

    public init(url: URL, name: String, isEjectable: Bool, isRemovable: Bool, isLocal: Bool, isRootFileSystem: Bool) {
        self.url = url
        self.name = name
        self.isEjectable = isEjectable
        self.isRemovable = isRemovable
        self.isLocal = isLocal
        self.isRootFileSystem = isRootFileSystem
    }

    /// What Eject All Disks ejects: ejectable, removable and network volumes, never the one macOS started from.
    public static func toEject(_ volumes: [MountedVolume]) -> [MountedVolume] {
        volumes.filter { !$0.isRootFileSystem && ($0.isEjectable || $0.isRemovable || !$0.isLocal) }
    }
}

/// An app the System commands send Apple Events to, which needs Automation permission.
public enum AutomationTarget: String, Sendable, CaseIterable {
    case finder = "Finder"
    case systemEvents = "System Events"
    /// macOS's `loginwindow`, which restarts, shuts down and logs out (Apple's QA1134).
    case loginWindow = "loginwindow"
}

/// What `loginwindow` is asked to do, with its Apple Event id (kCoreEventClass `aevt`).
public enum LoginWindowEvent: String, Sendable {
    /// `kAERestart`: restart without the system's own dialog, since Fudge asked first.
    case restart = "rest"
    /// `kAEShutDown`.
    case shutDown = "shut"
    /// `kAEReallyLogOut`: log out without the system's own dialog (`kAELogOut` would ask a second time). Apps still
    /// get asked to quit, so those with unsaved work ask about it.
    case logOut = "rlgo"
}

/// The system's part of the System commands. The app's runs each off the main thread where it can wait on another
/// app; tests' only records.
@MainActor
public protocol SystemActions: AnyObject {
    /// Whether Fudge may post key events (Accessibility), asking as a user-initiated call does.
    func mayPostKeys() -> Bool
    /// Posts ⌃⌘Q, the system's Lock Screen shortcut.
    func lockScreen() async throws
    /// `IOPMSleepSystem`.
    func sleep() async throws
    /// Whether Fudge may send `target` Apple Events, asking the user if they haven't decided: the OSStatus of
    /// `AEDeterminePermissionToAutomateTarget`, 0 when it may.
    func automation(of target: AutomationTarget) async -> Int32
    func send(_ event: LoginWindowEvent) async throws
    /// Finder's `count items of trash`. Throws `AppleEventError`.
    func trashCount() async throws -> Int
    /// Finder's `empty trash`. Throws `AppleEventError`.
    func emptyTrash() async throws
    /// System Events' `dark mode of appearance preferences`. Throws `AppleEventError`.
    func darkMode() async throws -> Bool
    func setDarkMode(_ on: Bool) async throws
    func mountedVolumes() async -> [MountedVolume]
    /// Unmounts and ejects `volume`; the error's description says why it couldn't.
    func eject(_ volume: MountedVolume) async throws
    func runningApps() -> [RunningApp]
    func hide(_ app: RunningApp)
    func quit(_ app: RunningApp)
}

/// Snapshot runs' System actions: made-up answers, and nothing done. A snapshot run never locks, sleeps, restarts,
/// logs out, empties the Trash, ejects, changes the appearance, hides or quits anything, and sends no Apple Event.
@MainActor
public final class InertSystemActions: SystemActions {
    /// The made-up Trash count the Empty Trash confirmation shows.
    public static let trashCount = 12

    public init() {}

    public func mayPostKeys() -> Bool { false }
    public func lockScreen() async throws {}
    public func sleep() async throws {}
    public func automation(of target: AutomationTarget) async -> Int32 { 0 }
    public func send(_ event: LoginWindowEvent) async throws {}
    public func trashCount() async throws -> Int { Self.trashCount }
    public func emptyTrash() async throws {}
    public func darkMode() async throws -> Bool { false }
    public func setDarkMode(_ on: Bool) async throws {}
    public func mountedVolumes() async -> [MountedVolume] { [] }
    public func eject(_ volume: MountedVolume) async throws {}
    public func runningApps() -> [RunningApp] { [] }
    public func hide(_ app: RunningApp) {}
    public func quit(_ app: RunningApp) {}
}

/// What a System command asks before it acts: an alert with the action as its destructive button.
public struct SystemConfirmation: Sendable, Equatable {
    public var title: String
    public var message: String
    public var primary: String
    public let dismiss = "Cancel"

    public static let restart = SystemConfirmation(
        title: "Restart your Mac?", message: "Open apps quit first, and ask about unsaved work.", primary: "Restart")
    public static let shutDown = SystemConfirmation(
        title: "Shut down your Mac?", message: "Open apps quit first, and ask about unsaved work.",
        primary: "Shut Down")
    public static let logOut = SystemConfirmation(
        title: "Log out?", message: "Open apps quit first, and ask about unsaved work.", primary: "Log Out")

    public static func emptyTrash(items: Int) -> SystemConfirmation {
        SystemConfirmation(
            title: "Empty the Trash?",
            message: "\(items) \(items == 1 ? "item" : "items") will be deleted permanently.",
            primary: "Empty Trash")
    }

    public static func quitAllApps(_ apps: Int) -> SystemConfirmation {
        SystemConfirmation(
            title: "Quit all apps?",
            message: "\(apps) \(apps == 1 ? "app" : "apps") will quit. Apps with unsaved work ask about it first.",
            primary: "Quit All")
    }
}

/// What the HUD says after a System command, when it says anything.
public enum SystemCommandMessage {
    public static let lockNeedsAccessibility = "Fudge needs Accessibility permission to lock the screen."
    public static let trashIsEmpty = "The Trash is empty."
    public static let nothingToEject = "There's nothing to eject."
    public static let noAppsToQuit = "There are no apps to quit."

    /// The user said no to Automation of `target`, so say where to allow it.
    public static func automationDenied(_ target: AutomationTarget) -> String {
        "Fudge isn't allowed to control \(target.rawValue). "
            + "Allow it in System Settings → Privacy & Security → Automation."
    }

    /// An Apple Event to `target` failed while `doing` (e.g. "count the Trash").
    public static func appleEventFailed(_ status: Int, target: AutomationTarget, doing: String) -> String {
        switch status {
        case notPermitted: automationDenied(target)
        case timedOut: "\(target.rawValue) didn't answer in time."
        default: "Couldn't \(doing) (error \(status))."
        }
    }

    /// What Eject All Disks did: what it ejected, then each volume it couldn't, with the reason.
    public static func ejected(_ names: [String], failed: [(name: String, reason: String)]) -> String {
        var parts: [String] = []
        if !names.isEmpty { parts.append("Ejected \(list(names)).") }
        for failure in failed {
            let reason = failure.reason.hasSuffix(".") ? failure.reason : failure.reason + "."
            parts.append("Couldn't eject \(failure.name): \(reason)")
        }
        return parts.joined(separator: " ")
    }

    /// `errAEEventNotPermitted`.
    static let notPermitted = -1743
    /// `errAETimeout`.
    static let timedOut = -1712

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

/// Runs the System commands over `SystemActions`. Every command is user-initiated (root search or its hotkey), so
/// Automation and Accessibility are asked for as such.
@MainActor
public struct SystemCommandRunner {
    let actions: any SystemActions
    let ownPid: Int32

    public init(actions: any SystemActions, ownPid: Int32) {
        self.actions = actions
        self.ownPid = ownPid
    }

    /// Runs `command`, asking through `confirm` first when it does (`asksFirst`). Returns what the HUD says, if
    /// anything.
    public func run(_ command: SystemCommand, confirm: (SystemConfirmation) async -> Bool) async -> String? {
        switch command {
        case .lockScreen:
            guard actions.mayPostKeys() else { return SystemCommandMessage.lockNeedsAccessibility }
            return await attempt("lock the screen") { try await actions.lockScreen() }
        case .sleep:
            return await attempt("put the Mac to sleep") { try await actions.sleep() }
        case .restart:
            return await loginWindow(.restart, confirmation: .restart, doing: "restart", confirm: confirm)
        case .shutDown:
            return await loginWindow(.shutDown, confirmation: .shutDown, doing: "shut down", confirm: confirm)
        case .logOut:
            return await loginWindow(.logOut, confirmation: .logOut, doing: "log out", confirm: confirm)
        case .emptyTrash:
            return await emptyTrash(confirm: confirm)
        case .ejectAllDisks:
            return await ejectAll()
        case .toggleDarkMode:
            if let refusal = await automationRefusal(.systemEvents, doing: "change the appearance") { return refusal }
            return await appleEvent(.systemEvents, doing: "change the appearance") {
                try await actions.setDarkMode(!(try await actions.darkMode()))
            }
        case .hideAllApps:
            for app in RunningApp.toHide(actions.runningApps(), ownPid: ownPid) { actions.hide(app) }
            return nil
        case .quitAllApps:
            let count = RunningApp.toQuit(actions.runningApps(), ownPid: ownPid).count
            guard count > 0 else { return SystemCommandMessage.noAppsToQuit }
            guard await confirm(.quitAllApps(count)) else { return nil }
            // The list is read again once confirmed: what's running now, not what was when the alert opened.
            for app in RunningApp.toQuit(actions.runningApps(), ownPid: ownPid) { actions.quit(app) }
            return nil
        }
    }

    private func loginWindow(
        _ event: LoginWindowEvent, confirmation: SystemConfirmation, doing: String,
        confirm: (SystemConfirmation) async -> Bool
    ) async -> String? {
        guard await confirm(confirmation) else { return nil }
        if let refusal = await automationRefusal(.loginWindow, doing: doing) { return refusal }
        return await appleEvent(.loginWindow, doing: doing) { try await actions.send(event) }
    }

    /// Counts through Finder, never by listing `~/.Trash` (TCC-protected, and without the volumes' `.Trashes`), so
    /// one Automation answer covers counting and emptying. A refusal or a failed count says so: it's never "empty".
    private func emptyTrash(confirm: (SystemConfirmation) async -> Bool) async -> String? {
        if let refusal = await automationRefusal(.finder, doing: "count the Trash") { return refusal }
        let count: Int
        do {
            count = try await actions.trashCount()
        } catch {
            return failure(error, target: .finder, doing: "count the Trash")
        }
        guard count > 0 else { return SystemCommandMessage.trashIsEmpty }
        guard await confirm(.emptyTrash(items: count)) else { return nil }
        return await appleEvent(.finder, doing: "empty the Trash") { try await actions.emptyTrash() }
    }

    private func ejectAll() async -> String {
        let volumes = MountedVolume.toEject(await actions.mountedVolumes())
        guard !volumes.isEmpty else { return SystemCommandMessage.nothingToEject }
        var ejected: [String] = []
        var failed: [(name: String, reason: String)] = []
        for volume in volumes {
            do {
                try await actions.eject(volume)
                ejected.append(volume.name)
            } catch {
                failed.append((volume.name, (error as NSError).localizedDescription))
            }
        }
        return SystemCommandMessage.ejected(ejected, failed: failed)
    }

    /// Asks for Automation of `target` (the user decides once); a refusal, or a target that can't be asked, is the
    /// message to show.
    private func automationRefusal(_ target: AutomationTarget, doing: String) async -> String? {
        let status = await actions.automation(of: target)
        return status == 0 ? nil : SystemCommandMessage.appleEventFailed(Int(status), target: target, doing: doing)
    }

    private func appleEvent(_ target: AutomationTarget, doing: String, _ body: () async throws -> Void) async
        -> String?
    {
        do {
            try await body()
            return nil
        } catch {
            return failure(error, target: target, doing: doing)
        }
    }

    private func failure(_ error: any Error, target: AutomationTarget, doing: String) -> String {
        let status = (error as? AppleEventError)?.status ?? (error as NSError).code
        return SystemCommandMessage.appleEventFailed(status, target: target, doing: doing)
    }

    private func attempt(_ doing: String, _ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return "Couldn't \(doing): \((error as NSError).localizedDescription)"
        }
    }
}
