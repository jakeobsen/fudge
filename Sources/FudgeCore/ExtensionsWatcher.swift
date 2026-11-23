import CoreServices
import Foundation

/// Watches the extensions folder, so the running app picks up an extension that `fudge build` installs, rebuilds
/// or that someone removes, with nothing to click.
///
/// One FSEvents stream with file-level events. A path counts when none of its components under the folder starts with
/// `.`: that leaves out `ExtensionBuilder`'s `.staging-*` and `.old-*` folders and its locks, inside a repository's
/// folder (FUD-183) as at the top, and `.DS_Store`. A batch that counts calls `onChange` `debounce` later, and further
/// counting batches in that time join it, so a build is one call. `onChange` runs on the main actor.
///
/// The stream is made, started, stopped and released on a serial queue of its own, which it also delivers on, never
/// on the main thread: each of those calls asks `fseventsd`, which can take seconds on a busy Mac, or not answer at
/// all, and the main thread must never wait for it (FUD-153). So `start` and `stop` return at once.
///
/// FSEvents reports only what happens once the stream exists, so a change made between `start` and the stream
/// starting would go unreported. The stamps of every folder an install can land in (`FolderStamps`) are read at
/// `start` and again once the stream has started, and when they differ that counts as a batch for the folder itself
/// (FUD-156).
@MainActor
public final class ExtensionsWatcher {
    /// How long FSEvents gathers events into one batch.
    public nonisolated static let latency: TimeInterval = 0.3
    /// How long after a counting batch `onChange` runs, unless another counting batch comes first.
    public nonisolated static let debounce: Duration = .milliseconds(300)

    public let directory: URL
    private let onChange: @MainActor () -> Void
    /// Where the stream lives. Tests pass a suspended queue to stand in for an `fseventsd` that doesn't answer.
    private let queue: DispatchQueue
    /// The folder's paths as FSEvents may report them, read when watching starts, once the folder exists.
    private var roots: [String] = []
    /// The current run's stream, from `start` to `stop`; only its queue touches what's inside it.
    private var stream: WatcherStream?
    /// Counts runs, so a batch delivered before `stop` (already on its way to the main queue) is dropped.
    private var run = 0
    private var pending: Task<Void, Never>?

    public convenience init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.init(
            directory: directory, queue: DispatchQueue(label: "io.github.jakeobsen.fudge.extensions-watcher"),
            onChange: onChange)
    }

    init(directory: URL, queue: DispatchQueue, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.queue = queue
        self.onChange = onChange
    }

    public var isRunning: Bool { stream != nil }

    /// Whether a counting batch is waiting for its debounce, for tests that wait for the watcher to go quiet.
    var hasPendingChange: Bool { pending != nil }

    /// Starts watching, creating the folder first when it's missing (as `ExtensionBuilder` would). The stream starts
    /// on the watcher's queue; one FSEvents refuses is reported on stderr, and then nothing is ever delivered. A change
    /// to the folder before the stream has started is one batch once it has.
    public func start() throws {
        guard stream == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        roots = Self.roots(of: directory)
        run += 1
        let stream = WatcherStream(queue: queue)
        self.stream = stream
        let sink = ExtensionsWatcherSink(self, run: run)
        let path = directory.path
        let stamps = FolderStamps(directory: directory)
        queue.async { stream.start(path: path, sink: sink, unchangedSince: stamps) }
    }

    /// Stops watching. Nothing calls back after this, not even a reload that was waiting for its debounce. The stream
    /// itself is stopped and released on its queue.
    public func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        self.stream = nil
        run += 1
        queue.async { stream.stop() }
    }

    /// Whether a changed path calls for a reload: the folder itself, or anything under it none of whose components
    /// starts with `.`.
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
            return !path.dropFirst(root.count + 1).split(separator: "/").contains { $0.hasPrefix(".") }
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

    fileprivate func received(_ paths: [String], run: Int) {
        guard stream != nil, run == self.run, paths.contains(where: { Self.counts(path: $0, roots: roots) }) else {
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled, self.stream != nil else { return }
            self.pending = nil
            self.onChange()
        }
    }
}

/// What changes when an entry of a folder is added, removed or renamed, as every install, rebuild and removal does: its
/// modification time, and its inode, in case the folder itself was replaced. Nil when the folder can't be read.
struct FolderStamp: Equatable, Sendable {
    let inode: UInt64
    let seconds: Int
    let nanoseconds: Int

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        inode = UInt64(info.st_ino)
        seconds = Int(info.st_mtimespec.tv_sec)
        nanoseconds = Int(info.st_mtimespec.tv_nsec)
    }
}

/// The stamps of every folder an install can land in (FUD-183): the extensions folder, `raycast/extensions`,
/// `fudgeapp/development`, and every folder the walk (`ExtensionWalk`) reads on its way to the installs, each owner's
/// and repository's, and a host's down to its repositories', by their paths relative to the extensions folder. An
/// install renamed into `raycast/extensions/` changes that folder's stamp, not the top one's. A folder that's missing
/// has none, so one added or gone differs too.
struct FolderStamps: Equatable, Sendable {
    let stamps: [String: FolderStamp]

    init(directory: URL) {
        var paths = Set(ExtensionWalk(directory).folders)
        for folder in [ExtensionRepositoryFolder.raycast, ExtensionRepositoryFolder.development] {
            var parts: [Substring] = []
            for part in folder.split(separator: "/") {
                parts.append(part)
                paths.insert(parts.joined(separator: "/"))
            }
        }
        var stamps: [String: FolderStamp] = [:]
        for path in paths {
            let url = path.isEmpty ? directory : directory.appendingPathComponent(path, isDirectory: true)
            stamps[path] = FolderStamp(path: url.path)
        }
        self.stamps = stamps
    }
}

/// What a stream's context points to: its watcher, held weakly so the stream never keeps it alive and read only on
/// the main queue, and the run the stream belongs to.
private final class ExtensionsWatcherSink: @unchecked Sendable {
    weak var watcher: ExtensionsWatcher?
    let run: Int

    @MainActor init(_ watcher: ExtensionsWatcher, run: Int) {
        self.watcher = watcher
        self.run = run
    }
}

/// One run's FSEvents stream. Every call on it happens on `queue`, which it delivers on too.
private final class WatcherStream: @unchecked Sendable {
    let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    init(queue: DispatchQueue) { self.queue = queue }

    /// Makes and starts the stream, then reads the folders' stamps again: any that differ from `stamps`, read at
    /// `start`, are a change FSEvents won't report, which goes to the watcher as a batch for the folder.
    func start(path: String, sink: ExtensionsWatcherSink, unchangedSince stamps: FolderStamps) {
        let info = Unmanaged.passRetained(sink).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info, retain: nil,
            release: { info in
                if let info { Unmanaged<ExtensionsWatcherSink>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags =
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, extensionsWatcherCallback, &context, [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), ExtensionsWatcher.latency,
                FSEventStreamCreateFlags(flags))
        else {
            Unmanaged<ExtensionsWatcherSink>.fromOpaque(info).release()
            FudgeLog.error("couldn't watch \(path): FSEvents refused the stream")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            FudgeLog.error("couldn't watch \(path): FSEvents didn't start")
            return
        }
        self.stream = stream
        if FolderStamps(directory: URL(fileURLWithPath: path, isDirectory: true)) != stamps {
            deliver([path], to: sink)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// The stream's callback, on the watcher's queue: with `kFSEventStreamCreateFlagUseCFTypes`, the paths are a CFArray.
/// The batch goes on to the main queue, in order.
private func extensionsWatcherCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int, _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    let sink = Unmanaged<ExtensionsWatcherSink>.fromOpaque(info).takeUnretainedValue()
    deliver(Array(paths.prefix(count)), to: sink)
}

/// Hands a batch to the watcher on the main queue, in order behind the ones before it.
private func deliver(_ batch: [String], to sink: ExtensionsWatcherSink) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { sink.watcher?.received(batch, run: sink.run) }
    }
}
