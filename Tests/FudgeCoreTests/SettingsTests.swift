import Foundation
import Testing

@testable import FudgeCore

@Test func parsesHotkeys() throws {
    let spec = try #require(HotKeySpec.parse("cmd + Shift+K"))
    #expect(spec.keyCode == 40)
    #expect(spec.command && spec.shift && !spec.option && !spec.control)
    #expect(spec.description == "⇧⌘K")
    #expect(HotKeySpec.default.keyCode == 49)
    #expect(HotKeySpec.default.description == "⌥Space")
}

@Test(arguments: ["space", "shift+space", "cmd+", "cmd+nope", "hyper+space", ""])
func rejectsHotkeysWithoutAModifierOrKey(text: String) {
    #expect(HotKeySpec.parse(text) == nil)
}

@Test func loadsSettingsAndToleratesMissingOrBrokenFiles() throws {
    let folder = try Fixtures.temporaryDirectory()
    let file = folder.appendingPathComponent("settings.json")
    #expect(FudgeSettings.load(from: file) == FudgeSettings())
    try Data(#"{ "hotkey": "ctrl+space" }"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file).hotkey == "ctrl+space")
    try Data("{ not json".utf8).write(to: file)
    #expect(FudgeSettings.load(from: file) == FudgeSettings())
}

@Test(arguments: [
    ("f1", 122), ("f13", 105), ("f20", 90), ("option+§", 10), ("cmd+left", 123), ("ctrl+up", 126),
    ("option+keypad5", 87), ("option+keypadplus", 69), ("option+forwarddelete", 117), ("cmd+shift+keycode:93", 93),
])
func everyRecordableKeyRoundTrips(text: String, keyCode: UInt32) throws {
    let spec = try #require(HotKeySpec.parse(text))
    #expect(spec.keyCode == keyCode)
    #expect(HotKeySpec.parse(spec.text) == spec, "\(spec.text) reads back the same")
    let rebuilt = HotKeySpec(
        keyCode: keyCode, command: spec.command, option: spec.option, control: spec.control, shift: spec.shift)
    #expect(rebuilt == spec, "a recorded key code gets the same name")
}

@Test func hotkeyTextAndLabels() throws {
    let spec = try #require(HotKeySpec.parse("shift+cmd+option+ctrl+k"))
    #expect(spec.text == "ctrl+option+shift+cmd+k", "macOS's modifier order")
    #expect(spec.modifierSymbols == ["⌃", "⌥", "⇧", "⌘"])
    #expect(try #require(HotKeySpec.parse("option+s")).description == "⌥S")
    #expect(try #require(HotKeySpec.parse("f5")).description == "F5")
    #expect(try #require(HotKeySpec.parse("cmd+left")).description == "⌘←")
    #expect(try #require(HotKeySpec.parse("option+keypad5")).keyLabel == "Keypad 5")
    #expect(try #require(HotKeySpec.parse("option+keycode:93")).keyLabel == "Key 93")
    #expect(HotKeySpec(keyCode: 93, option: true).text == "option+keycode:93")
}

@Test func anFKeyMayStandAloneButALetterMayNot() {
    #expect(HotKeySpec.parse("f13") != nil)
    #expect(HotKeySpec.parse("s") == nil)
    #expect(HotKeySpec.parse("shift+s") == nil, "⇧ alone isn't enough")
    #expect(HotKeySpec.parse("keycode:200") == nil, "key codes stop at 127")
}

@Test func commandSettingsRoundTrip() throws {
    let folder = try Fixtures.temporaryDirectory()
    let file = folder.appendingPathComponent("settings.json")
    var settings = FudgeSettings(hotkey: "ctrl+space")
    settings.commands["scratch/scratch-folders"] = .init(hotkey: "option+s", alias: "sf")
    settings.commands["scratch/create-scratch"] = .init(enabled: false)
    settings.extensions["next-task"] = .init(enabled: false)
    try settings.save(to: file)
    #expect(FudgeSettings.load(from: file) == settings)
    #expect(FudgeSettings.load(from: file).commandHotkeys == ["scratch/scratch-folders": HotKeySpec.parse("option+s")!])

    // Defaults aren't written, and an entry left empty goes away.
    settings.commands["scratch/scratch-folders"] = .init()
    settings.commands["scratch/create-scratch"] = .init(enabled: true)
    settings.extensions["next-task"] = .init()
    try settings.save(to: file)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object.keys.sorted() == ["hotkey"])
}

@Test func oldSettingsFilesStillReadAndUnknownKeysSurviveAWrite() throws {
    let folder = try Fixtures.temporaryDirectory()
    let file = folder.appendingPathComponent("settings.json")
    try Data(
        #"{ "hotkey": "option+space", "theme": "dark", "commands": { "a/b": { "alias": "ab", "note": "mine" } } }"#
            .utf8
    ).write(to: file)
    var settings = FudgeSettings.load(from: file)
    #expect(settings.hotkey == "option+space")
    #expect(settings.commands["a/b"] == .init(alias: "ab"))
    settings.commands["a/b"]?.hotkey = "f5"
    try settings.save(to: file)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["theme"] as? String == "dark", "a key fudge doesn't know is kept")
    let entry = try #require((object["commands"] as? [String: Any])?["a/b"] as? [String: Any])
    #expect(entry["note"] as? String == "mine", "so is one inside an entry")
    #expect(entry["hotkey"] as? String == "f5")

    // Values of the wrong type read as the default rather than failing the whole file.
    try Data(#"{ "hotkey": 5, "commands": { "a/b": { "alias": 7, "enabled": "no" } } }"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file) == FudgeSettings(commands: ["a/b": .init()]))
}
