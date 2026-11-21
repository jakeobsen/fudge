import Foundation
import Testing

@testable import FudgeCore

// Hyperkey (SPEC-093). Nothing here runs hidutil or creates an event tap: the mapping goes through a fake
// `KeyMappingSystem`, and the tap's decisions are `HyperTap`'s.

private let escape: UInt64 = 0x7_0000_0029
private let rightOption: UInt64 = 0x7_0000_00E6
private let leftControl: UInt64 = 0x7_0000_00E0

/// `hidutil property --get UserKeyMapping` as macOS prints a list: CoreFoundation's description of it.
private let printedList = """
    (
            {
            HIDKeyboardModifierMappingDst = 30064771113;
            HIDKeyboardModifierMappingSrc = 30064771302;
        },
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    """

private final class FakeKeyMapping: KeyMappingSystem, @unchecked Sendable {
    var mapping: String
    var keyboards: String
    var readFails = false
    var keyboardsFail = false
    var writeFails = false
    private(set) var writes: [String] = []

    init(mapping: String = "(null)\n", keyboards: String = "RegistryID  Key                   Value\n") {
        self.mapping = mapping
        self.keyboards = keyboards
    }

    struct Failed: Error {}

    func readMapping() throws -> String {
        if readFails { throw Failed() }
        return mapping
    }

    func readKeyboardMappings() throws -> String {
        if keyboardsFail { throw Failed() }
        return keyboards
    }

    func writeMapping(_ argument: String) throws {
        if writeFails { throw Failed() }
        writes.append(argument)
    }

    /// The list a write set, read back from its JSON.
    func written(_ index: Int) throws -> [KeyRemap] {
        let object = try JSONSerialization.jsonObject(with: Data(writes[index].utf8)) as? [String: [[String: UInt64]]]
        return try #require(object?["UserKeyMapping"]).map {
            KeyRemap(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
        }
    }
}

// MARK: - The key mapping

@Test func hidutilsOutputIsRead() throws {
    #expect(try HyperkeyMapping.parse("(null)\n") == [])
    #expect(try HyperkeyMapping.parse("") == [])
    #expect(
        try HyperkeyMapping.parse(printedList) == [
            KeyRemap(source: rightOption, destination: escape), HyperkeyMapping.entry,
        ])
    #expect(HyperkeyMapping.entry == KeyRemap(source: 0x7_0000_0039, destination: 0x7_0000_006D), "Caps Lock → F18")
    for junk in ["not a list", "( { HIDKeyboardModifierMappingSrc = 1; } )", "{ a = b; }", "( x"] {
        #expect(throws: HyperkeyMapping.Problem.unreadable, "\(junk)") { try HyperkeyMapping.parse(junk) }
    }
}

@Test func eachKeyboardsOwnMappingIsRead() throws {
    let output = """
        RegistryID  Key                   Value
        100000b43   UserKeyMapping   (null)
        100000c12   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771296;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        """
    #expect(
        try HyperkeyMapping.keyboardMappings(output) == [
            [], [KeyRemap(source: Hyperkey.capsLockUsage, destination: leftControl)],
        ])
    #expect(try HyperkeyMapping.keyboardMappings("RegistryID  Key                   Value\n") == [])
    #expect(throws: HyperkeyMapping.Problem.unreadable) { try HyperkeyMapping.keyboardMappings("something else") }
}

@Test func fudgesEntryIsAddedAndRemovedKeepingTheOthers() throws {
    let others = [KeyRemap(source: rightOption, destination: escape)]
    #expect(try HyperkeyMapping.adding(to: []) == [HyperkeyMapping.entry])
    #expect(try HyperkeyMapping.adding(to: others) == others + [HyperkeyMapping.entry])
    #expect(try HyperkeyMapping.adding(to: others + [HyperkeyMapping.entry]) == others + [HyperkeyMapping.entry])
    #expect(HyperkeyMapping.removing(from: others + [HyperkeyMapping.entry]) == others)
    #expect(HyperkeyMapping.removing(from: [HyperkeyMapping.entry] + others) == others)
    #expect(HyperkeyMapping.removing(from: others) == others)
}

@Test func capsLockMappedElsewhereIsRefusedNamingIt() {
    let taken = [KeyRemap(source: Hyperkey.capsLockUsage, destination: escape)]
    #expect(throws: HyperkeyMapping.Problem.capsLockTaken(destination: escape)) {
        try HyperkeyMapping.adding(to: taken)
    }
    // A keyboard's own mapping, as System Settings → Keyboard → Modifier Keys sets it.
    #expect(throws: HyperkeyMapping.Problem.capsLockTaken(destination: leftControl)) {
        try HyperkeyMapping.adding(
            to: [], keyboards: [[], [KeyRemap(source: Hyperkey.capsLockUsage, destination: leftControl)]])
    }
    // Fudge's own entry on a keyboard isn't a conflict.
    #expect((try? HyperkeyMapping.adding(to: [], keyboards: [[HyperkeyMapping.entry]])) == [HyperkeyMapping.entry])
    #expect(HyperkeyMapping.Problem.capsLockTaken(destination: escape).message.contains("mapped to Escape"))
    #expect(HyperkeyMapping.keyName(leftControl) == "Control")
    #expect(HyperkeyMapping.keyName(0x7_0000_0068) == "F13")
    #expect(HyperkeyMapping.keyName(0x7_0000_0004) == "another key")
    #expect(HyperkeyMapping.keyName(0xFF_0000_0003) == "another key")
}

@Test func applyingWritesTheWholeListOnceAndOnlyWhenItChanges() throws {
    let system = FakeKeyMapping(
        mapping: """
            (
                    {
                    HIDKeyboardModifierMappingDst = 30064771113;
                    HIDKeyboardModifierMappingSrc = 30064771302;
                }
            )
            """)
    try HyperkeyMapping.apply(system)
    #expect(system.writes.count == 1)
    #expect(try system.written(0) == [KeyRemap(source: rightOption, destination: escape), HyperkeyMapping.entry])

    // Already there (a launch after a crash): nothing is written.
    system.mapping = printedList
    try HyperkeyMapping.apply(system)
    #expect(system.writes.count == 1)

    try HyperkeyMapping.remove(system)
    #expect(system.writes.count == 2)
    #expect(try system.written(1) == [KeyRemap(source: rightOption, destination: escape)])

    // Removing when Fudge's entry isn't there writes nothing.
    system.mapping = "(null)"
    try HyperkeyMapping.remove(system)
    #expect(system.writes.count == 2)
}

@Test func nothingIsWrittenOverAMappingThatCantBeRead() {
    let unreadable = FakeKeyMapping(mapping: "garbled")
    #expect(throws: HyperkeyMapping.Problem.unreadable) { try HyperkeyMapping.apply(unreadable) }
    #expect(throws: HyperkeyMapping.Problem.unreadable) { try HyperkeyMapping.remove(unreadable) }
    let failing = FakeKeyMapping()
    failing.readFails = true
    #expect(throws: HyperkeyMapping.Problem.unreadable) { try HyperkeyMapping.apply(failing) }
    let keyboards = FakeKeyMapping()
    keyboards.keyboardsFail = true
    #expect(throws: HyperkeyMapping.Problem.unreadable) { try HyperkeyMapping.apply(keyboards) }
    let taken = FakeKeyMapping(
        keyboards: """
            RegistryID  Key                   Value
            100000c12   UserKeyMapping   (
                    {
                    HIDKeyboardModifierMappingDst = 30064771113;
                    HIDKeyboardModifierMappingSrc = 30064771129;
                }
            )
            """)
    #expect(throws: HyperkeyMapping.Problem.capsLockTaken(destination: escape)) { try HyperkeyMapping.apply(taken) }
    for system in [unreadable, failing, keyboards, taken] { #expect(system.writes.isEmpty) }

    let refused = FakeKeyMapping()
    refused.writeFails = true
    #expect(throws: HyperkeyMapping.Problem.self) { try HyperkeyMapping.apply(refused) }
}

@Test func theSetArgumentIsJSONHidutilReads() throws {
    #expect(HyperkeyMapping.setArgument([]) == #"{"UserKeyMapping":[]}"#)
    #expect(
        HyperkeyMapping.setArgument([HyperkeyMapping.entry])
            == #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771181}]}"#
    )
}

// MARK: - The tap

private func down(_ key: UInt16, at ms: UInt64, repeat: Bool = false) -> HyperTapEvent {
    HyperTapEvent(kind: .keyDown, keyCode: key, isRepeat: `repeat`, time: ms * 1_000_000)
}

private func up(_ key: UInt16, at ms: UInt64) -> HyperTapEvent {
    HyperTapEvent(kind: .keyUp, keyCode: key, time: ms * 1_000_000)
}

private let f18 = Hyperkey.f18KeyCode
private let t: UInt16 = 17

@Test func f18IsSwallowedAndKeysWhileItsDownGetHyper() {
    var tap = HyperTap()
    #expect(tap.handle(down(f18, at: 0), f18Down: true, secureInput: false) == .swallow)
    #expect(tap.handle(down(f18, at: 30, repeat: true), f18Down: true, secureInput: false) == .swallow)
    #expect(tap.handle(down(t, at: 50), f18Down: true, secureInput: false) == .addHyper)
    #expect(tap.handle(up(t, at: 80), f18Down: true, secureInput: false) == .addHyper)
    #expect(tap.handle(up(f18, at: 100), f18Down: false, secureInput: false) == .swallow)
    #expect(tap.handle(down(t, at: 120), f18Down: false, secureInput: false) == .pass)
    // A modifier pressed with it is left alone.
    let shift = HyperTapEvent(kind: .flagsChanged, keyCode: 56, time: 0)
    #expect(tap.handle(down(f18, at: 200), f18Down: true, secureInput: false) == .swallow)
    #expect(tap.handle(shift, f18Down: true, secureInput: false) == .pass)
}

@Test func hyperFollowsTheHardwareSoALostKeyUpCantLeaveItStuck() {
    var tap = HyperTap(quickPressTogglesCapsLock: true)
    #expect(tap.handle(down(f18, at: 0), f18Down: true, secureInput: false) == .swallow)
    #expect(tap.isTrackingPress)
    // F18's key-up never reached the tap (it was off for a moment); the hardware says it's up.
    #expect(tap.handle(down(t, at: 500), f18Down: false, secureInput: false) == .pass)
    #expect(!tap.isTrackingPress, "the press is over")
    // And one the tap never saw go down, held when it started, is Hyper all the same.
    var started = HyperTap()
    #expect(started.handle(down(t, at: 0), f18Down: true, secureInput: false) == .addHyper)
}

@Test func aQuickPressTogglesCapsLockOnlyWithTheOption() {
    var off = HyperTap()
    #expect(off.handle(down(f18, at: 0), f18Down: true, secureInput: false) == .swallow)
    #expect(off.handle(up(f18, at: 50), f18Down: false, secureInput: false) == .swallow, "never toggles caps")

    var on = HyperTap(quickPressTogglesCapsLock: true)
    #expect(on.handle(down(f18, at: 0), f18Down: true, secureInput: false) == .swallow)
    #expect(on.handle(down(f18, at: 100, repeat: true), f18Down: true, secureInput: false) == .swallow)
    #expect(on.handle(up(f18, at: 199), f18Down: false, secureInput: false) == .swallowAndToggleCapsLock)

    // 200 ms or longer is a hold.
    #expect(on.handle(down(f18, at: 1000), f18Down: true, secureInput: false) == .swallow)
    #expect(on.handle(up(f18, at: 1200), f18Down: false, secureInput: false) == .swallow)

    // Another key in between makes it a chord, however quick.
    #expect(on.handle(down(f18, at: 2000), f18Down: true, secureInput: false) == .swallow)
    #expect(on.handle(down(t, at: 2020), f18Down: true, secureInput: false) == .addHyper)
    #expect(on.handle(up(f18, at: 2050), f18Down: false, secureInput: false) == .swallow)

    // So does a modifier.
    #expect(on.handle(down(f18, at: 3000), f18Down: true, secureInput: false) == .swallow)
    _ = on.handle(
        HyperTapEvent(kind: .flagsChanged, keyCode: 56, time: 3_010_000_000), f18Down: true, secureInput: false)
    #expect(on.handle(up(f18, at: 3050), f18Down: false, secureInput: false) == .swallow)

    // A key-up with no press seen doesn't toggle.
    var fresh = HyperTap(quickPressTogglesCapsLock: true)
    #expect(fresh.handle(up(f18, at: 10), f18Down: false, secureInput: false) == .swallow)
}

@Test func theTapDoesNothingUnderSecureInputAndStartsOver() {
    var tap = HyperTap(quickPressTogglesCapsLock: true)
    #expect(tap.handle(down(f18, at: 0), f18Down: true, secureInput: false) == .swallow)
    #expect(tap.handle(down(t, at: 20), f18Down: true, secureInput: true) == .pass, "no Hyper in a password field")
    #expect(!tap.isTrackingPress)
    #expect(tap.handle(up(f18, at: 50), f18Down: false, secureInput: false) == .swallow, "no toggle after it")
    #expect(tap.handle(down(f18, at: 100), f18Down: true, secureInput: true) == .pass)
}

@Test func everyResetForgetsThePress() {
    for reason in [HyperTap.Reset.tapDisabled, .tapEnabled, .secureInput, .switchedOff] {
        var tap = HyperTap(quickPressTogglesCapsLock: true)
        _ = tap.handle(down(f18, at: 0), f18Down: true, secureInput: false)
        tap.reset(reason)
        #expect(!tap.isTrackingPress, "\(reason)")
        #expect(tap.handle(up(f18, at: 50), f18Down: false, secureInput: false) == .swallow, "\(reason): no toggle")
    }
}

@Test func theTapKeepsNothingAboutWhatsTyped() {
    // Two different runs of typing under Hyper leave the same state: no key, character or count is kept.
    var one = HyperTap(quickPressTogglesCapsLock: true)
    var two = HyperTap(quickPressTogglesCapsLock: true)
    _ = one.handle(down(f18, at: 0), f18Down: true, secureInput: false)
    _ = two.handle(down(f18, at: 0), f18Down: true, secureInput: false)
    for (index, key) in [UInt16(0), 1, 2, 3].enumerated() {
        _ = one.handle(down(key, at: UInt64(10 + index)), f18Down: true, secureInput: false)
    }
    _ = two.handle(down(t, at: 10), f18Down: true, secureInput: false)
    #expect(one == two)
    #expect(
        Set(Mirror(reflecting: one).children.compactMap(\.label))
            == ["quickPressTogglesCapsLock", "pressedAt", "otherKeySincePress"])
}

// MARK: - Hotkeys and settings

@Test func allFourModifiersShowAsHyper() throws {
    let spec = try #require(HotKeySpec.parse("ctrl+option+shift+cmd+t"))
    #expect(spec.isHyper)
    #expect(spec.modifierSymbols == ["Hyper"])
    #expect(spec.description == "Hyper+T")
    #expect(spec.text == "ctrl+option+shift+cmd+t", "saved as its four modifiers")
    let three = try #require(HotKeySpec.parse("ctrl+option+cmd+t"))
    #expect(!three.isHyper)
    #expect(three.description == "⌃⌥⌘T")
}

@Test func hyperkeysSettingsAreOffUntilSavedOn() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    #expect(!FudgeSettings().hyperkey && !FudgeSettings().hyperkeyQuickPress)
    var settings = FudgeSettings()
    try settings.save(to: file)
    let empty = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(empty?["hyperkey"] == nil && empty?["hyperkeyQuickPress"] == nil, "off isn't written")
    settings.hyperkey = true
    settings.hyperkeyQuickPress = true
    try settings.save(to: file)
    let loaded = FudgeSettings.load(from: file)
    #expect(loaded.hyperkey && loaded.hyperkeyQuickPress)
    try Data(#"{"hyperkey": "yes", "hyperkeyQuickPress": 1}"#.utf8).write(to: file)
    #expect(!FudgeSettings.load(from: file).hyperkey, "only a JSON true turns it on")
}
