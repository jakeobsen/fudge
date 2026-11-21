import Foundation
import Testing

@testable import FudgeCore

// MARK: - The filter

private let root = URL(fileURLWithPath: "/tmp/fudge-watch/extensions", isDirectory: true)
private let staging = ".staging-x-8D1B2E0C-6F2A-4C1E-9E52-3F0D4B7A9C11"
private let old = ".old-x-0B7C1D3E-2F4A-4B5C-8D6E-7F8091A2B3C4"

@Test(arguments: ["\(staging)/dist/x.cjs", staging, old, "\(old)/package.json", ".DS_Store"])
func pathsUnderADotFolderOrFileDontCount(_ relative: String) {
    #expect(!ExtensionsWatcher.counts(path: root.path + "/" + relative, in: root))
}

@Test(arguments: ["x", "x/package.json", "x/dist/x.cjs", "x/.DS_Store"])
func pathsUnderAnExtensionFolderCount(_ relative: String) {
    #expect(ExtensionsWatcher.counts(path: root.path + "/" + relative, in: root))
}

@Test func theFolderItselfCountsAndPathsOutsideItDont() {
    #expect(ExtensionsWatcher.counts(path: root.path, in: root))
    #expect(ExtensionsWatcher.counts(path: root.path + "/", in: root))
    #expect(!ExtensionsWatcher.counts(path: "/tmp/fudge-watch", in: root))
    #expect(!ExtensionsWatcher.counts(path: "/tmp/fudge-watch/extensions-old/x", in: root), "a sibling folder")
    #expect(!ExtensionsWatcher.counts(path: "/", in: root))
}

@Test func aBatchCountsWhenAnyOfItsPathsDoes() {
    let ignored = [root.path + "/" + staging + "/package.json", root.path + "/" + old, root.path + "/.DS_Store"]
    #expect(!ExtensionsWatcher.counts(paths: ignored, in: root), "a batch of only non-counting paths is dropped")
    #expect(ExtensionsWatcher.counts(paths: ignored + [root.path + "/x"], in: root))
    #expect(!ExtensionsWatcher.counts(paths: [], in: root))
}

@Test func pathsAreMatchedAsFSEventsReportsThemWithSymbolicLinksResolved() throws {
    // The temporary folder is under /var, which is a link to /private/var, and FSEvents reports the latter.
    let extensions = try Fixtures.temporaryDirectory().appendingPathComponent("extensions")
    try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
    let real = try #require(
        realpath(extensions.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
    #expect(ExtensionsWatcher.counts(path: real + "/x", in: extensions))
    #expect(!ExtensionsWatcher.counts(path: real + "/" + staging, in: extensions))
    #expect(ExtensionsWatcher.counts(path: extensions.path + "/x", in: extensions))
}

// MARK: - Watching, on temporary folders only

/// A ceiling that only catches a hang: each wait ends as soon as what it waits for has happened, so a CI runner that
/// stalls for seconds can't fail it.
private let noHang: Duration = .seconds(30)

/// The reloads a watcher made, and waits for them. A wait ends as the reload comes, or at its deadline, which
/// Dispatch enforces (`OffThePool.after`, FUD-153): neither a held-up main actor nor a full pool can hold a wait past
/// it.
private final class Reloads: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [ContinuousClock.Instant] = []
    /// Waits for the next reload, by id: `next` waits for one after it's called, `first` for the first since `reset`.
    private var waiting: [UUID: CheckedContinuation<ContinuousClock.Instant?, Never>] = [:]

    /// A reload, from the watcher's `onChange`.
    func record() {
        let now = ContinuousClock.now
        let woken = lock.withLock {
            times.append(now)
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        for continuation in woken { continuation.resume(returning: now) }
    }

    var all: [ContinuousClock.Instant] { lock.withLock { times } }

    func reset() { lock.withLock { times = [] } }

    /// The first reload since `reset`, if one has come, or the next one within `limit`, or nil.
    func first(within limit: Duration) async -> ContinuousClock.Instant? {
        await wait(within: limit, unlessAlready: true)
    }

    /// The next reload after this call, within `limit`, or nil.
    func next(within limit: Duration) async -> ContinuousClock.Instant? {
        await wait(within: limit, unlessAlready: false)
    }

    private func wait(within limit: Duration, unlessAlready: Bool) async -> ContinuousClock.Instant? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let already: ContinuousClock.Instant? = lock.withLock {
                if unlessAlready, let first = times.first { return first }
                waiting[id] = continuation
                return nil
            }
            if let already {
                continuation.resume(returning: already)
                return
            }
            OffThePool.after(limit) { [self] in
                lock.withLock { waiting.removeValue(forKey: id) }?.resume(returning: nil)
            }
        }
    }
}

/// Waits until the watcher has gone quiet: a second with no reload and none waiting for its debounce, up to `noHang`.
/// FSEvents can report the folder's own creation, made just before the stream started. A batch the main queue hasn't
/// run yet is ahead of this function's turn there, so it shows as a pending change rather than being missed.
@MainActor
private func settle(_ watcher: ExtensionsWatcher, _ reloads: Reloads) async {
    let started = ContinuousClock.now
    while ContinuousClock.now - started < noHang {
        if await reloads.next(within: .seconds(1)) == nil, !watcher.hasPendingChange { return }
    }
}

/// Starts a watcher on a new temporary extensions folder (after `prepare`), lets it settle, makes `change`, and
/// returns how long after the change each reload came. It waits for a first reload, up to `noHang` when one is
/// expected, so the wait ends when it comes, or for `watching` when none is (a window a stall can only lengthen),
/// then 1 s more for any further one.
@MainActor
private func reloads(
    preparing prepare: (URL) async throws -> Void = { _ in }, watching: Duration = noHang,
    after change: (URL) async throws -> Void
) async throws -> [Duration] {
    let extensions = try Fixtures.temporaryDirectory().appendingPathComponent("extensions")
    try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
    try await prepare(extensions)
    let reloads = Reloads()
    let watcher = ExtensionsWatcher(directory: extensions) { reloads.record() }
    try watcher.start()
    defer { watcher.stop() }
    await settle(watcher, reloads)
    reloads.reset()
    try await change(extensions)
    let changed = ContinuousClock.now
    _ = await reloads.first(within: watching)
    try await Task.sleep(for: .seconds(1))
    return reloads.all.map { $0 - changed }
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: false, encoding: .utf8)
}

/// What `ExtensionBuilder` writes before it swaps a build into place.
private func stage(in extensions: URL) throws -> URL {
    let staging = extensions.appendingPathComponent(".staging-x-\(UUID().uuidString)")
    try write(#"{"name":"x"}"#, to: staging.appendingPathComponent("package.json"))
    try write("module.exports = {}", to: staging.appendingPathComponent("dist/x.cjs"))
    return staging
}

private func install(in extensions: URL) throws {
    try FileManager.default.moveItem(at: try stage(in: extensions), to: extensions.appendingPathComponent("x"))
}

/// Exactly one reload.
private func expectOnce(_ times: [Duration], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(times.count == 1, "reloads: \(times)", sourceLocation: sourceLocation)
}

@Suite(.timeLimit(.minutes(2)))
@MainActor
struct ExtensionsWatcherTests {
    @Test func creatingAFolderReloadsOnce() async throws {
        expectOnce(
            try await reloads { extensions in
                try FileManager.default.createDirectory(
                    at: extensions.appendingPathComponent("x"), withIntermediateDirectories: false)
            })
    }

    @Test func aFirstInstallReloadsOnce() async throws {
        expectOnce(try await reloads { extensions in try install(in: extensions) })
    }

    @Test func aRebuildOverAnExistingInstallReloadsOnce() async throws {
        expectOnce(
            try await reloads(preparing: install) { extensions in
                let staging = try stage(in: extensions)
                let installed = extensions.appendingPathComponent("x")
                let old = extensions.appendingPathComponent(".old-x-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: installed, to: old)
                try FileManager.default.moveItem(at: staging, to: installed)
                try FileManager.default.removeItem(at: old)
            })
    }

    @Test func aRebuildWhoseOldFolderIsDeletedInALaterBatchStillReloadsOnce() async throws {
        expectOnce(
            try await reloads(preparing: install) { extensions in
                let staging = try stage(in: extensions)
                let installed = extensions.appendingPathComponent("x")
                let old = extensions.appendingPathComponent(".old-x-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: installed, to: old)
                try FileManager.default.moveItem(at: staging, to: installed)
                // Past the latency and the debounce: the deletion is a batch of its own.
                try await Task.sleep(for: .milliseconds(900))
                try FileManager.default.removeItem(at: old)
            })
    }

    @Test func removingAFolderReloadsOnce() async throws {
        expectOnce(
            try await reloads(preparing: install) { extensions in
                try FileManager.default.removeItem(at: extensions.appendingPathComponent("x"))
            })
    }

    @Test func workInAStagingFolderAloneDoesntReload() async throws {
        let times = try await reloads(watching: .seconds(2)) { extensions in
            let staging = try stage(in: extensions)
            try FileManager.default.removeItem(at: staging)
            try write("", to: extensions.appendingPathComponent(".DS_Store"))
        }
        #expect(times.isEmpty, "reloads: \(times)")
    }

    @Test func nothingCallsBackAfterStop() async throws {
        let extensions = try Fixtures.temporaryDirectory().appendingPathComponent("extensions")
        let reloads = Reloads()
        let watcher = ExtensionsWatcher(directory: extensions) { reloads.record() }
        try watcher.start()
        #expect(watcher.isRunning)
        await settle(watcher, reloads)
        reloads.reset()
        try install(in: extensions)
        watcher.stop()
        #expect(!watcher.isRunning)
        // A window for a callback that shouldn't come, longer than the latency and the debounce together. FSEvents
        // runs in real time, so there's no clock to inject; a stall can only lengthen the window, never fail it.
        #expect(await reloads.next(within: .seconds(1.5)) == nil)
        #expect(reloads.all.isEmpty)
    }

    @Test func startingCreatesAMissingFolderAndWatchesIt() async throws {
        // Under /var, a link to /private/var: the folder's real path is only known once it exists.
        let extensions = try Fixtures.temporaryDirectory().appendingPathComponent("support/extensions")
        let reloads = Reloads()
        let watcher = ExtensionsWatcher(directory: extensions) { reloads.record() }
        try watcher.start()
        defer { watcher.stop() }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: extensions.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        await settle(watcher, reloads)
        reloads.reset()
        try install(in: extensions)
        let installed = ContinuousClock.now
        _ = await reloads.first(within: noHang)
        try await Task.sleep(for: .seconds(1))
        expectOnce(reloads.all.map { $0 - installed })
    }

    /// FUD-153: CI's tests once stopped for 16 minutes, the main actor held up. The watcher asks `fseventsd` only on
    /// its own queue, so one that never answers (a suspended queue here) holds up nothing: `start` and `stop` return
    /// at once, nothing is reported, and the test's wait ends at its deadline.
    @Test func aStreamThatNeverStartsHoldsUpNothingAndItsWaitEndsAtItsDeadline() async throws {
        let extensions = try Fixtures.temporaryDirectory().appendingPathComponent("extensions")
        let fseventsd = DispatchQueue(label: "a stuck fseventsd")
        fseventsd.suspend()
        defer { fseventsd.resume() }
        let reloads = Reloads()
        let watcher = ExtensionsWatcher(directory: extensions, queue: fseventsd) { reloads.record() }
        let began = ContinuousClock.now
        try watcher.start()
        #expect(watcher.isRunning)
        try install(in: extensions)
        #expect(await reloads.first(within: .seconds(1)) == nil, "nothing reports")
        watcher.stop()
        #expect(!watcher.isRunning)
        #expect(ContinuousClock.now - began < noHang, "start, the wait and stop all ended")
    }

    /// A wait's deadline is enforced off the main actor: here the main actor is held until the wait has ended (or 30 s
    /// have passed), and a deadline that needed the main actor would never come.
    @Test func aWaitEndsAtItsDeadlineWhileTheMainActorIsHeldUp() {
        let reloads = Reloads()
        let ended = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await reloads.first(within: .milliseconds(100))
            ended.signal()
        }
        #expect(ended.wait(timeout: .now() + 30) == .success)
    }
}

@Suite(
    .enabled(if: Fixtures.esbuild != nil, "needs esbuild: run `make test`, which installs it"), .timeLimit(.minutes(2)))
@MainActor
struct ExtensionsWatcherBuildTests {
    let builder = ExtensionBuilder(esbuild: Fixtures.esbuild ?? URL(fileURLWithPath: "/missing"))

    /// Builds the greeter on a thread of its own, so its seconds of esbuild hold up neither the main actor nor the
    /// shared pool (a `Task.detached` would take a pool thread).
    private func build(into extensions: URL) async throws {
        let builder = builder
        _ = try await OffThePool.run { try builder.build(source: Fixtures.greeter, into: extensions) }
    }

    @Test func installingWithTheBuilderReloadsOnce() async throws {
        expectOnce(try await reloads { extensions in try await build(into: extensions) })
    }

    @Test func rebuildingWithTheBuilderReloadsOnce() async throws {
        // Both builds off the main actor: the first one used to run on it, holding up every main-actor test for its
        // seconds of esbuild (FUD-153).
        expectOnce(
            try await reloads(preparing: { extensions in try await build(into: extensions) }) { extensions in
                try await build(into: extensions)
            })
    }
}
