import Foundation
import Testing

@testable import FudgeCore

// SPEC-101 (FUD-133): a snippet's `{cursor}` lands where it was. A fake text field; no test posts a real key event or
// reads a real field.

/// A text field that shows `before` until its `landsOnRead`th read, and `after` from then on: an app that takes the
/// paste late. Setting the caret puts it where `setLands` says. Everything it's asked is recorded, in order. Its calls
/// come from dispatch queues, so it locks.
final class FakeField: CaretSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var reads = 0
    private var caret: Int?

    var before: TextFieldState?
    var after: TextFieldState?
    /// The read that first sees the paste, counting the read before ⌘V as 1.
    var landsOnRead = Int.max
    var settable = true
    /// Where a set caret ends up; the place asked for by default.
    var setLands: (Int) -> Int = { $0 }
    /// How long each read takes, as a slow app's would.
    var readDelay: Duration = .zero
    /// The first read that fails, as one that times out does; none by default.
    var failsFromRead = Int.max

    init(before: TextFieldState? = nil, after: TextFieldState? = nil, landsOnRead: Int = .max) {
        self.before = before
        self.after = after
        self.landsOnRead = landsOnRead
    }

    var events: [String] { lock.withLock { recorded } }

    func note(_ event: String) { lock.withLock { recorded.append(event) } }

    func state(of pid: Int32) -> TextFieldState? {
        if readDelay > .zero { usleep(useconds_t(readDelay / .microseconds(1))) }
        return lock.withLock {
            reads += 1
            if reads >= failsFromRead {
                recorded.append("read \(reads) failed")
                return nil
            }
            let landed = reads >= landsOnRead
            recorded.append("read \(reads)" + (landed ? " landed" : ""))
            var state = landed ? after : before
            if let caret, state != nil { state?.selection = .caret(caret) }
            return state
        }
    }

    func setCaret(_ location: Int, of pid: Int32) -> Bool {
        lock.withLock {
            recorded.append("set \(location)")
            guard settable else { return false }
            caret = setLands(location)
            return true
        }
    }

    func postLeftArrows(_ count: Int, to pid: Int32) {
        lock.withLock { recorded.append("← ×\(count) to \(pid)") }
    }
}

/// A clock that only the fake sleep moves on, so a wait "of a second" takes none.
final class CaretClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var passed: Duration = .zero

    func now() -> ContinuousClock.Instant { lock.withLock { start + passed } }
    func advance(_ duration: Duration) { lock.withLock { passed += duration } }
}

/// The reports `Paste` hands the log.
@MainActor
final class Reports {
    var all: [CaretReport] = []
}

private let pid: Int32 = 200

/// A placer whose sleeps take no time, are noted in the field's events, and move a fake clock on.
func placer(_ field: FakeField) -> CaretPlacer {
    let clock = CaretClock()
    return CaretPlacer(
        system: field,
        sleep: {
            field.note("sleep \($0.components.attoseconds / 1_000_000_000_000_000) ms")
            clock.advance($0)
        }, now: clock.now)
}

/// What `Paste` does around ⌘V: read the field, post ⌘V, wait for the landing, place the caret.
private func paste(_ pasted: PastedText, into field: FakeField) async -> CaretReport {
    let placer = placer(field)
    let before = await placer.read(pid)
    field.note("⌘V")
    let (landed, polls) = await placer.waitForLanding(pasted, before: before, pid: pid, since: placer.now())
    return await placer.place(pasted, before: before, landed: landed, polls: polls, waited: .zero, pid: pid)
}

private func field(count: Int, _ location: Int, _ length: Int = 0) -> TextFieldState {
    TextFieldState(count: count, selection: FieldRange(location: location, length: length))
}

// MARK: - What was pasted, and where it lands

@Test func pastedTextIsCountedInUTF16AndItsTailInClusters() {
    // "Hi 👋🏽\r\nthere" with the caret before the wave: 7 clusters after it, 11 UTF-16 units.
    let pasted = PastedText(text: "Hi 👋🏽\r\nthere", afterCursor: 7)
    #expect(pasted.length == 14)
    #expect(pasted.tail == "👋🏽\r\nthere")
    #expect(pasted.tail.utf16.count == 11 && pasted.tailArrows == 7, "← moves over the emoji and CRLF once each")
    #expect(pasted.arrows(overFirst: 4) == 1, "the emoji with its skin tone is one ←")
    #expect(pasted.arrows(overFirst: 5) == 2, "inside the CRLF counts it as passed")
    #expect(pasted.arrows(overFirst: 6) == 2)
    #expect(pasted.arrows(overFirst: 11) == 7)
    #expect(PastedText(text: "no cursor", afterCursor: 0).tail.isEmpty)
}

@Test func theLandingIsWhatThePasteReplaces() {
    let twelve = PastedText(text: "twelve chars", afterCursor: 3)
    // A plain paste at a caret: the caret moves on by the text, and the field grows by it.
    let plain = PasteLanding(before: field(count: 100, 40), pasted: twelve)
    #expect(plain.caret == 52 && plain.count == 112)
    // Over a selection, which the paste replaces.
    let overSelection = PasteLanding(before: field(count: 100, 40, 5), pasted: twelve)
    #expect(overSelection.caret == 52 && overSelection.count == 107)
    // An expansion: ⌫ presses delete the keyword before the caret first (the reviewer's MUST 1).
    let expansion = PasteLanding(
        before: field(count: 100, 40), pasted: PastedText(text: "twelve chars", afterCursor: 3, deletedBefore: 4))
    #expect(expansion.caret == 48 && expansion.count == 108)
    #expect(expansion.landed(field(count: 108, 48)))
    #expect(!expansion.landed(field(count: 96, 36)), "the keyword gone, the paste not yet")
    #expect(!expansion.landed(field(count: 100, 40)), "nothing yet")
    // What can't change says nothing: a paste as long as the keyword it replaces leaves both where they were.
    let same = PasteLanding(
        before: field(count: 100, 40), pasted: PastedText(text: "abcd", afterCursor: 1, deletedBefore: 4))
    #expect(!same.isObservable)
    // Nor can one shorter than the keyword: on the way down, the ⌫s pass through the place it would end at.
    let shorter = PasteLanding(
        before: field(count: 100, 40), pasted: PastedText(text: "abc", afterCursor: 1, deletedBefore: 5))
    #expect(!shorter.isObservable)
    // Where the caret is known, the length alone isn't enough (the reviewer's note).
    #expect(!plain.landed(field(count: 112, 40)), "the length grew, but the caret hasn't moved")
    // A field that reports only its length.
    let countOnly = PasteLanding(before: TextFieldState(count: 100, selection: nil), pasted: twelve)
    #expect(countOnly.caret == nil && countOnly.count == 112 && countOnly.isObservable)
    #expect(countOnly.landed(TextFieldState(count: 112, selection: nil)))
}

// MARK: - Placing the caret

@Test func theCaretIsSetThroughAccessibilityOnceThePasteLands() async {
    // The app takes the paste on the fourth read: two polls see nothing yet.
    let pasted = PastedText(text: "logging.info(\"Hello world!\")\n    return 0", afterCursor: 13)
    let field = FakeField(before: field(count: 100, 40), after: field(count: 141, 81), landsOnRead: 4)
    let report = await paste(pasted, into: field)
    #expect(
        field.events == [
            "read 1", "⌘V", "read 2", "sleep 15 ms", "read 3", "sleep 15 ms", "read 4 landed", "set 68",
            "read 5 landed",
        ], "no caret move before the paste is seen")
    #expect(report.path == .accessibility && report.arrows == 0 && report.polls == 3)
    #expect(report.pasted == 41 && report.tail == 13)
}

@Test func aFieldThatTakesNoCaretGetsPacedArrowsFromWhereItIs() async {
    let tail = String(repeating: "x", count: 25)
    let pasted = PastedText(text: "start " + tail, afterCursor: 25)
    let field = FakeField(before: field(count: 0, 0), after: field(count: 31, 31), landsOnRead: 2)
    field.settable = false
    let report = await paste(pasted, into: field)
    #expect(
        field.events == [
            "read 1", "⌘V", "read 2 landed", "set 6", "read 3 landed", "← ×10 to 200", "sleep 10 ms",
            "← ×10 to 200", "sleep 10 ms", "← ×5 to 200",
        ], "10 at a time, with a pause between")
    #expect(report.path == .arrows && report.arrows == 25)
}

@Test func aCaretThatStoppedPartwayGetsArrowsForTheRest() async {
    // "ab👋🏽cd" after {cursor}: the field put the caret 4 units past where it was set, inside the emoji.
    let pasted = PastedText(text: "x{ab👋🏽cd", afterCursor: 5)
    let field = FakeField(before: field(count: 0, 0), after: field(count: 10, 10), landsOnRead: 2)
    field.setLands = { $0 + 4 }
    let report = await paste(pasted, into: field)
    #expect(field.events.suffix(3) == ["set 2", "read 3 landed", "← ×3 to 200"], "a, b and the emoji")
    #expect(report.path == .arrows && report.arrows == 3)
}

@Test func aCaretThatWentSomewhereElseIsLeftThere() async {
    let pasted = PastedText(text: "abc def", afterCursor: 3)
    let field = FakeField(before: field(count: 0, 0), after: field(count: 7, 7), landsOnRead: 2)
    field.setLands = { _ in 1 }
    let report = await paste(pasted, into: field)
    #expect(report.path == .unplaced && report.arrows == 0)
    #expect(!field.events.contains { $0.hasPrefix("←") })
}

@Test func aFieldThatReportsNothingGetsArrowsAfterTheSettleTime() async {
    let pasted = PastedText(text: "Dear , thanks", afterCursor: 8)
    let field = FakeField()
    let report = await paste(pasted, into: field)
    #expect(field.events == ["read 1", "⌘V", "sleep 150 ms", "← ×8 to 200"])
    #expect(report.path == .arrowsUnreported && report.polls == 0)
}

@Test func aPasteTheFieldNeverShowsWaitsASecondByTheClockThenUsesArrows() async {
    let pasted = PastedText(text: "Dear , thanks", afterCursor: 8)
    let field = FakeField(before: field(count: 100, 40), after: field(count: 113, 53))
    let report = await paste(pasted, into: field)
    // Polls 15 ms apart until the clock passes a second after ⌘V: 67 waits, so 68 polls.
    let polls = Int((CaretPlacer.landingDeadline / CaretPlacer.pollInterval).rounded(.up)) + 1
    #expect(report.polls == polls && field.events.filter { $0.hasPrefix("read") }.count == 1 + polls)
    #expect(field.events.suffix(2) == ["sleep 150 ms", "← ×8 to 200"])
    #expect(report.path == .arrowsAfterTimeout)
}

@Test func theWaitEndsASecondAfterThePasteHoweverSlowTheReads() async {
    // The reviewer's REQUIRED item: an app whose reads take 300 ms never shows the paste. Counting polls, the wait
    // was 66 × 300 ms; by the clock it's about a second, and a few polls.
    let field = FakeField(before: field(count: 100, 40), after: field(count: 113, 53))
    field.readDelay = .milliseconds(300)
    let placer = CaretPlacer(system: field)
    let pasted = PastedText(text: "Dear , thanks", afterCursor: 8)
    let before = await placer.read(pid)
    let posted = ContinuousClock.now
    let (landed, polls) = await placer.waitForLanding(pasted, before: before, pid: pid, since: posted)
    let waited = posted.duration(to: .now)
    // The poll count proves the wait goes by the clock (counting polls took 66). The upper bound only catches a wait
    // that never ends, so it leaves room for a CI runner that stalls for seconds (5.85 s seen on #129).
    #expect(landed == nil && polls <= 5, "\(polls) polls")
    #expect(waited >= .seconds(1) && waited < .seconds(30), "\(waited)")
}

@Test func aReadThatFailsEndsTheWaitAtOnce() async {
    // The second poll times out, as a hung app's read does: no more polls, then the settle time and arrows.
    let field = FakeField(before: field(count: 100, 40), after: field(count: 113, 53))
    field.failsFromRead = 3
    let report = await paste(PastedText(text: "Dear , thanks", afterCursor: 8), into: field)
    #expect(field.events == ["read 1", "⌘V", "read 2", "sleep 15 ms", "read 3 failed", "sleep 150 ms", "← ×8 to 200"])
    #expect(report.path == .arrowsAfterTimeout && report.polls == 2)
}

@Test func aSetTheFieldTookIsTrustedWhenTheReadBackFails() async {
    // The reviewer's note: ← presses on top of a set that worked would move the caret twice.
    let took = FakeField(before: field(count: 0, 0), after: field(count: 13, 13), landsOnRead: 2)
    took.failsFromRead = 3
    let report = await paste(PastedText(text: "Dear , thanks", afterCursor: 8), into: took)
    #expect(took.events.suffix(2) == ["set 5", "read 3 failed"])
    #expect(report.path == .accessibility && report.arrows == 0)
    let refused = FakeField(before: field(count: 0, 0), after: field(count: 13, 13), landsOnRead: 2)
    refused.settable = false
    refused.failsFromRead = 3
    let arrows = await paste(PastedText(text: "Dear , thanks", afterCursor: 8), into: refused)
    #expect(arrows.path == .arrows && arrows.arrows == 8, "a set the field refused isn't")
}

@Test func anExpansionAndAPasteOverASelectionLandWithoutWaitingTheFullSecond() async {
    // The reviewer's MUST 1: the keyword's ⌫s, or the replaced selection, are counted, so the landing is seen at once.
    let expansion = PastedText(text: "Best regards,\nAda", afterCursor: 0, deletedBefore: 4)
    let typed = FakeField(before: field(count: 100, 40), after: field(count: 113, 53), landsOnRead: 3)
    let placer = placer(typed)
    let before = await placer.read(pid)
    let (landed, polls) = await placer.waitForLanding(expansion, before: before, pid: pid, since: placer.now())
    #expect(landed != nil && polls == 2)
    let selected = FakeField(before: field(count: 100, 40, 5), after: field(count: 112, 57), landsOnRead: 2)
    let overSelection = await paste(PastedText(text: "seventeen chars!!", afterCursor: 2), into: selected)
    #expect(overSelection.path == .accessibility && overSelection.polls == 1)
    #expect(selected.events.contains("set 55"))
}

@Test func theReportHoldsNumbersOnly() async {
    let pasted = PastedText(text: "secret plan{cursor}", afterCursor: 0)
    let report = CaretReport(path: .accessibility, waitMilliseconds: 42, polls: 3, arrows: 0, pasted: 18, tail: 0)
    #expect(report.line == "snippet caret path=accessibility waitMs=42 polls=3 arrows=0 pasted=18 tail=0")
    #expect(!report.line.contains("secret") && pasted.length == 19)
}

@Test func theRestoreWaitsForTheLandingAndItsDelay() async {
    let gate = Gate()
    let watch = PasteWatch(posted: .now, delay: .zero) {
        await gate.wait()
        return (nil, 0)
    }
    let done = Done()
    let waiting = Task {
        await watch.wait()
        await done.set()
    }
    try? await Task.sleep(for: .milliseconds(50))
    let early = await done.value
    #expect(!early, "not before the paste has landed")
    await gate.open()
    await waiting.value
    let late = await done.value
    #expect(late)
}

private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private actor Done {
    private(set) var value = false
    func set() { value = true }
}
