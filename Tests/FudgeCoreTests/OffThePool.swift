import Foundation

/// Blocking work in a test (a child process, a pipe read, a semaphore) runs on a thread of its own, never on Swift's
/// shared pool or the main actor (FUD-153). A CI runner has three cores, so the pool has about three threads, and a
/// test that blocks one holds up every test waiting for a thread; a deadline fires from Dispatch, which needs neither.
enum OffThePool {
    /// Runs `work` on a new thread, and returns what it returns or throws what it throws.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try work() }) }.start()
        }
    }

    /// Like `run`, but nil once `limit` has passed without an answer; the work goes on on its thread.
    static func run<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () throws -> T) async throws
        -> T?
    {
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            Thread {
                let result = Result { try work() as T? }
                if once.claim() { continuation.resume(with: result) }
            }.start()
            after(limit) { if once.claim() { continuation.resume(returning: nil) } }
        }
    }

    /// Calls `deadline` once `limit` has passed, from a Dispatch queue: it fires with the pool full or the main actor
    /// held up, which a `Task.sleep` wouldn't.
    static func after(_ limit: Duration, _ deadline: @escaping @Sendable () -> Void) {
        let milliseconds = max(0, Int(limit / .milliseconds(1)))
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: deadline)
    }
}

/// True for the first caller only: an answer and its deadline race, and only one resumes.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
