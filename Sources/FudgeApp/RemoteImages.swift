import AppKit
import FudgeCore
import Observation

/// The https images extensions show, by source. A view reads an entry's `image`; SwiftUI draws it again when the
/// image arrives, and only the views showing that image are redrawn. When to load is `RemoteImageStore`'s call (core);
/// this adds the observable entry and the decoding.
@MainActor
enum RemoteImages {
    static let shared = RemoteImageStore<Entry>(
        loader: RemoteImageLoader(
            cache: RemoteImageCache(directory: FudgePaths.standard().imageCacheDirectory),
            fetcher: URLSessionImageFetcher()),
        decode: decode)

    @MainActor
    @Observable
    final class Entry: RemoteImageEntry {
        var image: NSImage?
        var failed = false

        init() {}
    }

    /// At most two decodes at once: a maximal image peaks at about 128 MB while it decodes.
    private static let decodeSlots = AsyncLimiter(limit: 2)

    private static func decode(_ body: Data) async -> NSImage? {
        await decodeSlots.acquire()
        let image = await Task.detached { decodeNow(body) }.value
        await decodeSlots.release()
        return image
    }

    /// Raster images as thumbnails; SVG through NSImage, which draws it.
    nonisolated private static func decodeNow(_ body: Data) -> NSImage? {
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
