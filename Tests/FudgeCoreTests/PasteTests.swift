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
        field?.note("⌘V")
    }

    func postDelete(_ count: Int, to pid: Int32) {
        log.events.append("⌫ ×\(count) to \(pid)")
    }

    /// The field the caret goes into, told when ⌘V goes out.
    var field: FakeField?
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

@MainActor
private struct Rig {
    let log = Log()
    let access: FakeAccess
    let keys: FakePasteKeys
    let pasteboard: FakePasteboard
    let turns = PasteboardTurns()
    let paste: Paste
    let field: FakeField
    let reports = Reports()

    /// `field` is the text field the paste goes into; by default one that reports nothing.
    init(clipboard: PasteboardContents = clip("user's clipboard"), field: FakeField = FakeField()) {
        access = FakeAccess(log)
        keys = FakePasteKeys(log)
        pasteboard = FakePasteboard(clipboard, log: log)
        self.field = field
        keys.field = field
        let reports = reports
        paste = Paste(
            gate: AccessibilityGate(access: access), keys: keys, pasteboard: pasteboard, ownPid: me,
            turns: turns, restoreDelay: restoreDelay,
            caret: placer(field),
            caretPlaced: { reports.all.append($0) })
    }

    /// Once the pending restore has run, or been dropped: waits on the restore itself, never a fixed time, which a
    /// stalled CI runner can outlast.
    func afterRestore() async {
        await turns.restoreSettled()
    }

    func run(
        _ text: String, closeMainWindow: Bool = true, backspaces: Int = 0, leftArrows: Int = 0,
        frontmost: FrontmostApplication? = textEdit
    ) async throws {
        try await paste.paste(
            PasteboardContents.forPaste(text: text, html: nil, file: nil), closeMainWindow: closeMainWindow,
            origin: .userInitiated, backspaces: backspaces, leftArrows: leftArrows,
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
    await rig.afterRestore()
    #expect(rig.log.events.last == "write user's clipboard")
    #expect(rig.pasteboard.plainText() == "user's clipboard")
}

@Test @MainActor func aSnippetsCursorIsPlacedWithLeftArrowsAfterThePaste() async throws {
    // A field that reports nothing: after ⌘V, the settle time, then the ← presses.
    let rig = Rig()
    try await rig.run("Dear , thanks", leftArrows: 8)
    #expect(rig.log.events == ["snapshot", "write Dear , thanks", "trust", "hide", "hidden", "post"])
    #expect(rig.field.events == ["read 1", "⌘V", "sleep 150 ms", "← ×8 to 200"])
    #expect(rig.reports.all.map(\.path) == [.arrowsUnreported])
    #expect(rig.turns.isOwn(rig.pasteboard.changeCount), "Fudge's own write, which clipboard history skips")
    await rig.afterRestore()
    #expect(rig.turns.isOwn(rig.pasteboard.changeCount), "and so is the restore")
    let none = Rig()
    await #expect(throws: PasteError.noTarget) { try await none.run("x", leftArrows: 3, frontmost: nil) }
    #expect(!none.field.events.contains { $0.hasPrefix("←") }, "with no app to paste into, no ← either")
}

@Test @MainActor func aPasteAndItsRestoreAreMarkedAsFudgesOwnForClipboardHistory() async throws {
    let rig = Rig()
    let before = rig.pasteboard.changeCount
    #expect(!rig.turns.isOwn(before), "the user's copy")
    try await rig.run("pasted")
    #expect(rig.turns.isOwn(rig.pasteboard.changeCount), "the paste's write")
    #expect(rig.turns.isBusy, "its restore is still to come")
    await rig.afterRestore()
    #expect(rig.pasteboard.plainText() == "user's clipboard")
    #expect(rig.turns.isOwn(rig.pasteboard.changeCount), "the restore's write")
    #expect(!rig.turns.isBusy)
}

@Test @MainActor func anExpansionDeletesItsKeywordJustBeforeThePaste() async throws {
    let rig = Rig()
    try await rig.run("Best, me", closeMainWindow: false, backspaces: 4, leftArrows: 2)
    #expect(rig.log.events == ["snapshot", "write Best, me", "trust", "⌫ ×4 to 200", "post"])
    // The ← presses for `{cursor}` go through the caret's placement (#128), to the same app.
    #expect(rig.field.events.filter { $0.hasPrefix("←") } == ["← ×2 to 200"])
    let none = Rig()
    await #expect(throws: PasteError.noTarget) { try await none.run("x", backspaces: 3, frontmost: nil) }
    #expect(!none.log.events.contains { $0.hasPrefix("⌫") }, "with no app to paste into, nothing is deleted")
}

// MARK: - Expanding a snippet's keyword: only into the app it was typed in (#114's review)

private let spotlight: Int32 = 300

@MainActor
private func expand(_ rig: Rig, target: Int32?, secureInput: Bool = false) async throws {
    try await rig.paste.expand(
        PasteboardContents.forPaste(text: "Best, me", html: nil, file: nil), target: target, backspaces: 5,
        deletedUTF16: 5, leftArrows: 2, secureInput: { secureInput })
}

@Test @MainActor func anExpansionPostsOnlyToTheAppTheKeywordWasTypedIn() async throws {
    // ";addr" typed in Spotlight's field while a TextEdit document is the frontmost app: every key goes to
    // Spotlight, and TextEdit loses nothing at its caret.
    let rig = Rig()
    try await expand(rig, target: spotlight)
    #expect(rig.log.events == ["snapshot", "write Best, me", "trust", "⌫ ×5 to 300", "post"])
    #expect(rig.field.events.filter { $0.hasPrefix("←") } == ["← ×2 to 300"])
    #expect(rig.keys.posted == [spotlight])
    #expect(!rig.log.events.contains { $0.contains("to \(textEdit.pid)") }, "nothing to the frontmost app")
    await rig.afterRestore()
    #expect(rig.pasteboard.plainText() == "user's clipboard")
}

@Test @MainActor func anExpansionWithNoKnownTargetOrIntoFudgePostsNothing() async throws {
    for target in [nil, me] as [Int32?] {
        let rig = Rig()
        await #expect(throws: PasteError.noTarget) { try await expand(rig, target: target) }
        #expect(rig.keys.posted.isEmpty, "\(String(describing: target))")
        #expect(!rig.log.events.contains { $0.hasPrefix("⌫") || $0.hasPrefix("←") })
        #expect(rig.pasteboard.plainText() == "user's clipboard", "the clipboard is put back")
    }
}

@Test @MainActor func anExpansionStopsWhenAPasswordFieldHasTheKeyboardByItsTurn() async throws {
    let rig = Rig()
    await #expect(throws: PasteError.secureInput) { try await expand(rig, target: spotlight, secureInput: true) }
    #expect(rig.keys.posted.isEmpty)
    #expect(!rig.log.events.contains { $0.hasPrefix("⌫") || $0.hasPrefix("←") })
    #expect(rig.pasteboard.plainText() == "user's clipboard", "the clipboard is put back")
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
    await rig.afterRestore()
    #expect(rig.pasteboard.plainText() == "copied meanwhile")
    #expect(!rig.log.events.contains("write user's clipboard"))
}

@Test @MainActor func clearsAPasswordInsteadOfWritingItBack() async throws {
    let rig = Rig(clipboard: clip("hunter2", concealed: true))
    try await rig.run("pasted")
    await rig.afterRestore()
    #expect(rig.log.events.last == "clear")
    #expect(rig.pasteboard.current.items.isEmpty)
}

@Test @MainActor func pastesInQuickSuccessionRestoreTheOriginalClipboard() async throws {
    let rig = Rig()
    try await rig.run("first")
    try await rig.run("second")
    #expect(rig.keys.posted.count == 2)
    await rig.afterRestore()
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
    await rig.afterRestore()
    #expect(rig.pasteboard.plainText() == "user's clipboard", "not fudge's first write")
    #expect(rig.log.events.filter { $0 == "write user's clipboard" }.count == 1, "one restore")
}

@Test @MainActor func aCopyBetweenPastesIsTheClipboardPutBack() async throws {
    let rig = Rig()
    try await rig.run("first")
    rig.pasteboard.copied("copied meanwhile")
    try await rig.run("second")
    await rig.afterRestore()
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
    await rig.afterRestore()
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

@Test @MainActor func aSnippetsCaretWaitsUntilTheAppHasThePasteThenIsReported() async throws {
    // "Dear , thanks", 13 long, with the caret 8 back: the field shows the paste on its third read.
    let field = FakeField(
        before: TextFieldState(count: 0, selection: .caret(0)),
        after: TextFieldState(count: 13, selection: .caret(13)), landsOnRead: 3)
    let rig = Rig(field: field)
    try await rig.run("Dear , thanks", leftArrows: 8)
    #expect(field.events == ["read 1", "⌘V", "read 2", "sleep 15 ms", "read 3 landed", "set 5", "read 4 landed"])
    #expect(rig.reports.all.map(\.path) == [.accessibility] && rig.reports.all.first?.polls == 2)
    await rig.afterRestore()
    #expect(rig.pasteboard.plainText() == "user's clipboard")
}

@Test @MainActor func aPasteWithoutACursorPlacesNothing() async throws {
    let field = FakeField(
        before: TextFieldState(count: 0, selection: .caret(0)),
        after: TextFieldState(count: 6, selection: .caret(6)), landsOnRead: 2)
    let rig = Rig(field: field)
    try await rig.run("pasted")
    await rig.afterRestore()
    #expect(!field.events.contains { $0.hasPrefix("set") || $0.hasPrefix("←") })
    #expect(rig.reports.all.isEmpty)
    #expect(rig.pasteboard.plainText() == "user's clipboard")
}
