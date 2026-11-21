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
    var modifierKeys = "RegistryID  Key                   Value\n"
    var modifierKeysFail = false
    var writeFails = false
    private(set) var writes: [String] = []
    /// What `replacedCapsLock` keeps across launches, as the bytes of the app's `hyperkey.json`, read and written
    /// through the same functions.
    var state: Data?
    var rememberFails = false
    /// How many replaced entries the state says.
    var replaced: Int {
        get { HyperkeyMapping.replacedCount(inState: state) }
        set { state = newValue > 0 ? HyperkeyMapping.state(replaced: newValue) : nil }
    }

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

    func readModifierKeys() throws -> String {
        if modifierKeysFail { throw Failed() }
        return modifierKeys
    }

    func writeMapping(_ argument: String) throws {
        if writeFails { throw Failed() }
        writes.append(argument)
        mapping = Self.printed(try written(writes.count - 1))
    }

    func replacedCapsLock() -> Int { replaced }

    func setReplacedCapsLock(_ count: Int) throws {
        if rememberFails { throw Failed() }
        replaced = count
    }

    /// A list as `hidutil property --get UserKeyMapping` prints it, so a write is what the next read sees.
    static func printed(_ remaps: [KeyRemap]) -> String {
        guard !remaps.isEmpty else { return "(null)\n" }
        let entries = remaps.map {
            "    {\n        HIDKeyboardModifierMappingDst = \($0.destination);\n        HIDKeyboardModifierMappingSrc = \($0.source);\n    }"
        }
        return "(\n" + entries.joined(separator: ",\n") + "\n)\n"
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

    // A press whose key-up never came (secure input hid it) doesn't spoil the next quick press.
    #expect(on.handle(down(f18, at: 4000), f18Down: true, secureInput: false) == .swallow)
    #expect(on.handle(down(f18, at: 9000), f18Down: true, secureInput: false) == .swallow)
    #expect(on.handle(up(f18, at: 9050), f18Down: false, secureInput: false) == .swallowAndToggleCapsLock)

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

// MARK: - #125's review

@Test func capsLockMappedInModifierKeysIsRefused() {
    // System Settings → Keyboard → Modifier Keys writes `HIDKeyboardModifierMappingPairs`, not `UserKeyMapping`.
    let system = FakeKeyMapping()
    system.modifierKeys = """
        RegistryID  Key                   Value
        100000b43   HIDKeyboardModifierMappingPairs   (null)
        100009295   HIDKeyboardModifierMappingPairs   (
                {
                HIDKeyboardModifierMappingDst = 30064771296;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        """
    #expect(throws: HyperkeyMapping.Problem.capsLockTaken(destination: leftControl)) {
        try HyperkeyMapping.apply(system)
    }
    #expect(system.writes.isEmpty)
    #expect(HyperkeyMapping.Problem.capsLockTaken(destination: leftControl).message.contains("Modifier Keys"))
    // Caps Lock left as Caps Lock there isn't a mapping.
    system.modifierKeys = """
        RegistryID  Key                   Value
        100009295   HIDKeyboardModifierMappingPairs   (
                {
                HIDKeyboardModifierMappingDst = 30064771129;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        """
    #expect(throws: Never.self) { try HyperkeyMapping.apply(system) }
    let unreadable = FakeKeyMapping()
    unreadable.modifierKeysFail = true
    #expect(throws: HyperkeyMapping.Problem.unreadable) { try HyperkeyMapping.apply(unreadable) }
    #expect(HyperkeyMapping.keyName(0) == "No Action")
}

/// Runs the lifecycle's steps against the fake mapping as the app does: a start adds the entry unless the tap is
/// refused, which `startFailed` turns into a stop.
private func run(
    _ lifecycle: inout HyperkeyLifecycle, settingOn: Bool, trusted: Bool, tapStarts: Bool = true,
    on system: FakeKeyMapping
) throws {
    var step = lifecycle.next(settingOn: settingOn, trusted: trusted)
    if step == .start {
        if tapStarts { try HyperkeyMapping.apply(system) } else { step = lifecycle.startFailed() }
    }
    if step == .stop { try HyperkeyMapping.remove(system) }
}

@Test func aLeftoverEntryIsRemovedAtLaunchWheneverHyperkeyWontRun() throws {
    // Fudge was killed with Hyperkey on: Caps Lock → F18 is still there, and nothing handles F18.
    for (settingOn, trusted, tapStarts) in [(false, true, true), (true, false, true), (true, true, false)] {
        let system = FakeKeyMapping(mapping: printedList)
        var lifecycle = HyperkeyLifecycle()
        try run(&lifecycle, settingOn: settingOn, trusted: trusted, tapStarts: tapStarts, on: system)
        try #require(system.writes.count == 1, "setting \(settingOn), Accessibility \(trusted), tap \(tapStarts)")
        #expect(
            try system.written(0) == [KeyRemap(source: rightOption, destination: escape)],
            "setting \(settingOn), Accessibility \(trusted), tap \(tapStarts): Fudge's entry goes, the other stays")
        // The 2 s check doesn't do it again, nor start a tap again and again.
        system.mapping = "(null)"
        for _ in 0..<3 {
            #expect(lifecycle.next(settingOn: settingOn, trusted: trusted) == .nothing)
        }
        #expect(system.writes.count == 1)
    }
}

@Test func hyperkeyFollowsTheSettingAndAccessibility() {
    var lifecycle = HyperkeyLifecycle()
    #expect(lifecycle.next(settingOn: true, trusted: true) == .start)
    #expect(lifecycle.next(settingOn: true, trusted: true) == .nothing)
    #expect(lifecycle.next(settingOn: true, trusted: false) == .stop, "Accessibility revoked")
    #expect(lifecycle.next(settingOn: true, trusted: false) == .nothing)
    #expect(lifecycle.next(settingOn: true, trusted: true) == .start, "and back")
    #expect(lifecycle.next(settingOn: false, trusted: true) == .stop, "switched off")
    // A refused start waits for a change before it's tried again.
    #expect(lifecycle.next(settingOn: true, trusted: true) == .start)
    #expect(lifecycle.startFailed() == .stop)
    #expect(lifecycle.next(settingOn: true, trusted: true) == .nothing)
    #expect(lifecycle.next(settingOn: false, trusted: true) == .nothing, "already removed")
    #expect(lifecycle.next(settingOn: true, trusted: true) == .start, "the switch again")
}

// MARK: - SPEC-118 §1: a Caps Lock → Caps Lock entry already there

private let escapeToRightOption = KeyRemap(source: escape, destination: rightOption)
private let rightOptionToControl = KeyRemap(source: rightOption, destination: leftControl)

@Test func fudgesEntryTakesTheCapsLockToItselfEntrysPlaceAndPutsItBack() throws {
    let before = [escapeToRightOption, HyperkeyMapping.capsLockItself, rightOptionToControl]
    let fake = FakeKeyMapping(mapping: FakeKeyMapping.printed(before))
    try HyperkeyMapping.apply(fake)
    #expect(try fake.written(0) == [escapeToRightOption, HyperkeyMapping.entry, rightOptionToControl], "in its place")
    #expect(fake.replaced == 1, "remembered, before the write")

    try HyperkeyMapping.remove(fake)
    #expect(try fake.written(1) == before, "exactly as it was, in the same place")
    #expect(fake.replaced == 0 && fake.state == nil)
}

@Test func everyCapsLockToItselfEntryIsReplacedAndAsManyGoBack() throws {
    // Three of them: Fudge's entry takes the first one's place, and no Caps Lock → Caps Lock stays beside F18.
    let before = [
        HyperkeyMapping.capsLockItself, escapeToRightOption, HyperkeyMapping.capsLockItself, rightOptionToControl,
        HyperkeyMapping.capsLockItself,
    ]
    let fake = FakeKeyMapping(mapping: FakeKeyMapping.printed(before))
    try HyperkeyMapping.apply(fake)
    #expect(try fake.written(0) == [HyperkeyMapping.entry, escapeToRightOption, rightOptionToControl])
    #expect(fake.replaced == 3, "how many, remembered before the write")

    // Turned off: as many go back, all where Fudge's was, since they're alike.
    try HyperkeyMapping.remove(fake)
    #expect(
        try fake.written(1) == [
            HyperkeyMapping.capsLockItself, HyperkeyMapping.capsLockItself, HyperkeyMapping.capsLockItself,
            escapeToRightOption, rightOptionToControl,
        ])
    #expect(fake.replaced == 0)

    // On again from there: the same three are replaced, and nothing else moves.
    try HyperkeyMapping.apply(fake)
    #expect(try fake.written(2) == [HyperkeyMapping.entry, escapeToRightOption, rightOptionToControl])
    #expect(fake.replaced == 3)
}

@Test func hyperkeyJSONFromBeforeCountsAsOneEntry() throws {
    // A Mac that updates with Hyperkey on has SPEC-118's file: turning it off still puts the user's entry back.
    let fake = FakeKeyMapping(mapping: FakeKeyMapping.printed([HyperkeyMapping.entry, escapeToRightOption]))
    fake.state = Data(#"{"replacedCapsLock":true}"#.utf8)
    #expect(fake.replaced == 1)
    try HyperkeyMapping.remove(fake)
    #expect(try fake.written(0) == [HyperkeyMapping.capsLockItself, escapeToRightOption])
    #expect(fake.state == nil, "forgotten once it's back")
}

@Test func hyperkeyJSONIsReadAsACountOrNone() {
    let read = { (text: String?) in HyperkeyMapping.replacedCount(inState: text.map { Data($0.utf8) }) }
    #expect(read(#"{"replacedCapsLock":2}"#) == 2)
    #expect(read(#"{"replacedCapsLock":true}"#) == 1, "SPEC-118's flag")
    #expect(HyperkeyMapping.replacedCount(inState: HyperkeyMapping.state(replaced: 7)) == 7, "what Fudge writes")
    for text in [
        nil, "", "not json", "[]", "{}", #"{"replacedCapsLock":false}"#, #"{"replacedCapsLock":0}"#,
        #"{"replacedCapsLock":-1}"#, #"{"replacedCapsLock":1.5}"#, #"{"replacedCapsLock":"2"}"#,
        #"{"replacedCapsLock":101}"#, #"{"replacedCapsLock":null}"#,
    ] {
        #expect(read(text) == 0, "\(text ?? "no file")")
    }
}

@Test func theLaunchCleanupAfterACrashPutsTheEntryBackToo() throws {
    // A crash left Fudge's entry where Caps Lock → Caps Lock was: a new launch only has what was remembered.
    let fake = FakeKeyMapping(mapping: FakeKeyMapping.printed([HyperkeyMapping.entry, escapeToRightOption]))
    fake.replaced = 1
    try HyperkeyMapping.remove(fake)
    #expect(try fake.written(0) == [HyperkeyMapping.capsLockItself, escapeToRightOption])
    #expect(fake.replaced == 0)
}

@Test func withoutAReplacedEntryRemovalAddsNothing() throws {
    let fake = FakeKeyMapping(mapping: FakeKeyMapping.printed([escapeToRightOption, HyperkeyMapping.entry]))
    try HyperkeyMapping.remove(fake)
    #expect(try fake.written(0) == [escapeToRightOption])

    // The user wrote Caps Lock → Caps Lock again meanwhile: it isn't doubled.
    let rewritten = FakeKeyMapping(
        mapping: FakeKeyMapping.printed([HyperkeyMapping.capsLockItself, HyperkeyMapping.entry]))
    rewritten.replaced = 1
    try HyperkeyMapping.remove(rewritten)
    #expect(try rewritten.written(0) == [HyperkeyMapping.capsLockItself])

    // Fudge's entry is gone already (the user removed it): nothing is written, and what was remembered goes.
    let gone = FakeKeyMapping(mapping: FakeKeyMapping.printed([escapeToRightOption]))
    gone.replaced = 1
    try HyperkeyMapping.remove(gone)
    #expect(gone.writes.isEmpty && gone.replaced == 0)
}

@Test func whatCantBeRememberedIsntReplacedAndAFailedRemovalKeepsIt() throws {
    let fake = FakeKeyMapping(mapping: FakeKeyMapping.printed([HyperkeyMapping.capsLockItself]))
    fake.rememberFails = true
    #expect(throws: HyperkeyMapping.Problem.self) { try HyperkeyMapping.apply(fake) }
    #expect(fake.writes.isEmpty, "the user's entry is never replaced without a way back")

    let failing = FakeKeyMapping(mapping: FakeKeyMapping.printed([HyperkeyMapping.entry]))
    failing.replaced = 2
    failing.writeFails = true
    #expect(throws: HyperkeyMapping.Problem.self) { try HyperkeyMapping.remove(failing) }
    #expect(failing.replaced == 2, "still remembered, for the next try")
}
