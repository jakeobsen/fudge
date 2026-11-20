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
