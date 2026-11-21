import Foundation

/// The `RemoteImageRetry` of sources whose entries have left `RemoteImageStore`'s memory, so a failing URL isn't
/// tried again at once when it's next asked for. Only a source in back-off or failed for good is kept
/// (`failures > 0 || isFinal`): a loaded image's refresh time is the disk cache's `fetchedAt`. At most `capacity`
/// are kept, the oldest out first.
public struct RemoteImageRetries: Sendable, Equatable {
    public static let defaultCapacity = 1000

    public let capacity: Int
    private var kept: [String: RemoteImageRetry] = [:]
    /// The kept sources, oldest first.
    private var order: [String] = []

    public init(capacity: Int = defaultCapacity) {
        self.capacity = capacity
    }

    public var count: Int { kept.count }

    /// Whether a source's state is worth keeping once its entry has gone.
    public static func keeps(_ retry: RemoteImageRetry) -> Bool {
        !retry.loading && (retry.failures > 0 || retry.isFinal)
    }

    /// `source`'s entry left memory with `retry`: it's kept when it's in back-off or final, and anything kept for
    /// the source before is replaced.
    public mutating func keep(_ source: String, _ retry: RemoteImageRetry) {
        forget(source)
        guard Self.keeps(retry) else { return }
        kept[source] = retry
        order.append(source)
        while order.count > capacity {
            kept[order.removeFirst()] = nil
        }
    }

    /// The state for `source` as its entry comes back into memory: what was kept for it, else a new one.
    public mutating func take(_ source: String) -> RemoteImageRetry {
        guard let retry = kept[source] else { return RemoteImageRetry() }
        forget(source)
        return retry
    }

    private mutating func forget(_ source: String) {
        guard kept.removeValue(forKey: source) != nil else { return }
        order.removeAll { $0 == source }
    }
}
