import AppKit
import FudgeCore
import Observation

/// The https images extensions show, by source. A view reads an entry's `image`; SwiftUI draws it again when the
/// image arrives, and only the views showing that image are redrawn.
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
        /// Refused, failed or not an image: show the fallback.
        fileprivate(set) var failed = false
    }

    /// Decoded images stay in memory up to this many sources; past that the oldest are read from disk again.
    private static let capacity = 300

    private let loader: RemoteImageLoader
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(loader: RemoteImageLoader) {
        self.loader = loader
    }

    /// The entry for `source`, starting its load the first time it's asked for.
    func entry(for source: String) -> Entry {
        if let entry = entries[source] { return entry }
        let entry = Entry()
        entries[source] = entry
        order.append(source)
        if order.count > Self.capacity {
            for old in order.prefix(order.count - Self.capacity) { entries[old] = nil }
            order.removeFirst(order.count - Self.capacity)
        }
        guard let url = URL(string: source) else {
            entry.failed = true
            return entry
        }
        let loader = loader
        Task {
            let body = await loader.load(url)
            // At most two decodes at once: a maximal image peaks at about 128 MB while it decodes.
            await Self.decodeSlots.acquire()
            let image = await Task.detached { body.flatMap(Self.decode) }.value
            await Self.decodeSlots.release()
            entry.image = image
            entry.failed = image == nil
        }
        return entry
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
