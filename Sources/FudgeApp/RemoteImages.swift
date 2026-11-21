import AppKit
import FudgeCore
import Observation

/// The https images extensions show, by source. A view reads an entry's `image`; SwiftUI draws it again when the
/// image arrives, and only the views showing that image are redrawn. Each time a view asks for a source, its
/// `RemoteImageRetry` says whether to load it again: a failed load after a back-off, an image a day old.
@MainActor
final class RemoteImages {
    static let shared = RemoteImages(
        loader: RemoteImageLoader(
            cache: RemoteImageCache(directory: FudgePaths.standard().imageCacheDirectory),
            fetcher: URLSessionImageFetcher()))

    @MainActor
    @Observable
    final class Entry {
        fileprivate(set) var image: NSImage?
        /// Refused, failed or not an image: show the fallback. It stays while a retry runs, until one succeeds.
        fileprivate(set) var failed = false
        @ObservationIgnored fileprivate var retry = RemoteImageRetry()
    }

    /// Decoded images stay in memory up to this many sources; past that the oldest are read from disk again.
    private static let capacity = 300

    private let loader: RemoteImageLoader
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(loader: RemoteImageLoader, now: @escaping () -> Date = { Date() }) {
        self.loader = loader
        self.now = now
    }

    /// The entry for `source`, starting its load the first time it's asked for, and again when it's due.
    func entry(for source: String) -> Entry {
        let entry: Entry
        if let existing = entries[source] {
            entry = existing
        } else {
            entry = Entry()
            entries[source] = entry
            order.append(source)
            if order.count > Self.capacity {
                for old in order.prefix(order.count - Self.capacity) { entries[old] = nil }
                order.removeFirst(order.count - Self.capacity)
            }
        }
        guard entry.retry.isDue(now: now()) else { return entry }
        guard let url = URL(string: source) else {
            entry.failed = true
            entry.retry.failed(.refused, now: now())
            return entry
        }
        load(url, into: entry)
        return entry
    }

    /// Loads `url` for `entry`: a refresh when it shows an image already. A 304 or a failed refresh keeps that
    /// image; a failed load keeps the fallback.
    private func load(_ url: URL, into entry: Entry) {
        entry.retry.started()
        let loader = loader
        let refreshing = entry.image != nil
        Task {
            switch await loader.load(url, refreshing: refreshing) {
            case .loaded(let body, let fetchedAt):
                // At most two decodes at once: a maximal image peaks at about 128 MB while it decodes.
                await Self.decodeSlots.acquire()
                let image = await Task.detached { Self.decode(body) }.value
                await Self.decodeSlots.release()
                if let image {
                    entry.image = image
                    entry.failed = false
                    entry.retry.loaded(fetchedAt: fetchedAt)
                } else {
                    self.failed(entry, .notAnImage)
                }
            case .unchanged(let fetchedAt):
                entry.retry.loaded(fetchedAt: fetchedAt)
            case .failed(let failure):
                self.failed(entry, failure)
            }
        }
    }

    private func failed(_ entry: Entry, _ failure: RemoteImageFailure) {
        if entry.image == nil { entry.failed = true }
        entry.retry.failed(failure, now: now())
    }

    private static let decodeSlots = AsyncLimiter(limit: 2)

    /// Raster images as thumbnails; SVG through NSImage, which draws it.
    nonisolated private static func decode(_ body: Data) -> NSImage? {
        switch try? RemoteImageDecoder.inspect(body) {
        case .raster:
            return RemoteImageDecoder.thumbnail(body).map { NSImage(cgImage: $0, size: .zero) }
        case .svg:
            return NSImage(data: RemoteImageDecoder.svgForDrawing(body))
        case nil:
            return nil
        }
    }
}
