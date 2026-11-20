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
