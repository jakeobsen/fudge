import Foundation

// Where a snippet's `{cursor}` puts the caret after a paste (SPEC-101, FUD-133). ⌘V is handled by the app on a later
// turn of its run loop, or in another process, so ← presses sent straight after it can arrive before the pasted text
// and leave the caret short. `CaretPlacer` waits until the field shows the paste, then sets the caret through the
// Accessibility API, or sends paced ← presses where it can't. It reads only the field's length and selection, never
// its text.

/// A selection or caret, in UTF-16 units, as the Accessibility API counts (`kAXSelectedTextRangeAttribute`).
public struct FieldRange: Sendable, Equatable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public static func caret(_ location: Int) -> FieldRange { FieldRange(location: location, length: 0) }
}

/// What the focused text field says about itself: its length (`kAXNumberOfCharactersAttribute`) and its selection,
/// each nil when it isn't reported. Never its text.
public struct TextFieldState: Sendable, Equatable {
    public var count: Int?
    public var selection: FieldRange?

    public init(count: Int?, selection: FieldRange?) {
        self.count = count
        self.selection = selection
    }
}

/// The system side of placing the caret: the focused text field of an app, through the Accessibility API, and ←
/// presses. Each call blocks while the app answers (with FUD-93's 2 s timeout), so `CaretPlacer` makes them off the
/// main actor.
public protocol CaretSystem: Sendable {
    /// The app's focused element's length and selection; nil when there's no focused element or it reports neither.
    func state(of pid: Int32) -> TextFieldState?
    /// Sets the focused element's selection to an empty range at `location`; false when the range can't be set there
    /// or the app refused it.
    func setCaret(_ location: Int, of pid: Int32) -> Bool
    /// Posts ←, key down then key up, `count` times, to the application `pid`.
    func postLeftArrows(_ count: Int, to pid: Int32)
}

/// What was pasted, for placing the caret: the text's length, the text after `{cursor}`, and what the paste's ⌫
/// presses delete before it (a snippet expansion's keyword), all in UTF-16 units.
public struct PastedText: Sendable, Equatable {
    public var length: Int
    /// The text after `{cursor}`, which the caret goes back over. Fudge's own snippet text, kept only for the paste.
    public var tail: String
    /// What ⌫ presses sent before ⌘V delete, when the paste replaces typed text.
    public var deletedBefore: Int

    /// `text` with the caret `afterCursor` grapheme clusters from its end.
    public init(text: String, afterCursor: Int, deletedBefore: Int = 0) {
        length = text.utf16.count
        tail = String(text.suffix(max(0, afterCursor)))
        self.deletedBefore = deletedBefore
    }

    /// The ← presses over the whole tail: one per grapheme cluster, as a text field moves.
    public var tailArrows: Int { tail.count }

    /// The ← presses over the tail's first `units` UTF-16 units, for a caret that stopped partway; a cluster the
    /// caret is inside counts as passed.
    func arrows(overFirst units: Int) -> Int {
        var counted = 0
        var arrows = 0
        for cluster in tail where counted < units {
            counted += cluster.utf16.count
            arrows += 1
        }
        return arrows
    }
}

/// What the field should show once it has taken the paste (SPEC-101 §1, the reviewer's MUST 1): the paste replaces
/// the selection, or, with none, what the ⌫ presses deleted before the caret.
public struct PasteLanding: Sendable, Equatable {
    /// The caret just after the pasted text, when the selection was reported.
    public var caret: Int?
    /// The field's length then, when it was reported.
    public var count: Int?

    public init(before: TextFieldState, pasted: PastedText) {
        var removed = pasted.deletedBefore
        if let selection = before.selection {
            if selection.length > 0 {
                removed = selection.length
                caret = selection.location + pasted.length
            } else {
                caret = selection.location - pasted.deletedBefore + pasted.length
            }
            // A caret where it already is says nothing about the paste.
            if caret == selection.location, selection.length == 0 { caret = nil }
        }
        if let before = before.count {
            let after = before - removed + pasted.length
            count = after == before ? nil : after
        }
    }

    /// Whether anything about the field can tell that the paste has landed.
    public var isObservable: Bool { caret != nil || count != nil }

    /// Whether `state` shows the paste: the caret just after it, or the length it gives.
    public func landed(_ state: TextFieldState) -> Bool {
        if let caret, state.selection == .caret(caret) { return true }
        if let count, state.count == count { return true }
        return false
    }
}

/// How the caret was placed, for the launcher's log (SPEC-101 §4): numbers only, never text or app names.
public struct CaretReport: Sendable, Equatable {
    public enum Path: String, Sendable {
        /// Set through `kAXSelectedTextRangeAttribute`.
        case accessibility
        /// ← presses once the paste was seen.
        case arrows
        /// ← presses after waiting the full time for a paste the field never showed.
        case arrowsAfterTimeout
        /// ← presses after the settle time, for a field that reports no length or selection.
        case arrowsUnreported
        /// The caret was somewhere Fudge couldn't account for after setting it, so it was left there.
        case unplaced
    }

    public var path: Path
    /// From ⌘V until the paste was seen, or the wait ended.
    public var waitMilliseconds: Int
    public var polls: Int
    public var arrows: Int
    /// The pasted text's and its tail's lengths, in UTF-16 units.
    public var pasted: Int
    public var tail: Int

    /// One line for the log.
    public var line: String {
        "snippet caret path=\(path.rawValue) waitMs=\(waitMilliseconds) polls=\(polls) arrows=\(arrows) "
            + "pasted=\(pasted) tail=\(tail)"
    }
}

/// Places the caret after a paste (SPEC-101). Every call into `system` runs on a dispatch queue, never the main
/// actor, so an app that doesn't answer holds a background thread for at most its 2 s timeout, never Fudge.
public struct CaretPlacer: Sendable {
    public let system: any CaretSystem
    /// Waits between polls and ← batches; tests pass one that doesn't.
    let sleep: @Sendable (Duration) async -> Void
    /// Polls for the paste every 15 ms, about a second in all.
    static let pollInterval: Duration = .milliseconds(15)
    static let maxPolls = 66
    /// After a paste the field can't show, or didn't in time: a moment for it to land anyway.
    static let settle: Duration = .milliseconds(150)
    /// ← presses go 10 at a time, 10 ms apart, so the app's queue keeps up.
    static let batch = 10
    static let batchPause: Duration = .milliseconds(10)

    public init(system: any CaretSystem, sleep: @escaping @Sendable (Duration) async -> Void = CaretPlacer.realSleep) {
        self.system = system
        self.sleep = sleep
    }

    public static let realSleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The focused field before any key goes to the app.
    public func read(_ pid: Int32) async -> TextFieldState? {
        let system = system
        return await Self.offMain { system.state(of: pid) }
    }

    /// Polls until the field shows the paste (`PasteLanding`), about a second at most. The state that showed it, or
    /// nil when the field can't tell or didn't in time; and how many polls it took.
    public func waitForLanding(_ pasted: PastedText, before: TextFieldState?, pid: Int32) async -> (
        landed: TextFieldState?, polls: Int
    ) {
        guard let before else { return (nil, 0) }
        let landing = PasteLanding(before: before, pasted: pasted)
        guard landing.isObservable else { return (nil, 0) }
        let system = system
        for poll in 1...Self.maxPolls {
            if let state = await Self.offMain({ system.state(of: pid) }), landing.landed(state) {
                return (state, poll)
            }
            await sleep(Self.pollInterval)
        }
        return (nil, Self.maxPolls)
    }

    /// Puts the caret before the tail (SPEC-101 §2, §3), once `waitForLanding` has said where the paste is: through
    /// the Accessibility API, read back to check it took; else, or for what's left, paced ← presses.
    public func place(
        _ pasted: PastedText, before: TextFieldState?, landed: TextFieldState?, polls: Int, waited: Duration,
        pid: Int32
    ) async -> CaretReport {
        var report = CaretReport(
            path: .arrows,
            waitMilliseconds: Int(waited.components.seconds * 1000)
                + Int(waited.components.attoseconds / 1_000_000_000_000_000), polls: polls, arrows: 0,
            pasted: pasted.length, tail: pasted.tail.utf16.count)
        let system = system
        guard let landed else {
            await sleep(Self.settle)
            let observable = before.map { PasteLanding(before: $0, pasted: pasted).isObservable } ?? false
            report.path = observable ? .arrowsAfterTimeout : .arrowsUnreported
            report.arrows = pasted.tailArrows
            await postArrows(report.arrows, to: pid)
            return report
        }
        // Where the paste ended: the caret the field shows, else where it should be.
        let end =
            landed.selection.flatMap { $0.length == 0 ? $0.location : nil }
            ?? before.flatMap { PasteLanding(before: $0, pasted: pasted).caret }
        guard let end, end - report.tail >= 0 else {
            report.arrows = pasted.tailArrows
            await postArrows(report.arrows, to: pid)
            return report
        }
        let target = end - report.tail
        _ = await Self.offMain { system.setCaret(target, of: pid) }
        let back = await Self.offMain { system.state(of: pid) }?.selection
        if back == .caret(target) {
            report.path = .accessibility
            return report
        }
        // From where the caret is now (the reviewer's note): all the way when it didn't move, the rest when it
        // stopped partway, and nothing when it went somewhere else.
        if let back, back.length == 0, back.location > target, back.location <= end {
            report.arrows = pasted.arrows(overFirst: back.location - target)
        } else if back == nil {
            report.arrows = pasted.tailArrows
        } else {
            report.path = .unplaced
            return report
        }
        await postArrows(report.arrows, to: pid)
        return report
    }

    /// `count` ← presses, 10 at a time with a pause between.
    func postArrows(_ count: Int, to pid: Int32) async {
        var left = count
        let system = system
        while left > 0 {
            let now = min(Self.batch, left)
            await Self.offMain { system.postLeftArrows(now, to: pid) }
            left -= now
            if left > 0 { await sleep(Self.batchPause) }
        }
    }

    /// Runs `work`, which may wait on another app, on a dispatch queue.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

/// A field that says nothing and takes no keys: for `Paste` where no system is given.
public struct NoCaretSystem: CaretSystem {
    public init() {}
    public func state(of pid: Int32) -> TextFieldState? { nil }
    public func setCaret(_ location: Int, of pid: Int32) -> Bool { false }
    public func postLeftArrows(_ count: Int, to pid: Int32) {}
}
