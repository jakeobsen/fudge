import Foundation
import Testing

@testable import FudgeCore

// Pastes and getSelectedText()'s ⌘C fallback taking turns (FUD-61). Fakes only: these tests never touch the real
// pasteboard or post key events.

/// What happened to the pasteboard and the keys, in order.
@MainActor
private final class Log {
    var events: [String] = []
}

/// Trusted, and with no selected text to give, so every read takes the ⌘C fallback.
@MainActor
private final class FakeAccess: AccessibilityAccess {
    func isTrusted(prompt: Bool) -> Bool { true }
    func selectedText(pid: Int32) async -> String? { nil }
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
        log.events.append("snapshot \(text(current) ?? "-")")
        return current
    }

    func replace(with contents: PasteboardContents) {
        log.events.append("write \(text(contents) ?? "-")")
        current = contents
        changeCount += 1
    }

    func plainText() -> String? { text(current) }

    /// What the user or an app does: a new copy.
    func copied(_ text: String) {
        log.events.append("copied \(text)")
        changeCount += 1
        current = clip(text)
    }

    private func text(_ contents: PasteboardContents) -> String? {
        contents.items.first?.first { $0.type == "public.utf8-plain-text" }.map {
            String(decoding: $0.data, as: UTF8.self)
        }
    }
}

/// Both shortcuts. The app the user is in copies its selection a moment after ⌘C.
@MainActor
private final class FakeKeys: CopyKeyPoster, PasteKeyPoster {
    let log: Log
    let pasteboard: FakePasteboard
    /// Runs as ⌘C is posted, while the fallback has its turn.
    var onCopy: () -> Void = {}

    init(log: Log, pasteboard: FakePasteboard) {
        self.log = log
        self.pasteboard = pasteboard
    }

    func postPaste(to pid: Int32) {
        log.events.append("⌘V")
    }

    func postDelete(_ count: Int, to pid: Int32) {}

    func postCopy(to pid: Int32) {
        log.events.append("⌘C")
        onCopy()
        Task { @MainActor [pasteboard] in
            try? await Task.sleep(for: .milliseconds(5))
            pasteboard.copied("selected")
        }
    }
}

private func clip(_ text: String) -> PasteboardContents {
    PasteboardContents(items: [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]])
}

private let me: Int32 = 100
private let textEdit = FrontmostApplication(pid: 200, bundleIdentifier: "com.apple.TextEdit")
private let restoreDelay: Duration = .milliseconds(50)
/// Generous bounds for "it doesn't wait for anything else": a busy CI runner can stall the main actor for seconds.
private let noHang: Duration = .seconds(30)

/// A `Paste` and a `SelectedText` sharing one `PasteboardTurns`, as the app's are.
@MainActor
private struct Rig {
    let log = Log()
    let pasteboard: FakePasteboard
    let keys: FakeKeys
    let paster: Paste
    let selection: SelectedText
    let turns = PasteboardTurns()

    init() {
        pasteboard = FakePasteboard(clip("user's clipboard"), log: log)
        keys = FakeKeys(log: log, pasteboard: pasteboard)
        let access = FakeAccess()
        let gate = AccessibilityGate(access: access)
        paster = Paste(
            gate: gate, keys: keys, pasteboard: pasteboard, ownPid: me, turns: turns, restoreDelay: restoreDelay)
        selection = SelectedText(
            accessibility: access, keys: keys, pasteboard: pasteboard, ownPid: me, turns: turns, gate: gate,
            // A copy that lands ends the wait at once; the long timeout only keeps a stalled runner from failing.
            copyTimeout: .seconds(60), pollInterval: .milliseconds(1))
    }

    /// Returns once the pending restore, if any, has run or been dropped.
    func afterRestore() async {
        await turns.restoreSettled()
    }

    /// A paste that hides the panel, which takes a moment, so other calls can arrive meanwhile.
    func paste(_ text: String) async throws {
        try await paster.paste(
            PasteboardContents.forPaste(text: text, html: nil, file: nil), closeMainWindow: true,
            origin: .userInitiated, hideWindow: { try? await Task.sleep(for: .milliseconds(10)) },
            frontmost: { textEdit })
    }

    func read() async throws -> String {
        try await selection.read(from: textEdit, origin: .userInitiated)
    }
}

@Test @MainActor func aFallbackRightAfterAPasteStartsOnlyAfterTheRestore() async throws {
    let rig = Rig()
    try await rig.paste("pasted")
    #expect(try await rig.read() == "selected")
    #expect(
        rig.log.events == [
            "snapshot user's clipboard", "write pasted", "⌘V",
            "write user's clipboard",
            "snapshot user's clipboard", "⌘C", "copied selected", "write user's clipboard",
        ], "the paste's restore runs first, so the fallback's snapshot is the user's clipboard")
    await rig.afterRestore()
    #expect(rig.pasteboard.plainText() == "user's clipboard")
}

@Test @MainActor func aRestoreDroppedBecauseOfANewCopyStillEndsTheFallbacksWait() async throws {
    let rig = Rig()
    let started = ContinuousClock.now
    try await rig.paste("pasted")
    rig.pasteboard.copied("copied meanwhile")
    #expect(try await rig.read() == "selected")
    let waited = ContinuousClock.now - started
    #expect(
        rig.log.events == [
            "snapshot user's clipboard", "write pasted", "⌘V",
            "copied copied meanwhile",
            "snapshot copied meanwhile", "⌘C", "copied selected", "write copied meanwhile",
        ], "the restore leaves the newer copy, and the fallback keeps it")
    #expect(waited >= restoreDelay, "the restore isn't hurried")
    #expect(waited < restoreDelay + noHang, "and the fallback waits for nothing after it")
    #expect(rig.pasteboard.plainText() == "copied meanwhile")
}

@Test @MainActor func aPasteDuringAFallbackWaitsForItsTurn() async throws {
    let rig = Rig()
    var pasting: Task<Void, any Error>?
    // The paste arrives while the fallback is waiting for the app to copy.
    rig.keys.onCopy = { pasting = Task { try await rig.paste("pasted") } }
    #expect(try await rig.read() == "selected")
    try await #require(pasting).value
    #expect(
        rig.log.events == [
            "snapshot user's clipboard", "⌘C", "copied selected", "write user's clipboard",
            "snapshot user's clipboard", "write pasted", "⌘V",
        ], "the paste's snapshot is the user's clipboard, which the fallback put back")
    await rig.afterRestore()
    #expect(rig.log.events.last == "write user's clipboard")
    #expect(rig.pasteboard.plainText() == "user's clipboard")
}

@Test @MainActor func twoPastesAndAFallbackRunInOrderOneAtATime() async throws {
    let rig = Rig()
    let first = Task { try await rig.paste("A") }
    let second = Task { try await rig.paste("B") }
    let reading = Task { try await rig.read() }
    try await first.value
    try await second.value
    #expect(try await reading.value == "selected")
    #expect(
        rig.log.events == [
            "snapshot user's clipboard", "write A", "⌘V",
            "write B", "⌘V",
            "write user's clipboard",
            "snapshot user's clipboard", "⌘C", "copied selected", "write user's clipboard",
        ], "B keeps A's snapshot, and the fallback waits for B's restore")
    await rig.afterRestore()
    #expect(rig.pasteboard.plainText() == "user's clipboard")
}

@Test @MainActor func restoreSettledReturnsAtOnceWithNothingPendingAndWhenTheRestoreIsCancelled() async {
    let turns = PasteboardTurns()
    let started = ContinuousClock.now
    await turns.restoreSettled()
    #expect(ContinuousClock.now - started < noHang, "nothing pending")

    // A restore that would wait a long time: a new paste cancels it and keeps its snapshot.
    let restore = Task<Void, Never> { try? await Task.sleep(for: .seconds(600)) }
    turns.restore = restore
    let waiting = Task { await turns.restoreSettled() }
    restore.cancel()
    let cancelled = ContinuousClock.now
    await waiting.value
    #expect(ContinuousClock.now - cancelled < noHang, "the waiter resumes with the cancelled restore")
}
