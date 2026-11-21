import Foundation
import Testing

@testable import FudgeCore

// A snippet expansion through `Paste.expand` with #128's caret placement (#114's review, from the reviewer's probe): a
// keyword with `{cursor}` typed in Spotlight's field while TextEdit is the frontmost app. The field is read before any
// key, the ⌫s' UTF-16 length counts towards the landing, everything goes to Spotlight, and secure input stops it
// before the first key.

/// Spotlight's field: knows what the keys do to it, records every call with its pid, in one order.
private final class ExpansionField: CaretSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var count: Int
    private var caret: Int
    private var pendingPaste: Int?
    private var readsSincePaste = 0
    private let keywordClusters: [Int]
    let settable: Bool

    init(count: Int, caret: Int, keyword: String, settable: Bool) {
        self.count = count
        self.caret = caret
        keywordClusters = keyword.map { $0.utf16.count }
        self.settable = settable
    }

    var events: [String] { lock.withLock { recorded } }

    func deleted(_ n: Int, pid: Int32) {
        lock.withLock {
            recorded.append("⌫×\(n) \(pid)")
            let units = keywordClusters.suffix(n).reduce(0, +)
            count -= units
            caret -= units
        }
    }

    func pasted(_ length: Int, pid: Int32) {
        lock.withLock {
            recorded.append("⌘V \(pid)")
            pendingPaste = length
            readsSincePaste = 0
        }
    }

    func state(of pid: Int32) -> TextFieldState? {
        lock.withLock {
            if let length = pendingPaste {
                readsSincePaste += 1
                // The app takes the paste late: on the second read after ⌘V.
                if readsSincePaste >= 2 {
                    count += length
                    caret += length
                    pendingPaste = nil
                }
            }
            recorded.append("read \(pid) c=\(count) @\(caret)")
            return TextFieldState(count: count, selection: .caret(caret))
        }
    }

    func setCaret(_ location: Int, of pid: Int32) -> Bool {
        lock.withLock {
            recorded.append("set \(location) \(pid)")
            guard settable else { return false }
            caret = location
            return true
        }
    }

    func postLeftArrows(_ n: Int, to pid: Int32) {
        lock.withLock {
            recorded.append("←×\(n) \(pid)")
        }
    }
}

@MainActor
private final class ExpansionAccess: AccessibilityAccess {
    func isTrusted(prompt: Bool) -> Bool { true }
    func selectedText(pid: Int32) async -> String? { nil }
}

@MainActor
private final class ExpansionKeys: PasteKeyPoster {
    let field: ExpansionField
    let length: Int
    init(_ field: ExpansionField, length: Int) {
        self.field = field
        self.length = length
    }
    func postPaste(to pid: Int32) { field.pasted(length, pid: pid) }
    func postDelete(_ count: Int, to pid: Int32) { field.deleted(count, pid: pid) }
}

@MainActor
private final class ExpansionPasteboard: PasteboardAccess {
    var changeCount = 1
    var current = PasteboardContents(items: [])
    func contents() -> PasteboardContents { current }
    func replace(with contents: PasteboardContents) {
        current = contents
        changeCount += 1
    }
    func plainText() -> String? { nil }
}

private let expansionTextEdit: Int32 = 200
private let expansionSpotlight: Int32 = 300
private let expansionMe: Int32 = 100

@MainActor
private func expandInSpotlight(
    settable: Bool, secureInput: Bool = false, seen: (ExpansionField) -> Void = { _ in }
) async throws -> (ExpansionField, [CaretReport]) {
    // Snippet "Hi {cursor}there 👋🏽", keyword ";a😀" (3 characters, 4 UTF-16 units), typed at the end of Spotlight's
    // 20-unit field.
    let keyword = ";a😀"
    let template = SnippetTemplate("Hi {cursor}there 👋🏽")
    let filled = template.fill(context: .init(clipboard: nil))
    let leftArrows = SnippetTemplate.leftArrows(afterCursor: filled.afterCursor)
    #expect(filled.text == "Hi there 👋🏽" && leftArrows == 7)
    let field = ExpansionField(count: 20, caret: 20, keyword: keyword, settable: settable)
    seen(field)
    let keys = ExpansionKeys(field, length: filled.text.utf16.count)
    let clock = CaretClock()
    let placer = CaretPlacer(system: field, sleep: { clock.advance($0) }, now: clock.now)
    var reports: [CaretReport] = []
    let paste = Paste(
        gate: AccessibilityGate(access: ExpansionAccess()), keys: keys, pasteboard: ExpansionPasteboard(),
        ownPid: expansionMe,
        turns: PasteboardTurns(), restoreDelay: .milliseconds(1), caret: placer, caretPlaced: { reports.append($0) })
    // As SystemCalls.expandSnippet passes them.
    try await paste.expand(
        PasteboardContents.forPaste(text: filled.text, html: nil, file: nil), target: expansionSpotlight,
        backspaces: keyword.count, deletedUTF16: keyword.utf16.count, leftArrows: leftArrows,
        secureInput: { secureInput })
    return (field, reports)
}

@Test @MainActor func anExpansionReadsFirstThenDeletesPastesAndPlacesTheCaretInSpotlight() async throws {
    let (field, reports) = try await expandInSpotlight(settable: false)
    let events = field.events
    // Read before any key, then ⌫s, then ⌘V, then the landing reads, then the caret.
    #expect(events.first == "read 300 c=20 @20", "\(events)")
    #expect(events[1] == "⌫×3 300" && events[2] == "⌘V 300", "\(events)")
    #expect(events.last == "←×7 300", "\(events)")
    #expect(!events.contains { $0.hasSuffix(" \(expansionTextEdit)") || $0.contains(" 200 ") }, "nothing to TextEdit")
    #expect(events.allSatisfy { $0.contains("300") }, "\(events)")
    #expect(reports.count == 1)
    #expect(reports.first?.path == .arrows, "landing seen via deletedBefore, not a timeout: \(reports)")
    #expect((reports.first?.polls ?? 99) <= 3, "\(reports)")
    #expect(reports.first?.arrows == 7)
}

@Test @MainActor func anExpansionsCaretIsSetThroughAccessibilityCountingTheDeletedKeyword() async throws {
    let (field, reports) = try await expandInSpotlight(settable: true)
    let events = field.events
    #expect(events.first == "read 300 c=20 @20", "\(events)")
    // 20 - 4 + 13 = 29 after the paste; the tail "there 👋🏽" is 10 UTF-16 units back.
    #expect(events.contains("set 19 300"), "\(events)")
    #expect(reports.first?.path == .accessibility, "\(reports)")
    #expect(!events.contains { $0.hasPrefix("←") })
}

@Test @MainActor func anExpansionUnderSecureInputReadsAndPostsNothing() async throws {
    var field: ExpansionField?
    await #expect(throws: PasteError.secureInput) {
        _ = try await expandInSpotlight(settable: true, secureInput: true, seen: { field = $0 })
    }
    #expect(field?.events == [], "no read, no key: \(String(describing: field?.events))")
}

/// Secure input comes on while the pre-⌫ field read is in flight (focus moves to a password field in the same app).
@Test @MainActor func secureInputComingOnDuringTheReadStopsTheExpansionBeforeAnyKey() async throws {
    let keyword = ";a😀"
    let field = ExpansionField(count: 20, caret: 20, keyword: keyword, settable: true)
    let keys = ExpansionKeys(field, length: 8)
    let pasteboard = ExpansionPasteboard()
    let clock = CaretClock()
    let placer = CaretPlacer(system: field, sleep: { clock.advance($0) }, now: clock.now)
    let paste = Paste(
        gate: AccessibilityGate(access: ExpansionAccess()), keys: keys, pasteboard: pasteboard, ownPid: expansionMe,
        turns: PasteboardTurns(), restoreDelay: .milliseconds(1), caret: placer)
    await #expect(throws: PasteError.secureInput) {
        try await paste.expand(
            PasteboardContents.forPaste(text: "Best, me", html: nil, file: nil), target: expansionSpotlight,
            backspaces: keyword.count, deletedUTF16: keyword.utf16.count, leftArrows: 0,
            secureInput: { !field.events.isEmpty })  // on once the field has been read
    }
    #expect(!field.events.contains { $0.hasPrefix("⌫") || $0.hasPrefix("⌘V") }, "\(field.events)")
    #expect(pasteboard.current.items.isEmpty, "the clipboard is put back")
}
