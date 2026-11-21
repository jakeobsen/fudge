import AppKit
import Foundation
import Testing

@testable import FudgeCore

// The System commands (SPEC-087) run against a fake that only records: no test locks, sleeps, restarts, logs out,
// empties the Trash, ejects, changes the appearance, hides or quits anything, or sends an Apple Event.

private let me: Int32 = 100

@MainActor
private final class FakeSystem: SystemActions {
    var keysAllowed = true
    var permission: [AutomationTarget: Int32] = [:]
    var trash: Result<Int, AppleEventError> = .success(3)
    var dark = false
    var volumes: [MountedVolume] = []
    /// Volume names that won't eject, with the reason.
    var ejectFailures: [String: String] = [:]
    var apps: [RunningApp] = []
    /// What everything asked or did, in order.
    private(set) var done: [String] = []

    func mayPostKeys() -> Bool { keysAllowed }
    func lockScreen() async throws { done.append("lock") }
    func sleep() async throws { done.append("sleep") }
    func automation(of target: AutomationTarget) async -> Int32 {
        done.append("ask \(target.rawValue)")
        return permission[target] ?? 0
    }
    func send(_ event: LoginWindowEvent) async throws { done.append("send \(event.rawValue)") }
    func trashCount() async throws -> Int {
        done.append("count")
        return try trash.get()
    }
    func emptyTrash() async throws { done.append("empty") }
    func darkMode() async throws -> Bool { dark }
    func setDarkMode(_ on: Bool) async throws { done.append("dark \(on)") }
    func mountedVolumes() async -> [MountedVolume] { volumes }
    func eject(_ volume: MountedVolume) async throws {
        if let reason = ejectFailures[volume.name] {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        done.append("eject \(volume.name)")
    }
    func runningApps() -> [RunningApp] { apps }
    func hide(_ app: RunningApp) { done.append("hide \(app.pid)") }
    func quit(_ app: RunningApp) { done.append("quit \(app.pid)") }
}

/// Runs `command`, answering every confirmation with `answer` and recording what was asked.
@MainActor
private func run(
    _ command: SystemCommand, on system: FakeSystem, answer: Bool = true,
    whileAsking: @escaping () -> Void = {}
) async -> (message: String?, asked: [SystemConfirmation]) {
    var asked: [SystemConfirmation] = []
    let message = await SystemCommandRunner(actions: system, ownPid: me).run(command) { confirmation in
        asked.append(confirmation)
        whileAsking()
        return answer
    }
    return (message, asked)
}

private func volume(
    _ name: String, ejectable: Bool = false, removable: Bool = false, local: Bool = true, root: Bool = false
)
    -> MountedVolume
{
    MountedVolume(
        url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name, isEjectable: ejectable, isRemovable: removable,
        isLocal: local, isRootFileSystem: root)
}

@Test func theSystemGroupListsTheCommands() {
    let group = BuiltInCommandGroup.system
    #expect(group.name == ":system" && BuiltInCommandGroup.isValidName(group.name))
    #expect(BuiltInCommandGroup.all.map(\.title) == ["Apps", "System", "Window Management"], "by title")
    #expect(
        group.commands.map(\.title) == [
            "Lock Screen", "Sleep", "Restart", "Shut Down", "Log Out", "Empty Trash", "Eject All Disks",
            "Toggle Dark Mode", "Hide All Apps", "Quit All Apps",
        ])
    #expect(group.commands.map(\.name) == SystemCommand.allCases.map(\.rawValue), "the settings.json ids")
    #expect(group.commands.allSatisfy { ExtensionManifest.isValidName($0.name) })
    for command in group.commands {
        #expect(NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) != nil, "\(command.symbol)")
        #expect(command.keywords.contains("system"))
    }
    #expect(group.commands.first { $0.title == "Toggle Dark Mode" }?.keywords.contains("appearance") == true)
}

@Test func onlyTheCommandsThatCantBeUndoneAskFirst() {
    #expect(
        Set(SystemCommand.allCases.filter(\.asksFirst)) == [.restart, .shutDown, .logOut, .emptyTrash, .quitAllApps])
}

@MainActor
@Test func aCancelledConfirmationDoesNothing() async {
    for command in SystemCommand.allCases where command.asksFirst {
        let system = FakeSystem()
        system.apps = [RunningApp(pid: 200, bundleIdentifier: "com.apple.TextEdit", isRegular: true)]
        let (message, asked) = await run(command, on: system, answer: false)
        #expect(message == nil)
        #expect(asked.count == 1, "\(command) asks once")
        #expect(asked.first.map { !$0.primary.isEmpty && $0.dismiss == "Cancel" } == true)
        let acted = system.done.filter { $0.hasPrefix("send") || $0 == "empty" || $0.hasPrefix("quit") }
        #expect(acted.isEmpty, "\(command) did \(acted)")
    }
}

@MainActor
@Test func restartShutDownAndLogOutAskThenGoThroughLoginWindow() async {
    let events: [(SystemCommand, String, SystemConfirmation)] = [
        (.restart, "rest", .restart), (.shutDown, "shut", .shutDown), (.logOut, "rlgo", .logOut),
    ]
    for (command, id, confirmation) in events {
        let system = FakeSystem()
        let (message, asked) = await run(command, on: system)
        #expect(message == nil)
        #expect(asked == [confirmation])
        // Fudge's own question first, then Automation of loginwindow, then the event.
        #expect(system.done == ["ask loginwindow", "send \(id)"])
    }
    #expect(SystemConfirmation.restart.title == "Restart your Mac?" && SystemConfirmation.restart.primary == "Restart")
    #expect(SystemConfirmation.logOut.primary == "Log Out")
}

@MainActor
@Test func aRefusedLoginWindowSaysWhereToAllowIt() async {
    let system = FakeSystem()
    system.permission[.loginWindow] = -1743
    let (message, _) = await run(.shutDown, on: system)
    #expect(
        message == "Fudge isn't allowed to control loginwindow. "
            + "Allow it in System Settings → Privacy & Security → Automation.")
    #expect(!system.done.contains { $0.hasPrefix("send") })
}

@MainActor
@Test func emptyTrashCountsThroughFinderThenAsksWithTheCount() async {
    let system = FakeSystem()
    system.trash = .success(5)
    let (message, asked) = await run(.emptyTrash, on: system)
    #expect(message == nil)
    #expect(system.done == ["ask Finder", "count", "empty"])
    #expect(asked == [.emptyTrash(items: 5)])
    #expect(asked.first?.title == "Empty the Trash?")
    #expect(asked.first?.message == "5 items will be deleted permanently.")
    #expect(asked.first?.primary == "Empty Trash")
    #expect(SystemConfirmation.emptyTrash(items: 1).message == "1 item will be deleted permanently.")
}

@MainActor
@Test func emptyTrashAlwaysAsksEvenWhenTheCountIsZeroOrUnreadable() async {
    let withoutNumber = "The items in the Trash will be deleted permanently."
    // A count of 0, a reply that isn't a number, or Finder failing: the same question, without a number.
    let failures: [Result<Int, AppleEventError>] = [
        .success(0), .failure(AppleEventError(status: SystemAppleEvents.coercionFailed)),
        .failure(AppleEventError(status: -600)), .failure(AppleEventError(status: -1712)),
    ]
    for count in failures {
        let system = FakeSystem()
        system.trash = count
        let (message, asked) = await run(.emptyTrash, on: system)
        #expect(message == nil, "\(count)")
        #expect(asked.map(\.message) == [withoutNumber], "\(count)")
        #expect(system.done == ["ask Finder", "count", "empty"], "\(count)")
    }
    #expect(SystemConfirmation.emptyTrash(items: nil).message == withoutNumber)
    #expect(SystemConfirmation.emptyTrash(items: 0) == SystemConfirmation.emptyTrash(items: nil))

    // Cancel empties nothing, with a number or without.
    for count in [Result<Int, AppleEventError>.success(5), .success(0)] {
        let system = FakeSystem()
        system.trash = count
        let (message, asked) = await run(.emptyTrash, on: system, answer: false)
        #expect(message == nil && asked.count == 1)
        #expect(!system.done.contains("empty"))
    }
}

@MainActor
@Test func aRefusedFinderSaysSoAndAsksNothing() async {
    let refused = FakeSystem()
    refused.permission[.finder] = -1743
    let (refusal, asked) = await run(.emptyTrash, on: refused)
    #expect(
        refusal == "Fudge isn't allowed to control Finder. "
            + "Allow it in System Settings → Privacy & Security → Automation.")
    #expect(refused.done == ["ask Finder"])
    #expect(asked.isEmpty)
}

@Test func theTrashCountIsAskedForAsAppleScriptDoes() throws {
    let code = SystemAppleEvents.code
    let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
    let event = SystemAppleEvents.countTrash(to: finder)
    #expect(event.eventClass == code("core") && event.eventID == code("cnte"))
    // `kocl`: the class to count, items.
    #expect(event.paramDescriptor(forKeyword: code("kocl"))?.typeCodeValue == code("cobj"))
    // `----`: the Trash itself, `property trsh of the application`, never `every item of trash`.
    let direct = try #require(event.paramDescriptor(forKeyword: code("----")))
    #expect(direct.descriptorType == code("obj "))
    #expect(direct.forKeyword(code("want"))?.typeCodeValue == code("prop"))
    #expect(direct.forKeyword(code("form"))?.enumCodeValue == code("prop"))
    #expect(direct.forKeyword(code("seld"))?.typeCodeValue == code("trsh"))
    #expect(direct.forKeyword(code("from"))?.descriptorType == code("null"))
}

@Test func aCountIsReadOnlyFromANumber() throws {
    let code = SystemAppleEvents.code
    func reply(_ value: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("aevt"), eventID: code("ansr"), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let value { reply.setParam(value, forKeyword: code("----")) }
        return reply
    }
    #expect(try SystemAppleEvents.count(in: reply(NSAppleEventDescriptor(int32: 7))) == 7)
    #expect(try SystemAppleEvents.count(in: reply(NSAppleEventDescriptor(int32: 0))) == 0)
    // A list (what counting `every item of trash` by `cobj` can give) or nothing at all throws: never 0.
    let list = NSAppleEventDescriptor.list()
    list.insert(NSAppleEventDescriptor(int32: 0), at: 1)
    list.insert(NSAppleEventDescriptor(int32: 0), at: 2)
    #expect(throws: AppleEventError(status: SystemAppleEvents.coercionFailed)) {
        try SystemAppleEvents.count(in: reply(list))
    }
    #expect(throws: AppleEventError(status: SystemAppleEvents.coercionFailed)) {
        try SystemAppleEvents.count(in: reply(nil))
    }
    #expect(throws: AppleEventError.self) { try SystemAppleEvents.count(in: reply(.init(string: "lots"))) }
    // Dark mode's yes or no is read as strictly.
    #expect(try SystemAppleEvents.boolean(in: reply(NSAppleEventDescriptor(boolean: true))))
    #expect(try !SystemAppleEvents.boolean(in: reply(NSAppleEventDescriptor(boolean: false))))
    #expect(throws: AppleEventError.self) { try SystemAppleEvents.boolean(in: reply(nil)) }
    #expect(throws: AppleEventError.self) { try SystemAppleEvents.boolean(in: reply(list)) }
}

@Test func ejectAllDisksTakesEjectableRemovableAndNetworkVolumesOnly() {
    let volumes = [
        volume("Macintosh HD", root: true),
        volume("Macintosh HD", ejectable: true, removable: true, root: true),
        volume("Internal Data"),
        volume("Stick", ejectable: true, removable: true),
        volume("Card", removable: true),
        volume("Installer", ejectable: true),
        volume("Share", local: false),
    ]
    #expect(MountedVolume.toEject(volumes).map(\.name) == ["Stick", "Card", "Installer", "Share"])
}

@MainActor
@Test func ejectAllDisksSaysWhatItEjectedAndWhatItCouldnt() async {
    let system = FakeSystem()
    system.volumes = [
        volume("Macintosh HD", root: true), volume("Stick", ejectable: true), volume("Share", local: false),
    ]
    #expect(await run(.ejectAllDisks, on: system).message == "Ejected Stick and Share.")
    #expect(system.done == ["eject Stick", "eject Share"])

    let busy = FakeSystem()
    busy.volumes = [
        volume("Stick", ejectable: true), volume("Backup", ejectable: true), volume("Card", removable: true),
    ]
    busy.ejectFailures = ["Backup": "The volume is in use"]
    #expect(
        await run(.ejectAllDisks, on: busy).message
            == "Ejected Stick and Card. Couldn't eject Backup: The volume is in use.")

    let none = FakeSystem()
    none.volumes = [volume("Macintosh HD", root: true)]
    #expect(await run(.ejectAllDisks, on: none).message == "There's nothing to eject.")
    #expect(none.done.isEmpty)
    #expect(SystemCommandMessage.ejected(["A", "B", "C"], failed: []) == "Ejected A, B and C.")
}

@Test func hideAndQuitListsLeaveOutFudgeFinderAndBackgroundApps() {
    let apps = [
        RunningApp(pid: me, bundleIdentifier: "io.github.jakeobsen.fudge", isRegular: true),
        RunningApp(pid: 1, bundleIdentifier: "com.apple.finder", isRegular: true),
        RunningApp(pid: 2, bundleIdentifier: "com.apple.TextEdit", isRegular: true),
        RunningApp(pid: 3, bundleIdentifier: "com.example.menu-bar-helper", isRegular: false),
        RunningApp(pid: 4, bundleIdentifier: nil, isRegular: true),
    ]
    #expect(RunningApp.toHide(apps, ownPid: me).map(\.pid) == [1, 2, 4], "never Fudge, regular apps only")
    #expect(RunningApp.toQuit(apps, ownPid: me).map(\.pid) == [2, 4], "never Fudge or Finder")
}

@MainActor
@Test func hideAllAppsHidesWithoutAsking() async {
    let system = FakeSystem()
    system.apps = [
        RunningApp(pid: me, bundleIdentifier: "io.github.jakeobsen.fudge", isRegular: true),
        RunningApp(pid: 1, bundleIdentifier: "com.apple.finder", isRegular: true),
        RunningApp(pid: 2, bundleIdentifier: "com.apple.TextEdit", isRegular: true),
    ]
    let (message, asked) = await run(.hideAllApps, on: system)
    #expect(message == nil && asked.isEmpty)
    #expect(system.done == ["hide 1", "hide 2"])
}

@MainActor
@Test func quitAllAppsAsksWithTheCountAndReadsTheListAgainWhenConfirmed() async {
    let system = FakeSystem()
    let textEdit = RunningApp(pid: 2, bundleIdentifier: "com.apple.TextEdit", isRegular: true)
    system.apps = [RunningApp(pid: 1, bundleIdentifier: "com.apple.finder", isRegular: true), textEdit]
    // Mail opens while the alert is up, and TextEdit quits by itself: what's quit is what's running when confirmed.
    let mail = RunningApp(pid: 5, bundleIdentifier: "com.apple.mail", isRegular: true)
    let (message, asked) = await run(.quitAllApps, on: system) { system.apps = [system.apps[0], mail] }
    #expect(message == nil)
    #expect(asked == [.quitAllApps(1)])
    #expect(asked.first?.message == "1 app will quit. Apps with unsaved work ask about it first.")
    #expect(SystemConfirmation.quitAllApps(7).message.hasPrefix("7 apps will quit."))
    #expect(system.done == ["quit 5"])

    let alone = FakeSystem()
    alone.apps = [RunningApp(pid: 1, bundleIdentifier: "com.apple.finder", isRegular: true)]
    let (none, askedNone) = await run(.quitAllApps, on: alone)
    #expect(none == "There are no apps to quit." && askedNone.isEmpty)
}

@MainActor
@Test func toggleDarkModeFlipsTheAppearanceThroughSystemEvents() async {
    let light = FakeSystem()
    light.dark = false
    #expect(await run(.toggleDarkMode, on: light).message == nil)
    #expect(light.done == ["ask System Events", "dark true"])

    let dark = FakeSystem()
    dark.dark = true
    _ = await run(.toggleDarkMode, on: dark)
    #expect(dark.done == ["ask System Events", "dark false"])

    let refused = FakeSystem()
    refused.permission[.systemEvents] = -1743
    #expect(await run(.toggleDarkMode, on: refused).message == SystemCommandMessage.automationDenied(.systemEvents))
    #expect(refused.done == ["ask System Events"])
}

@MainActor
@Test func lockScreenNeedsAccessibilityAndSleepJustSleeps() async {
    let refused = FakeSystem()
    refused.keysAllowed = false
    #expect(await run(.lockScreen, on: refused).message == "Fudge needs Accessibility permission to lock the screen.")
    #expect(refused.done.isEmpty)

    let allowed = FakeSystem()
    #expect(await run(.lockScreen, on: allowed).message == nil)
    #expect(allowed.done == ["lock"])

    let sleeper = FakeSystem()
    let (message, asked) = await run(.sleep, on: sleeper)
    #expect(message == nil && asked.isEmpty && sleeper.done == ["sleep"])
}

@Test func lockScreensKeyIsTheOneThatTypesQ() {
    // QWERTY: the ANSI Q key types "q".
    #expect(LockScreenKey.keyCode { $0 == 12 ? "q" : "x" } == 12)
    // A layout where Q is elsewhere (Dvorak puts it on the ANSI X key, 7).
    #expect(LockScreenKey.keyCode { $0 == 7 ? "q" : "z" } == 7)
}

@MainActor
@Test func snapshotRunsGetMadeUpAnswersAndDoNothing() async {
    var asked: [SystemConfirmation] = []
    let runner = SystemCommandRunner(actions: InertSystemActions(), ownPid: me)
    let message = await runner.run(.emptyTrash) {
        asked.append($0)
        return false
    }
    #expect(message == nil)
    #expect(asked == [.emptyTrash(items: InertSystemActions.trashCount)])
    #expect(await runner.run(.lockScreen) { _ in true } == SystemCommandMessage.lockNeedsAccessibility)
    // `--trash-count` with no number: the confirmation without one.
    let unreadable = SystemCommandRunner(actions: InertSystemActions(trashCount: nil), ownPid: me)
    _ = await unreadable.run(.emptyTrash) {
        asked.append($0)
        return false
    }
    #expect(asked.last == .emptyTrash(items: nil))
}
