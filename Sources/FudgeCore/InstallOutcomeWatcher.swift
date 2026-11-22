import CoreServices
import Foundation

/// Watches the Extension Store's `installing/` folder for builds' outcomes (SPEC-156 C.2): an FSEvents stream with
/// file-level events, counting only names `<pid>.ended.json` directly in the folder.
///
/// Everything touching the stream or the folder runs on a serial queue of its own, never the main thread, since each
/// FSEvents call asks `fseventsd`, which can take seconds on a busy Mac (FUD-153), and the folder's reads go there too:
/// the launch scan, each batch's outcomes and the read when a store session ends (`readAll`).
///
/// At `start` the stream starts first, then the folder is read once (N9): the outcomes already there go to `found`, and
/// only then any the stream reports go to `ended`, in that order on the main queue, so an outcome written in between,
/// which both see, is counted as found first.
public final class InstallOutcomeWatcher: @unchecked Sendable {
    /// How long FSEvents gathers events into one batch.
    public static let latency: TimeInterval = 0.2

    public let folder: URL
    private let queue: DispatchQueue
    private let found: @MainActor ([InstallBuild]) -> Void
    private let ended: @MainActor ([InstallEnd]) -> Void
    /// Only `queue` touches these.
    private var stream: FSEventStreamRef?
    private var roots: [String] = []

    /// `found` gets the builds whose outcomes were there at the start, `ended` each batch's outcomes that have their
    /// records; both on the main actor.
    public init(
        folder: URL, found: @escaping @MainActor ([InstallBuild]) -> Void,
        ended: @escaping @MainActor ([InstallEnd]) -> Void
    ) {
        self.folder = folder
        self.found = found
        self.ended = ended
        queue = DispatchQueue(label: "io.github.jakeobsen.fudge.install-outcomes")
    }

    /// Starts watching on the watcher's queue, making the folder when it's missing, so the stream has a folder to watch.
    /// A stream FSEvents refuses is logged, and the scan still runs.
    public func start() {
        queue.async { [self] in
            guard stream == nil else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                FudgeLog.error("couldn't make \(folder.path): \(error.localizedDescription)")
            }
            roots = Self.roots(of: folder)
            startStream()
            let builds = InstallOutcomeFolder.ends(in: folder).compactMap(\.build)
            let found = self.found
            DispatchQueue.main.async { MainActor.assumeIsolated { found(builds) } }
        }
    }

    /// Stops watching; nothing is delivered after the batches already on their way.
    public func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Reads every outcome that has its record, on the watcher's queue, behind the batches before it, and hands them
    /// to `then` on the main actor: what a store session that just ended left.
    public func readAll(then: @escaping @MainActor ([InstallEnd]) -> Void) {
        queue.async { [folder] in
            let ends = InstallOutcomeFolder.ends(in: folder)
            DispatchQueue.main.async { MainActor.assumeIsolated { then(ends) } }
        }
    }

    /// The outcome names directly in the folder among a batch's paths.
    static func outcomeNames(in paths: [String], roots: [String]) -> Set<String> {
        var names = Set<String>()
        for path in paths {
            for root in roots where path.hasPrefix(root + "/") {
                let name = String(path.dropFirst(root.count + 1))
                if !name.contains("/"), InstallOutcomeFolder.isOutcome(name) { names.insert(name) }
            }
        }
        return names
    }

    /// The folder as given and as FSEvents reports it, with symbolic links resolved (`/var` is `/private/var`).
    static func roots(of folder: URL) -> [String] {
        var given = folder.standardizedFileURL.path
        while given.count > 1, given.hasSuffix("/") { given.removeLast() }
        guard let resolved = realpath(given, nil) else { return [given] }
        defer { free(resolved) }
        let real = String(cString: resolved)
        return real == given ? [given] : [given, real]
    }

    /// On `queue`.
    private func startStream() {
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info, retain: nil,
            release: { info in
                if let info { Unmanaged<InstallOutcomeWatcher>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, installOutcomeCallback, &context, [folder.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, FSEventStreamCreateFlags(flags))
        else {
            Unmanaged<InstallOutcomeWatcher>.fromOpaque(info).release()
            FudgeLog.error("couldn't watch \(folder.path): FSEvents refused the stream")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            FudgeLog.error("couldn't watch \(folder.path): FSEvents didn't start")
            return
        }
        self.stream = stream
    }

    /// On `queue`: a batch's outcomes that have their records go to `ended`.
    fileprivate func received(_ paths: [String]) {
        guard stream != nil else { return }
        let names = Self.outcomeNames(in: paths, roots: roots)
        guard !names.isEmpty else { return }
        let ends = InstallOutcomeFolder.ends(in: folder, only: names)
        guard !ends.isEmpty else { return }
        let ended = self.ended
        DispatchQueue.main.async { MainActor.assumeIsolated { ended(ends) } }
    }
}

/// The stream's callback, on the watcher's queue: with `kFSEventStreamCreateFlagUseCFTypes`, the paths are a CFArray.
private func installOutcomeCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int, _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    Unmanaged<InstallOutcomeWatcher>.fromOpaque(info).takeUnretainedValue().received(Array(paths.prefix(count)))
}
