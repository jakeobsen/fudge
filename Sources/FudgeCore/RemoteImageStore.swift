import Foundation

/// What a view draws for one remote image source, kept by `RemoteImageStore`. The app's is `@Observable`, so only
/// the views showing that image redraw when it changes.
@MainActor
public protocol RemoteImageEntry: AnyObject {
    associatedtype Image
    init()
    /// The image shown, once one has loaded.
    var image: Image? { get set }
    /// Refused, failed or not an image: show the fallback. It stays while a retry runs, until one succeeds.
    var failed: Bool { get set }
}

/// The https images extensions show, by source, without the drawing: `RemoteImages` (app) is one, holding NSImages.
///
/// Each time a view asks for a source, its `RemoteImageRetry` says whether to load it: the first time, again after a
/// back-off when a load failed, and a refresh once the image is `RemoteImageCache.maxAge` old. A first load that
/// comes from the disk cache older than that is shown at once and refreshed straight away, not at the next ask.
/// Decoded images stay in memory up to `capacity` sources; past that, the oldest are read from disk again. A source
/// that leaves memory in back-off, or failed for good, keeps that (`RemoteImageRetries`): asked for again, it shows
/// the fallback and loads only when it's due.
@MainActor
public final class RemoteImageStore<Entry: RemoteImageEntry> {
    /// Turns a loaded body into an image, or nil when it isn't one.
    public typealias Decode = @MainActor (Data) async -> Entry.Image?

    public static var defaultCapacity: Int { 300 }

    @MainActor
    private final class Source {
        let entry = Entry()
        var retry: RemoteImageRetry

        init(retry: RemoteImageRetry) {
            self.retry = retry
            // It failed before it left memory: the fallback shows until a retry succeeds.
            if RemoteImageRetries.keeps(retry) { entry.failed = true }
        }
    }

    private let loader: RemoteImageLoader
    private let capacity: Int
    private let now: () -> Date
    private let decode: Decode
    private var sources: [String: Source] = [:]
    private var order: [String] = []
    private var retries: RemoteImageRetries
    private var running: [Int: Task<Void, Never>] = [:]
    private var nextTask = 0

    public init(
        loader: RemoteImageLoader, capacity: Int = defaultCapacity,
        retries: RemoteImageRetries = RemoteImageRetries(), now: @escaping () -> Date = { Date() },
        decode: @escaping Decode
    ) {
        self.loader = loader
        self.capacity = capacity
        self.retries = retries
        self.now = now
        self.decode = decode
    }

    /// The entry for `source`, starting its load the first time it's asked for, and again when it's due.
    public func entry(for source: String) -> Entry {
        let current = sources[source] ?? add(source)
        guard current.retry.isDue(now: now()) else { return current.entry }
        guard let url = URL(string: source) else {
            current.entry.failed = true
            current.retry.failed(.refused, now: now())
            return current.entry
        }
        load(url, source, current)
        return current.entry
    }

    /// Waits until every load started so far has finished, with the refreshes they start. For tests.
    public func loadsFinished() async {
        while let task = running.values.first {
            await task.value
        }
    }

    /// The sources kept after leaving memory, for tests.
    var keptRetries: RemoteImageRetries { retries }

    private func add(_ source: String) -> Source {
        let added = Source(retry: retries.take(source))
        sources[source] = added
        order.append(source)
        while order.count > capacity {
            let old = order.removeFirst()
            // One still loading is kept when its load ends (`finish`).
            if let gone = sources.removeValue(forKey: old) { retries.keep(old, gone.retry) }
        }
        return added
    }

    /// Loads `url` for `current`: a refresh when it shows an image already. A 304 or a failed refresh keeps that
    /// image; a failed load keeps the fallback.
    private func load(_ url: URL, _ source: String, _ current: Source) {
        current.retry.started()
        let refreshing = current.entry.image != nil
        let id = nextTask
        nextTask += 1
        // The task runs on the main actor, so it can't start, or end, before it's in `running`.
        running[id] = Task {
            let result = await loader.load(url, refreshing: refreshing)
            await finish(result, refreshing: refreshing, url, source, current)
            running[id] = nil
        }
    }

    private func finish(
        _ result: RemoteImageLoad, refreshing: Bool, _ url: URL, _ source: String, _ current: Source
    ) async {
        switch result {
        case .loaded(let body, let fetchedAt):
            if let image = await decode(body) {
                current.entry.image = image
                current.entry.failed = false
                current.retry.loaded(fetchedAt: fetchedAt)
            } else {
                failed(current, .notAnImage)
            }
        case .unchanged(let fetchedAt):
            current.retry.loaded(fetchedAt: fetchedAt)
        case .failed(let failure):
            failed(current, failure)
        }
        // It left memory while loading: keep how the load ended, unless the source is back already.
        if sources[source] !== current {
            if sources[source] == nil { retries.keep(source, current.retry) }
            return
        }
        // A first load that came from the disk cache, already due a refresh: it's shown now, and refreshed now. Only
        // after a first load, so a refresh never starts another.
        if case .loaded = result, !refreshing, current.entry.image != nil,
            current.retry.isDue(now: now())
        {
            load(url, source, current)
        }
    }

    private func failed(_ current: Source, _ failure: RemoteImageFailure) {
        if current.entry.image == nil { current.entry.failed = true }
        current.retry.failed(failure, now: now())
    }
}
