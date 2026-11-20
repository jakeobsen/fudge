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

@MainActor
private final class Reloads {
    var times: [ContinuousClock.Instant] = []
}

/// Starts a watcher on a new temporary extensions folder (after `prepare`), lets it settle, makes `change`, and
/// returns how long after the change each reload came. It waits 2 s for a first reload, then 1 s more for any
/// further one. Settling takes longer than the latency and the debounce together, because FSEvents can report the
/// folder's own creation, made just before the stream started.
@MainActor
private func reloads(
    preparing prepare: (URL) throws -> Void = { _ in }, after change: (URL) async throws -> Void
) async throws -> [Duration] {
    let extensions = try Fixtures.temporaryDirectory().appendingPathComponent("extensions")
    try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
    try prepare(extensions)
    let reloads = Reloads()
    let watcher = ExtensionsWatcher(directory: extensions) { reloads.times.append(.now) }
    try watcher.start()
    defer { watcher.stop() }
    try await Task.sleep(for: .seconds(1))
    reloads.times = []
    try await change(extensions)
    let changed = ContinuousClock.now
    while reloads.times.isEmpty, ContinuousClock.now - changed < .seconds(2) {
        try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .seconds(1))
    return reloads.times.map { $0 - changed }
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

/// Exactly one reload, within 2 s.
private func expectOnce(_ times: [Duration], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(times.count == 1, "reloads: \(times)", sourceLocation: sourceLocation)
    #expect(times.allSatisfy { $0 < .seconds(2) }, "reloads: \(times)", sourceLocation: sourceLocation)
}

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
        let times = try await reloads { extensions in
            let staging = try stage(in: extensions)
            try FileManager.default.removeItem(at: staging)
            try write("", to: extensions.appendingPathComponent(".DS_Store"))
        }
        #expect(times.isEmpty, "reloads: \(times)")
    }

    @Test func nothingCallsBackAfterStop() async throws {
        let extensions = try Fixtures.temporaryDirectory().appendingPathComponent("extensions")
        let reloads = Reloads()
        let watcher = ExtensionsWatcher(directory: extensions) { reloads.times.append(.now) }
        try watcher.start()
        #expect(watcher.isRunning)
        try await Task.sleep(for: .seconds(1))
        reloads.times = []
        try install(in: extensions)
        watcher.stop()
        #expect(!watcher.isRunning)
        try await Task.sleep(for: .seconds(1.5))
        #expect(reloads.times.isEmpty)
    }

    @Test func startingCreatesAMissingFolderAndWatchesIt() async throws {
        // Under /var, a link to /private/var: the folder's real path is only known once it exists.
        let extensions = try Fixtures.temporaryDirectory().appendingPathComponent("support/extensions")
        let reloads = Reloads()
        let watcher = ExtensionsWatcher(directory: extensions) { reloads.times.append(.now) }
        try watcher.start()
        defer { watcher.stop() }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: extensions.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        try await Task.sleep(for: .seconds(1))
        reloads.times = []
        try install(in: extensions)
        let installed = ContinuousClock.now
        while reloads.times.isEmpty, ContinuousClock.now - installed < .seconds(2) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .seconds(1))
        expectOnce(reloads.times.map { $0 - installed })
    }
}

@Suite(.enabled(if: Fixtures.esbuild != nil, "needs esbuild: run `make test`, which installs it"))
@MainActor
struct ExtensionsWatcherBuildTests {
    let builder = ExtensionBuilder(esbuild: Fixtures.esbuild ?? URL(fileURLWithPath: "/missing"))

    /// Builds the greeter off the main actor, so the build doesn't hold up other tests' callbacks.
    private func build(into extensions: URL) async throws {
        let builder = builder
        _ = try await Task.detached { try builder.build(source: Fixtures.greeter, into: extensions) }.value
    }

    @Test func installingWithTheBuilderReloadsOnce() async throws {
        expectOnce(try await reloads { extensions in try await build(into: extensions) })
    }

    @Test func rebuildingWithTheBuilderReloadsOnce() async throws {
        let builder = builder
        expectOnce(
            try await reloads(preparing: { extensions in
                _ = try builder.build(source: Fixtures.greeter, into: extensions)
            }) { extensions in
                try await build(into: extensions)
            })
    }
}
