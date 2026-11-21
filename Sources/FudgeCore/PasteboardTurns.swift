import Foundation

/// One turn at a time for everything that snapshots the pasteboard and writes it back: a paste (`Paste`) and
/// `getSelectedText()`'s ⌘C fallback (`SelectedText`). The app makes one and hands it to both (FUD-61).
///
/// Without it, a fallback right after a paste would take Fudge's pasted content for the user's clipboard while the
/// paste's restore was still to come. It would then write that content back, and the restore, seeing the pasteboard
/// changed, would leave it there: the user's clipboard would be lost.
@MainActor
public final class PasteboardTurns {
    /// Whether a turn is running, and the turns waiting, oldest first.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Paste's restore while it's pending (`Paste.pending`). It runs about a second after ⌘V, once the paste's turn has
    /// ended, so a turn that snapshots the pasteboard waits for it first (`restoreSettled`). The restore never takes a
    /// turn itself: the fallback waits for it while holding one.
    var restore: Task<Void, Never>?
    /// The change counts of Fudge's own writes (a paste and its restore, the ⌘C fallback's copy and its restore), the
    /// last `ownLimit`, so clipboard history leaves them out (SPEC-077).
    private var own: [Int] = []
    static let ownLimit = 32

    public init() {}

    /// Whether a paste or a ⌘C fallback is running, or a paste's restore is still to come: the pasteboard may hold
    /// Fudge's content, so clipboard history looks again later.
    public var isBusy: Bool { busy || restore != nil }

    /// Notes that the pasteboard's `changeCount` is now one of Fudge's own writes.
    func markOwn(_ changeCount: Int) {
        own.append(changeCount)
        if own.count > Self.ownLimit { own.removeFirst(own.count - Self.ownLimit) }
    }

    /// Whether `changeCount` is one of Fudge's own writes.
    public func isOwn(_ changeCount: Int) -> Bool { own.contains(changeCount) }

    /// Runs `body` once the turns before it have ended. The next turn starts when it returns.
    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await take()
        defer { end() }
        return try await body()
    }

    /// Returns once Paste's pending restore, if there is one, has written the user's clipboard back, or found it
    /// changed by someone else and left it. It's never hurried: the app pasted into may not have read the pasted
    /// content yet.
    func restoreSettled() async {
        await restore?.value
    }

    private func take() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn to the oldest waiting one, or frees it.
    private func end() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
