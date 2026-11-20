import Testing

@testable import FudgeCore

@Test func commandQAndWCloseFudgesWindowsUnlessAHotkeyIsBeingRecorded() {
    let q = KeyShortcut(key: "q", modifiers: ["cmd"])
    let w = KeyShortcut(key: "w", modifiers: ["cmd"])
    #expect(WindowShortcut.closesWindow(q, recording: false))
    #expect(WindowShortcut.closesWindow(w, recording: false))
    #expect(WindowShortcut.closesWindow(KeyShortcut(key: "Q", modifiers: ["cmd"]), recording: false), "either case")
    #expect(!WindowShortcut.closesWindow(q, recording: true), "the recorder takes ⌘Q like any other shortcut")
    #expect(!WindowShortcut.closesWindow(KeyShortcut(key: "q", modifiers: ["cmd", "shift"]), recording: false))
    #expect(!WindowShortcut.closesWindow(KeyShortcut(key: "q", modifiers: ["cmd", "opt"]), recording: false))
    #expect(!WindowShortcut.closesWindow(KeyShortcut(key: "q", modifiers: []), recording: false), "typing q")
    #expect(!WindowShortcut.closesWindow(KeyShortcut(key: "a", modifiers: ["cmd"]), recording: false))
}
