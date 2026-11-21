import Foundation
import Testing

@testable import FudgeCore

/// Records registrations instead of making them; `refuse` makes some fail, as when another app has the key.
private final class FakeRegistrar: HotKeyRegistering {
    var registered: [UInt32: HotKeySpec] = [:]
    var refuse: Set<String> = []
    var calls: [String] = []

    func register(_ spec: HotKeySpec, id: UInt32) -> Bool {
        calls.append("+\(id) \(spec.text)")
        guard !refuse.contains(spec.text) else { return false }
        registered[id] = spec
        return true
    }

    func unregister(id: UInt32) {
        calls.append("-\(id)")
        registered[id] = nil
    }
}

private let launcher = HotKeySpec.parse("option+space")!
private let optionS = HotKeySpec.parse("option+s")!
private let optionV = HotKeySpec.parse("option+v")!

@Test func registersOnlyWhatChanged() throws {
    let fake = FakeRegistrar()
    let registry = HotKeyRegistry(registrar: fake)
    registry.setLauncher(launcher)
    registry.apply(["scratch/folders": optionS, "vscode/search": optionV])
    #expect(Set(fake.registered.values) == [launcher, optionS, optionV])
    let folders = try #require(fake.registered.first { $0.value == optionS }?.key)
    #expect(registry.command(for: folders) == "scratch/folders")
    #expect(registry.command(for: HotKeyRegistry.launcherID) == nil)

    fake.calls = []
    registry.apply(["scratch/folders": optionS])
    #expect(fake.calls.count == 1, "only vscode/search is unregistered: \(fake.calls)")
    #expect(Set(fake.registered.values) == [launcher, optionS])
}

@Test func aRefusedHotkeyIsReportedAndRetried() {
    let fake = FakeRegistrar()
    fake.refuse = ["option+s"]
    let registry = HotKeyRegistry(registrar: fake)
    registry.apply(["scratch/folders": optionS])
    #expect(registry.refused == ["scratch/folders"])
    fake.refuse = []
    registry.apply(["scratch/folders": optionS])
    #expect(registry.refused.isEmpty, "applied again, it's tried again")
}

/// Recording a hotkey suspends them all; saving, cancelling and closing the window all resume.
@Test(arguments: ["save", "cancel", "close"])
func recordingSuspendsEveryHotkeyAndRestoresThem(ending: String) {
    let fake = FakeRegistrar()
    let registry = HotKeyRegistry(registrar: fake)
    registry.setLauncher(launcher)
    registry.apply(["scratch/folders": optionS, "vscode/search": optionV])
    registry.suspend()
    #expect(fake.registered.isEmpty, "⌥Space and ⌥S must reach the recorder, not fire")
    #expect(registry.isSuspended)

    // Changes made while suspended wait for the resume.
    if ending == "save" { registry.apply(["scratch/folders": optionS, "vscode/search": HotKeySpec.parse("f5")!]) }
    #expect(fake.registered.isEmpty)
    registry.resume()
    let expected: Set<HotKeySpec> =
        ending == "save" ? [launcher, optionS, HotKeySpec.parse("f5")!] : [launcher, optionS, optionV]
    #expect(Set(fake.registered.values) == expected)
    #expect(!registry.isSuspended)
}

@Test func conflicts() {
    let commands = ["scratch/folders": optionS]
    #expect(
        HotKeyConflict.check(optionS, for: "vscode/search", launcher: launcher, commands: commands)
            == .command("scratch/folders"))
    #expect(
        HotKeyConflict.check(optionS, for: "scratch/folders", launcher: launcher, commands: commands) == nil, "its own")
    #expect(HotKeyConflict.check(launcher, for: "vscode/search", launcher: launcher, commands: commands) == .launcher)
    #expect(
        HotKeyConflict.check(HotKeySpec(keyCode: 1), for: "a/b", launcher: launcher, commands: [:]) == .needsModifier)
    #expect(
        HotKeyConflict.check(HotKeySpec(keyCode: 1, shift: true), for: "a/b", launcher: launcher, commands: [:])
            == .needsModifier)
    #expect(
        HotKeyConflict.check(HotKeySpec.parse("f5")!, for: "a/b", launcher: launcher, commands: [:]) == nil,
        "an F-key alone")
}

@Test func whatAHotkeyPressDoes() {
    #expect(HotKeyLaunch.action(mode: "view", hasRequiredArgument: false, isOnScreen: false) == .open)
    #expect(HotKeyLaunch.action(mode: "no-view", hasRequiredArgument: false, isOnScreen: false) == .open)
    #expect(HotKeyLaunch.action(mode: "view", hasRequiredArgument: false, isOnScreen: true) == .hidePanel, "toggles")
    #expect(HotKeyLaunch.action(mode: "no-view", hasRequiredArgument: true, isOnScreen: false) == .askForArguments)
    #expect(HotKeyLaunch.action(mode: "view", hasRequiredArgument: true, isOnScreen: true) == .hidePanel)
}

@Test func aHotkeyRunLeavesRootSearchAlone() {
    #expect(LaunchOrigin.rootSearch.clearsRootSearchWhenFinished)
    #expect(!LaunchOrigin.hotkey.clearsRootSearchWhenFinished, "a no-view command run by hotkey keeps the query")
}

private let cmdShiftK = HotKeySpec.parse("cmd+shift+k")!

@Test func changingTheLauncherHotkeyMovesItsRegistration() {
    let fake = FakeRegistrar()
    let registry = HotKeyRegistry(registrar: fake)
    #expect(registry.setLauncher(launcher))
    fake.calls = []
    #expect(registry.setLauncher(cmdShiftK))
    #expect(fake.calls == ["-1", "+1 shift+cmd+k"])
    #expect(fake.registered == [HotKeyRegistry.launcherID: cmdShiftK])
    #expect(registry.launcher == cmdShiftK)
    #expect(!registry.launcherRefused)
}

@Test func aRefusedLauncherHotkeyKeepsTheOldOneRegistered() {
    let fake = FakeRegistrar()
    let registry = HotKeyRegistry(registrar: fake)
    registry.setLauncher(launcher)
    fake.refuse = ["shift+cmd+k"]
    #expect(!registry.setLauncher(cmdShiftK), "another app has ⇧⌘K")
    #expect(fake.registered == [HotKeyRegistry.launcherID: launcher], "⌥Space is registered again")
    #expect(registry.launcher == launcher)
    #expect(!registry.launcherRefused)
}

@Test func aLauncherHotkeyRefusedAtLaunchIsMarkedAndTriedAgainOnResume() {
    let fake = FakeRegistrar()
    fake.refuse = ["option+space"]
    let registry = HotKeyRegistry(registrar: fake)
    #expect(!registry.setLauncher(launcher), "Raycast holds ⌥Space")
    #expect(registry.launcher == launcher)
    #expect(registry.launcherRefused)
    #expect(fake.registered.isEmpty)

    // Recording suspends and resumes everything; by then the other app may have let go.
    registry.suspend()
    #expect(!fake.calls.contains("-1"), "nothing to unregister")
    fake.refuse = []
    registry.resume()
    #expect(!registry.launcherRefused)
    #expect(fake.registered == [HotKeyRegistry.launcherID: launcher])

    // A new hotkey after a refused one doesn't unregister anything first.
    let other = FakeRegistrar()
    other.refuse = ["option+space"]
    let fresh = HotKeyRegistry(registrar: other)
    fresh.setLauncher(launcher)
    other.calls = []
    #expect(fresh.setLauncher(cmdShiftK))
    #expect(other.calls == ["+1 shift+cmd+k"])
    #expect(!fresh.launcherRefused)
}

@Test func recordingTheLauncherHotkeySuspendsEverythingAndResumesWithTheNewOne() {
    let fake = FakeRegistrar()
    let registry = HotKeyRegistry(registrar: fake)
    registry.setLauncher(launcher)
    registry.apply(["scratch/folders": optionS])
    registry.suspend()
    #expect(fake.registered.isEmpty, "⌥Space must reach the recorder, not show the panel")
    // The recorder resumes before it applies the new hotkey.
    registry.resume()
    #expect(registry.setLauncher(cmdShiftK))
    #expect(Set(fake.registered.values) == [cmdShiftK, optionS])
}

@Test func whatAKeyPressDoesWhileRecording() {
    let escape: UInt32 = 53
    let delete: UInt32 = 51
    let forwardDelete: UInt32 = 117
    #expect(HotKeyRecording(keyCode: escape, command: false, option: false, control: false, shift: false) == .cancel)
    #expect(HotKeyRecording(keyCode: delete, command: false, option: false, control: false, shift: false) == .clear)
    #expect(
        HotKeyRecording(keyCode: forwardDelete, command: false, option: false, control: false, shift: false) == .clear)
    #expect(
        HotKeyRecording(keyCode: delete, command: false, option: true, control: false, shift: false)
            == .record(HotKeySpec(keyCode: delete, option: true)), "⌥⌫ is a shortcut")
    #expect(
        HotKeyRecording(keyCode: 1, command: false, option: true, control: false, shift: false) == .record(optionS))
}

@Test func theLauncherHotkeyIsNeverEmptyAndYieldsToCommands() {
    let commands = ["scratch/folders": optionS, "vscode/search": optionV]
    #expect(HotKeyRecording.cancel.launcherEdit(commands: commands) == .keep)
    #expect(HotKeyRecording.clear.launcherEdit(commands: commands) == .set(.default), "⌫ resets it to ⌥Space")
    #expect(HotKeyRecording.record(cmdShiftK).launcherEdit(commands: commands) == .set(cmdShiftK))
    #expect(
        HotKeyRecording.record(optionS).launcherEdit(commands: commands) == .refused(.command("scratch/folders")),
        "a command has it")
    #expect(
        HotKeyRecording.record(HotKeySpec(keyCode: 1, shift: true)).launcherEdit(commands: commands)
            == .refused(.needsModifier))
    #expect(HotKeyRecording.record(HotKeySpec.parse("f5")!).launcherEdit(commands: commands) == .set(.parse("f5")!))
    // ⌫ can't take ⌥Space from a command that has it.
    #expect(
        HotKeyRecording.clear.launcherEdit(commands: ["a/b": launcher]) == .refused(.command("a/b")))
}

// MARK: - SPEC-047 (FUD-60)

@Test func aLauncherChangeThatCantBeSavedPutsBackWhatWasThere() {
    // Refused at launch: Raycast holds ⌥Space, so it's wanted but not registered.
    let fake = FakeRegistrar()
    fake.refuse = ["option+space"]
    let registry = HotKeyRegistry(registrar: fake)
    registry.setLauncher(launcher)
    #expect(registry.launcherRefused && fake.registered.isEmpty)

    #expect(registry.changeLauncher(to: cmdShiftK, save: { false }) == .notSaved)
    #expect(registry.launcher == launcher && registry.launcherRefused, "still wanted, still refused")
    #expect(fake.registered.isEmpty, "⌘⇧K isn't left registered behind a file that says ⌥Space")

    // Registered before: the old one is registered again.
    let other = FakeRegistrar()
    let working = HotKeyRegistry(registrar: other)
    working.setLauncher(launcher)
    #expect(working.changeLauncher(to: cmdShiftK, save: { false }) == .notSaved)
    #expect(working.launcher == launcher && !working.launcherRefused)
    #expect(other.registered == [HotKeyRegistry.launcherID: launcher])

    // Saved: the new one stays. Refused by the system: the old one stays and nothing is saved.
    var saves = 0
    #expect(
        working.changeLauncher(
            to: cmdShiftK,
            save: {
                saves += 1
                return true
            }) == .changed)
    #expect(working.launcher == cmdShiftK && saves == 1)
    other.refuse = ["option+s"]
    #expect(
        working.changeLauncher(
            to: optionS,
            save: {
                saves += 1
                return true
            }) == .inUse)
    #expect(working.launcher == cmdShiftK && saves == 1, "a refused hotkey is never saved")
    #expect(other.registered == [HotKeyRegistry.launcherID: cmdShiftK])
}

@Test func leavingThePageEndsARecordingAndResumesHotkeys() {
    var recorder = HotKeyRecorder()
    let first = recorder.start("vscode/search")
    #expect(first, "the first recording suspends hotkeys")
    let second = recorder.start(":launcher")
    #expect(!second && recorder.recording == ":launcher", "another hotkey on the page doesn't suspend twice")
    let samePage = recorder.pageChanged(from: ":general", to: ":general")
    #expect(!samePage && recorder.recording == ":launcher", "the same page keeps it")
    let otherPage = recorder.pageChanged(from: ":general", to: ":commands")
    #expect(otherPage && recorder.recording == nil, "another page ends it and resumes")
    let again = recorder.pageChanged(from: ":commands", to: ":general")
    let ended = recorder.end()
    #expect(!again && !ended, "nothing to resume")
    _ = recorder.start("vscode/search")
    let escape = recorder.end()
    #expect(escape && recorder.recording == nil)
}

@Test func anUninstalledCommandsHotkeyGivesWay() {
    let commands = ["gone/old": optionS, "vscode/search": optionV]
    let installed: Set<String> = ["vscode/search", "scratch/folders"]
    #expect(
        HotKeyConflict.check(
            optionS, for: "scratch/folders", launcher: launcher, commands: commands, installed: installed)
            == nil, "gone/old isn't installed")
    #expect(
        HotKeyConflict.displaced(by: optionS, except: "scratch/folders", commands: commands, installed: installed)
            == ["gone/old"])
    #expect(
        HotKeyConflict.check(
            optionV, for: "scratch/folders", launcher: launcher, commands: commands, installed: installed)
            == .command("vscode/search"), "an installed command still blocks")
    #expect(HotKeyConflict.displaced(by: optionV, commands: commands, installed: installed).isEmpty)
    // The launcher's hotkey too.
    #expect(HotKeyRecording.record(optionS).launcherEdit(commands: commands, installed: installed) == .set(optionS))
    #expect(
        HotKeyRecording.record(optionV).launcherEdit(commands: commands, installed: installed)
            == .refused(.command("vscode/search")))
    // Without `installed`, every saved hotkey counts, as before.
    #expect(
        HotKeyConflict.check(optionS, for: "scratch/folders", launcher: launcher, commands: commands)
            == .command("gone/old"))
}

private func installed(_ json: String) throws -> InstalledExtension {
    InstalledExtension(
        manifest: try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)),
        directory: URL(fileURLWithPath: "/nonexistent"))
}

@Test func conflictsNameTheCommandByTitle() throws {
    let vscode = try installed(
        #"{"name":"vscode","title":"VS Code Project Manager","commands":[{"name":"search","title":"Search Projects","mode":"view"}]}"#
    )
    let jetbrains = try installed(
        #"{"name":"jetbrains","title":"JetBrains Toolbox","commands":[{"name":"search","title":"Search Projects","mode":"view"},{"name":"open","title":"Open Recent","mode":"view"}]}"#
    )
    #expect(CommandNames.name(of: "jetbrains/open", in: [vscode, jetbrains]) == "Open Recent")
    #expect(
        CommandNames.name(of: "vscode/search", in: [vscode, jetbrains]) == "Search Projects (VS Code Project Manager)",
        "two installed commands share the title")
    #expect(CommandNames.name(of: "vscode/search", in: [vscode]) == "Search Projects")
    #expect(CommandNames.name(of: "gone/old", in: [vscode]) == nil)
}
