import Testing

@testable import FudgeCore

private func argument(
    _ name: String, type: String = "text", required: Bool? = nil, options: [String] = []
) -> ExtensionManifest.Argument {
    ExtensionManifest.Argument(
        name: name, type: type, placeholder: name, required: required,
        data: options.isEmpty ? nil : options.map { ExtensionManifest.Option(title: $0.uppercased(), value: $0) })
}

private let tab = KeyShortcut(key: "tab", modifiers: [])
private let shiftTab = KeyShortcut(key: "tab", modifiers: ["shift"])
private let up = KeyShortcut(key: "arrowUp", modifiers: [])
private let down = KeyShortcut(key: "arrowDown", modifiers: [])
private let delete = KeyShortcut(key: "delete", modifiers: [])
private let enter = KeyShortcut(key: "return", modifiers: [])
private let escape = KeyShortcut(key: "escape", modifiers: [])

/// Presses `key` and returns what the input made of it.
private func press(_ key: KeyShortcut, in input: inout ArgumentInput) -> ArgumentInput.KeyResult {
    input.handle(key)
}

@Test func tabMovesThroughTheArgumentsAndBackToTheSearchField() {
    var input = ArgumentInput(arguments: [argument("a"), argument("b")])
    #expect(input.focus == nil)
    #expect(press(tab, in: &input) == .handled)
    #expect(input.focus == 0)
    _ = press(tab, in: &input)
    #expect(input.focus == 1)
    _ = press(tab, in: &input)
    #expect(input.focus == nil, "past the last argument, back to the search field")
    _ = press(shiftTab, in: &input)
    #expect(input.focus == 1, "⇧Tab from the search field goes to the last argument")
    _ = press(shiftTab, in: &input)
    _ = press(shiftTab, in: &input)
    #expect(input.focus == nil)
}

@Test func tabStaysInTheSearchFieldWithoutArguments() {
    var input = ArgumentInput()
    #expect(press(tab, in: &input) == .handled)
    #expect(input.focus == nil)
    #expect(press(down, in: &input) == .ignored, "↓ moves the selection")
}

@Test func launchArgumentsNameEveryArgumentWithEmptyStringsForTheUnfilled() {
    var input = ArgumentInput(arguments: [argument("label"), argument("kind", type: "dropdown", options: ["a"])])
    #expect(input.launchArguments == ["label": "", "kind": ""])
    input.set("notes", at: 0)
    #expect(input.value(at: 0) == "notes")
    #expect(input.launchArguments == ["label": "notes", "kind": ""])
}

@Test func anEmptyRequiredArgumentStopsTheLaunchAndTakesTheKeyboard() {
    var input = ArgumentInput(arguments: [argument("label"), argument("token", required: true)])
    var complete = input.checkRequired()
    #expect(!complete)
    #expect(input.focus == 1)
    #expect(input.missing == 1)
    input.set("", at: 1)
    #expect(input.missing == 1, "still empty")
    input.set("x", at: 1)
    #expect(input.missing == nil)
    complete = input.checkRequired()
    #expect(complete)

    var optional = ArgumentInput(arguments: [argument("label", required: false)])
    complete = optional.checkRequired()
    #expect(complete)
    #expect(optional.focus == nil)
}

@Test func keysInsideATextArgument() {
    var input = ArgumentInput(arguments: [argument("a"), argument("b")])
    input.focus = 1
    input.set("x", at: 1)
    #expect(press(delete, in: &input) == .ignored, "⌫ deletes text in the field")
    input.set("", at: 1)
    #expect(press(delete, in: &input) == .handled)
    #expect(input.focus == 0, "⌫ in an empty field goes back one")
    #expect(press(down, in: &input) == .handled, "↓ doesn't leave the field")
    #expect(input.focus == 0)
    #expect(press(enter, in: &input) == .ignored, "a text field submits itself")
    #expect(press(KeyShortcut(key: "x", modifiers: []), in: &input) == .ignored)
    #expect(press(escape, in: &input) == .handled)
    #expect(input.focus == nil)
}

@Test func arrowsChangeADropdownArgument() {
    var input = ArgumentInput(arguments: [argument("kind", type: "dropdown", options: ["a", "b", "c"])])
    input.focus = 0
    _ = press(down, in: &input)
    #expect(input.value(at: 0) == "a", "↓ with no value picks the first")
    for _ in 0..<3 { _ = press(down, in: &input) }
    #expect(input.value(at: 0) == "c", "stops at the last")
    _ = press(up, in: &input)
    #expect(input.value(at: 0) == "b")
    #expect(press(enter, in: &input) == .submit)
    #expect(press(KeyShortcut(key: "enter", modifiers: []), in: &input) == .submit, "keypad Enter too")
    #expect(press(delete, in: &input) == .handled)
    #expect(input.value(at: 0) == "", "⌫ clears a dropdown's value")

    var fresh = ArgumentInput(arguments: [argument("kind", type: "dropdown", options: ["a", "b", "c"])])
    fresh.focus = 0
    _ = press(up, in: &fresh)
    #expect(fresh.value(at: 0) == "c", "↑ with no value picks the last")
}
