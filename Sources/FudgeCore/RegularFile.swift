import Foundation

/// Reading a small file that something else writes: never through a link, never waiting on a FIFO or a device, and
/// never more than a size.
enum RegularFile {
    /// The file's bytes, or nil when it's missing, a link, not a regular file, or over `maxBytes`.
    static func read(_ url: URL, maxBytes: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= maxBytes else {
            return nil
        }
        // A file that grew since `fstat` is still read only up to its limit.
        guard let data = try? handle.read(upToCount: maxBytes + 1) ?? Data(), data.count <= maxBytes else { return nil }
        return data
    }
}
