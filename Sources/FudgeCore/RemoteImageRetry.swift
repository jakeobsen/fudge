import Foundation

/// When a remote image is loaded again (SPEC-059). Nothing runs on a timer: `RemoteImageStore` asks `isDue` each time
/// a view asks for the source, so a run fetches no more than the views need.
///
/// - A retryable failure (`RemoteImageFailure.isRetryable`) is tried again after 1 min, then 5 min, 30 min, and every
///   2 h from then on, or after a 429's or 503's `Retry-After` when that's longer, up to 2 h. Any other failure is
///   final for the run.
/// - An image is refreshed once it was fetched `RemoteImageCache.maxAge` ago. A failed refresh keeps the image, and
///   the next one waits another `maxAge`.
/// - Nothing starts while a load is running.
public struct RemoteImageRetry: Sendable, Equatable {
    /// The waits after the 1st, 2nd, 3rd and every later retryable failure in a row.
    public static let backOff: [TimeInterval] = [60, 5 * 60, 30 * 60, 2 * 60 * 60]
    /// The longest wait a `Retry-After` can ask for.
    public static let maxWait: TimeInterval = 2 * 60 * 60

    public private(set) var loading = false
    /// When the image shown was fetched; nil while there's none.
    public private(set) var fetchedAt: Date?
    /// Retryable failures in a row, with no image shown.
    public private(set) var failures = 0
    /// When the next load is due; nil before the first.
    public private(set) var next: Date?
    /// A failure that isn't retried this run.
    public private(set) var isFinal = false

    public init() {}

    public func isDue(now: Date) -> Bool {
        guard !loading, !isFinal else { return false }
        guard let next else { return true }
        return now >= next
    }

    public mutating func started() {
        loading = true
    }

    /// The image arrived (a new body, or a 304 keeping the one shown), fetched at `fetchedAt`: from the network just
    /// now, or earlier when it came from the cache.
    public mutating func loaded(fetchedAt: Date) {
        loading = false
        self.fetchedAt = fetchedAt
        failures = 0
        isFinal = false
        next = fetchedAt.addingTimeInterval(RemoteImageCache.maxAge)
    }

    public mutating func failed(_ failure: RemoteImageFailure, now: Date) {
        loading = false
        if fetchedAt != nil {
            next = now.addingTimeInterval(RemoteImageCache.maxAge)
            return
        }
        guard failure.isRetryable else {
            isFinal = true
            return
        }
        failures += 1
        var wait = Self.backOff[min(failures, Self.backOff.count) - 1]
        if case .http(_, let retryAfter?) = failure { wait = max(wait, min(retryAfter, Self.maxWait)) }
        next = now.addingTimeInterval(wait)
    }
}
