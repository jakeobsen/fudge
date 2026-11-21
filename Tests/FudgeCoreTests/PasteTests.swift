import Foundation
import Testing

@testable import FudgeCore

/// What happened, in order, across the fakes.
@MainActor
private final class Log {
    var events: [String] = []
}

@MainActor
private final class FakeAccess: AccessibilityAccess {
    var trusted = true
    var prompts: [Bool] = []
    let log: Log

    init(_ log: Log) { self.log = log }

    func isTrusted(prompt: Bool) -> Bool {
        prompts.append(prompt)
        log.events.append("trust")
        return trusted
    }

    func selectedText(pid: Int32) async -> String? { nil }
}

@MainActor
private final class FakePasteKeys: PasteKeyPoster {
    var posted: [Int32] = []
    let log: Log

    init(_ log: Log) { self.log = log }

    func postPaste(to pid: Int32) {
        posted.append(pid)
        log.events.append("post")
    }
}

@MainActor
private final class FakePasteboard: PasteboardAccess {
    var changeCount = 7
    var current: PasteboardContents
    let log: Log

    init(_ contents: PasteboardContents, log: Log) {
        current = contents
        self.log = log
    }

    func contents() -> PasteboardContents {
        log.events.append("snapshot")
        return current
    }

    func replace(with contents: PasteboardContents) {
        log.events.append(contents.items.isEmpty ? "clear" : "write \(text(contents) ?? "?")")
        current = contents
        changeCount += 1
    }

    func plainText() -> String? { text(current) }

    /// What the user or another app does: a new copy.
    func copied(_ text: String) {
        changeCount += 1
        current = clip(text)
    }

    private func text(_ contents: PasteboardContents) -> String? {
        contents.items.first?.first { $0.type == "public.utf8-plain-text" }.map {
            String(decoding: $0.data, as: UTF8.self)
        }
    }
}

private func clip(_ text: String, concealed: Bool = false) -> PasteboardContents {
    var item = [PasteboardContents.Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]
    if concealed { item.append(.init(type: PasteboardContents.concealedType, data: Data())) }
    return PasteboardContents(items: [item])
}

private let me: Int32 = 100
private let textEdit = FrontmostApplication(pid: 200, bundleIdentifier: "com.apple.TextEdit")
private let restoreDelay: Duration = .milliseconds(30)
/// Comfortably past the restore.
private func afterRestore() async { try? await Task.sleep(for: .milliseconds(150)) }

@MainActor
private struct Rig {
    let log = Log()
    let access: FakeAccess
    let keys: FakePasteKeys
    let pasteboard: FakePasteboard
    let paste: Paste

    init(clipboard: PasteboardContents = clip("user's clipboard")) {
        access = FakeAccess(log)
        keys = FakePasteKeys(log)
        pasteboard = FakePasteboard(clipboard, log: log)
        paste = Paste(
            gate: AccessibilityGate(access: access), keys: keys, pasteboard: pasteboard, ownPid: me,
            turns: PasteboardTurns(), restoreDelay: restoreDelay)
    }

    func run(
        _ text: String, closeMainWindow: Bool = true, frontmost: FrontmostApplication? = textEdit
    ) async throws {
        try await paste.paste(
            PasteboardContents.forPaste(text: text, html: nil, file: nil), closeMainWindow: closeMainWindow,
            origin: .userInitiated,
            hideWindow: {
                log.events.append("hide")
                // The panel is really gone a moment later; ⌘V must wait for that.
                try? await Task.sleep(for: .milliseconds(10))
                log.events.append("hidden")
            },
            frontmost: { frontmost })
    }
}

@Test @MainActor func pastesInOrderThenPutsTheClipboardBack() async throws {
    let rig = Rig()
    try await rig.run("pasted")
    #expect(rig.log.events == ["snapshot", "write pasted", "trust", "hide", "hidden", "post"])
    #expect(rig.keys.posted == [textEdit.pid], "into the app the user is in")
    #expect(rig.pasteboard.plainText() == "pasted", "resolved before the restore")
    await afterRestore()
    #expect(rig.log.events.last == "write user's clipboard")
    #expect(rig.pasteboard.plainText() == "user's clipboard")
}

@Test @MainActor func keepsThePanelWhenAskedTo() async throws {
    let rig = Rig()
    try await rig.run("pasted", closeMainWindow: false)
    #expect(rig.log.events == ["snapshot", "write pasted", "trust", "post"])
}

@Test @MainActor func leavesAClipboardSomeoneElseChanged() async throws {
    let rig = Rig()
    try await rig.run("pasted")
    rig.pasteboard.copied("copied meanwhile")
    await afterRestore()
    #expect(rig.pasteboard.plainText() == "copied meanwhile")
    #expect(!rig.log.events.contains("write user's clipboard"))
}

@Test @MainActor func clearsAPasswordInsteadOfWritingItBack() async throws {
    let rig = Rig(clipboard: clip("hunter2", concealed: true))
    try await rig.run("pasted")
    await afterRestore()
    #expect(rig.log.events.last == "clear")
    #expect(rig.pasteboard.current.items.isEmpty)
}

@Test @MainActor func pastesInQuickSuccessionRestoreTheOriginalClipboard() async throws {
    let rig = Rig()
    try await rig.run("first")
    try await rig.run("second")
    #expect(rig.keys.posted.count == 2)
    await afterRestore()
    #expect(rig.pasteboard.plainText() == "user's clipboard", "not the first paste's content")
    #expect(rig.log.events.filter { $0 == "write user's clipboard" }.count == 1, "one restore")
}

@Test @MainActor func overlappingPastesRunOneAtATime() async throws {
    let rig = Rig()
    // Two `clipboard.paste` calls arrive together: the second starts while the first waits for the panel to hide.
    let first = Task { try await rig.run("A") }
    let second = Task { try await rig.run("B") }
    try await first.value
    try await second.value
    #expect(
        rig.log.events == [
            "snapshot", "write A", "trust", "hide", "hidden", "post",
            "write B", "trust", "hide", "hidden", "post",
        ], "each ⌘V pastes its own content, and the second paste keeps the first one's snapshot")
    await afterRestore()
    #expect(rig.pasteboard.plainText() == "user's clipboard", "not fudge's first write")
    #expect(rig.log.events.filter { $0 == "write user's clipboard" }.count == 1, "one restore")
}

@Test @MainActor func aCopyBetweenPastesIsTheClipboardPutBack() async throws {
    let rig = Rig()
    try await rig.run("first")
    rig.pasteboard.copied("copied meanwhile")
    try await rig.run("second")
    await afterRestore()
    #expect(rig.pasteboard.plainText() == "copied meanwhile", "the user's newer copy, not the older snapshot")
}

@Test @MainActor func refusesToPasteIntoFudgeAndPutsTheClipboardBackFirst() async throws {
    let rig = Rig()
    await #expect(throws: PasteError.noTarget) {
        try await rig.run("pasted", frontmost: FrontmostApplication(pid: me, bundleIdentifier: "io.github.fudge"))
    }
    #expect(rig.log.events.suffix(2) == ["hidden", "write user's clipboard"])
    #expect(rig.keys.posted.isEmpty)
    await #expect(throws: PasteError.noTarget) { try await rig.run("pasted", frontmost: nil) }
    #expect(PasteError.noTarget.description == "There is no app to paste into")
}

@Test @MainActor func withoutPermissionTheContentStaysCopied() async throws {
    let rig = Rig()
    rig.access.trusted = false
    await #expect(throws: PasteError.accessibilityNeeded) { try await rig.run("pasted") }
    await #expect(throws: PasteError.accessibilityNeeded) { try await rig.run("again") }
    #expect(rig.access.prompts == [true, false], "macOS asks once per run")
    #expect(!rig.log.events.contains("hide") && rig.keys.posted.isEmpty)
    await afterRestore()
    #expect(rig.pasteboard.plainText() == "again", "left for the user to paste")
    #expect(
        PasteError.accessibilityNeeded.description
            == "Fudge needs Accessibility permission to paste. The content was copied instead; allow Fudge in "
            + "System Settings → Privacy & Security → Accessibility.")
}

@Test @MainActor func theAccessibilityPromptIsSharedWithReadingTheSelection() {
    let access = FakeAccess(Log())
    access.trusted = false
    let gate = AccessibilityGate(access: access)
    #expect(!gate.isTrusted(origin: .userInitiated))
    #expect(!gate.isTrusted(origin: .userInitiated))
    #expect(access.prompts == [true, false])
}

@Test func writesTheContentAsCopyDoesMarkedTransient() {
    func types(_ contents: PasteboardContents) -> [String] { contents.items.flatMap { $0.map(\.type) } }
    let text = PasteboardContents.forPaste(text: "hi", html: nil, file: nil)
    #expect(text.items.count == 1)
    #expect(
        types(text) == [
            "public.utf8-plain-text", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        ])
    #expect(text.items[0][0].data == Data("hi".utf8))
    let html = PasteboardContents.forPaste(text: "hi", html: "<b>hi</b>", file: nil)
    #expect(types(html).prefix(2) == ["public.html", "public.utf8-plain-text"])
    let file = PasteboardContents.forPaste(text: nil, html: nil, file: "/tmp/a b.txt")
    #expect(types(file).prefix(2) == ["public.file-url", "public.utf8-plain-text"])
    #expect(file.items[0][0].data == Data("file:///tmp/a%20b.txt".utf8))
    #expect(!text.isConcealed)
}

@Test func findsTheKeyThatTypesV() {
    #expect(PasteKey.keyCode { $0 == 9 ? "v" : "x" } == 9, "ANSI V")
    // Dvorak: the ANSI "." key (47) types "v".
    #expect(PasteKey.keyCode { $0 == 47 ? "v" : ($0 == 9 ? "k" : nil) } == 47)
    #expect(PasteKey.keyCode { _ in nil } == 9, "the ANSI key when nothing types v")
    #expect(CopyKey.keyCode { $0 == 8 ? "c" : nil } == 8)
}
