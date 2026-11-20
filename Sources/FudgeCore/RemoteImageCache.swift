import CryptoKit
import Foundation
import ImageIO

/// Remote images on disk: `image-cache/<sha256 of the URL>` holds the body, and `<same>.json` the sidecar. Least
/// recently used entries go first once the folder passes `capacity`.
public struct RemoteImageCache: Sendable {
    /// What fudge knows about a cached body.
    public struct Entry: Codable, Equatable, Sendable {
        public var fetchedAt: Date
        public var etag: String?
        public var lastModified: String?

        public init(fetchedAt: Date, etag: String? = nil, lastModified: String? = nil) {
            self.fetchedAt = fetchedAt
            self.etag = etag
            self.lastModified = lastModified
        }
    }

    /// An entry this old is still shown, but revalidated.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    public let directory: URL
    public let capacity: Int

    public init(directory: URL, capacity: Int = 200_000_000) {
        self.directory = directory
        self.capacity = capacity
    }

    public static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func isFresh(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.fetchedAt) < maxAge
    }

    private func bodyFile(_ url: URL) -> URL {
        directory.appendingPathComponent(Self.key(for: url))
    }

    private func sidecarFile(_ url: URL) -> URL {
        directory.appendingPathComponent(Self.key(for: url) + ".json")
    }

    /// The cached body and its sidecar, marking the entry as just used.
    public func read(_ url: URL, now: Date = Date()) -> (entry: Entry, body: Data)? {
        guard let sidecar = try? Data(contentsOf: sidecarFile(url)),
            let entry = try? Self.decoder.decode(Entry.self, from: sidecar),
            let body = try? Data(contentsOf: bodyFile(url))
        else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: bodyFile(url).path)
        return (entry, body)
    }

    /// Saves a body and its sidecar, then trims the folder to `capacity`.
    public func store(_ url: URL, body: Data, entry: Entry, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body.write(to: bodyFile(url), options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: bodyFile(url).path)
        try Self.encoder.encode(entry).write(to: sidecarFile(url), options: .atomic)
        evict()
    }

    /// Replaces the sidecar only: a revalidation answered 304.
    public func update(_ url: URL, entry: Entry) throws {
        try Self.encoder.encode(entry).write(to: sidecarFile(url), options: .atomic)
    }

    /// Drops least recently used entries (by the body's modification date) until the folder fits `capacity`.
    public func evict() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys)
        else { return }
        var bodies: [(file: URL, size: Int, used: Date)] = []
        var total = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            total += size
            if file.pathExtension != "json" {
                bodies.append((file, size, values?.contentModificationDate ?? .distantPast))
            }
        }
        guard total > capacity else { return }
        for body in bodies.sorted(by: { $0.used < $1.used }) {
            let sidecar = body.file.appendingPathExtension("json")
            let sidecarSize = (try? sidecar.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try? FileManager.default.removeItem(at: body.file)
            try? FileManager.default.removeItem(at: sidecar)
            total -= body.size + sidecarSize
            if total <= capacity { break }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Reads a downloaded body as an image without trusting it: the header's size is checked before anything is
/// decoded, and raster images are decoded as thumbnails.
public enum RemoteImageDecoder {
    public enum Kind: Equatable, Sendable {
        case raster(width: Int, height: Int)
        case svg
    }

    public enum Problem: Error, Equatable, Sendable {
        case notAnImage
        case tooLarge
    }

    /// An image whose header gives either side as more than this is refused.
    public static let maxSide = 16_384
    /// Raster images are decoded to at most this many pixels on their longer side.
    public static let maxPixelSize = 2048
    /// SVG is parsed whole, so it gets a smaller byte limit than other images.
    public static let maxSVGBytes = 1_000_000

    /// What `data` is, from its header alone.
    public static func inspect(_ data: Data) throws -> Kind {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, options),
            CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        {
            guard width > 0, height > 0 else { throw Problem.notAnImage }
            guard width <= maxSide, height <= maxSide else { throw Problem.tooLarge }
            return .raster(width: width, height: height)
        }
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        if head.contains("<svg") {
            guard data.count <= maxSVGBytes else { throw Problem.tooLarge }
            return .svg
        }
        throw Problem.notAnImage
    }

    /// SVG ready for AppKit, which draws nothing inside an `<a>` element: the links are unwrapped, keeping what
    /// they hold. A link does nothing in an image anyway.
    public static func svgForDrawing(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let unwrapped = text.replacingOccurrences(
            of: #"<a\b[^>]*>|</a\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        return Data(unwrapped.utf8)
    }

    /// A raster image decoded to at most `maxPixelSize` on its longer side, turned upright.
    public static func thumbnail(_ data: Data) -> CGImage? {
        guard case .raster = try? inspect(data),
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
