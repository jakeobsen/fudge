import CoreServices
import Foundation

/// Watches the extensions folder, so the running app picks up an extension that `fudge build` installs, rebuilds
/// or that someone removes, with nothing to click.
///
/// One FSEvents stream with file-level events. A path counts when its first component under the folder doesn't
/// start with `.`: that leaves out `ExtensionBuilder`'s `.staging-*` and `.old-*` folders, and `.DS_Store`. A batch
/// that counts calls `onChange` `debounce` later, and further counting batches in that time join it, so a build is
/// one call. The stream delivers on the main queue, and `onChange` runs on the main actor.
@MainActor
public final class ExtensionsWatcher {
    /// How long FSEvents gathers events into one batch.
    public static let latency: TimeInterval = 0.3
    /// How long after a counting batch `onChange` runs, unless another counting batch comes first.
    public static let debounce: Duration = .milliseconds(300)

    public let directory: URL
    private let onChange: @MainActor () -> Void
    /// The folder's paths as FSEvents may report them, read when watching starts, once the folder exists.
    private var roots: [String] = []
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?

    public init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    public var isRunning: Bool { stream != nil }

    /// Starts watching, creating the folder first when it's missing (as `ExtensionBuilder` would).
    public func start() throws {
        guard stream == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        roots = Self.roots(of: directory)
        let sink = Unmanaged.passRetained(ExtensionsWatcherSink(self)).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: sink, retain: nil,
            release: { info in
                if let info { Unmanaged<ExtensionsWatcherSink>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags =
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, extensionsWatcherCallback, &context, [directory.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, FSEventStreamCreateFlags(flags))
        else {
            Unmanaged<ExtensionsWatcherSink>.fromOpaque(sink).release()
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
        self.stream = stream
    }

    /// Stops watching. Nothing calls back after this, not even a reload that was waiting for its debounce.
    public func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Whether a changed path calls for a reload: the folder itself, or anything under it whose first component
    /// doesn't start with `.`.
    public nonisolated static func counts(path: String, in directory: URL) -> Bool {
        counts(path: path, roots: roots(of: directory))
    }

    /// Whether any path of a batch counts. A batch where none does is dropped.
    public nonisolated static func counts(paths: [String], in directory: URL) -> Bool {
        let roots = roots(of: directory)
        return paths.contains { counts(path: $0, roots: roots) }
    }

    private nonisolated static func counts(path: String, roots: [String]) -> Bool {
        for root in roots {
            if path == root || path == root + "/" { return true }
            guard path.hasPrefix(root + "/") else { continue }
            let first = path.dropFirst(root.count + 1).prefix { $0 != "/" }
            return !first.hasPrefix(".")
        }
        return false
    }

    /// The folder as given and as FSEvents reports it, with symbolic links resolved (`/var` is `/private/var`).
    private nonisolated static func roots(of directory: URL) -> [String] {
        var given = directory.standardizedFileURL.path
        while given.count > 1, given.hasSuffix("/") { given.removeLast() }
        guard let resolved = realpath(given, nil) else { return [given] }
        defer { free(resolved) }
        let real = String(cString: resolved)
        return real == given ? [given] : [given, real]
    }

    fileprivate func received(_ paths: [String]) {
        guard stream != nil, paths.contains(where: { Self.counts(path: $0, roots: roots) }) else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled, self.stream != nil else { return }
            self.pending = nil
            self.onChange()
        }
    }
}

/// What a watcher's stream context points to. It holds the watcher weakly, so the stream never keeps it alive.
@MainActor
private final class ExtensionsWatcherSink {
    weak var watcher: ExtensionsWatcher?
    init(_ watcher: ExtensionsWatcher) { self.watcher = watcher }
}

/// The stream's callback, on the main queue: with `kFSEventStreamCreateFlagUseCFTypes`, the paths are a CFArray.
private func extensionsWatcherCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int, _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    let sink = Unmanaged<ExtensionsWatcherSink>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated { sink.watcher?.received(Array(paths.prefix(count))) }
}
