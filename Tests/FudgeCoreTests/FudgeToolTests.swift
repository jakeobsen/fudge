import Darwin
import Foundation
import Testing

@testable import FudgeCore

/// The real `fudge` tool, run end to end.
enum Tool {
    /// The `fudge` binary `swift test` builds beside this test bundle, else in `.build/debug`.
    static let fudge: URL? = {
        let besideTests = Bundle.allBundles.map {
            $0.bundleURL.deletingLastPathComponent().appendingPathComponent("fudge")
        }
        return (besideTests + [Fixtures.repository.appendingPathComponent(".build/debug/fudge")])
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// A script that stands in for a program the tool runs: it never exits, and neither does the child it starts,
    /// as with npm and node. It writes both pids to `pids`.
    static func neverExiting(at file: URL, pids: URL) throws {
        try "#!/bin/sh\n/bin/sleep 600 &\necho $$ $! > '\(pids.path)'\nwait\n".write(
            to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    static func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    /// Runs `fudge` with `arguments` until the stand-in has started, then sends it SIGTERM: the tool must exit
    /// with 143 and take the stand-in and its child with it, all within two seconds.
    static func expectTerminationEndsEverything(
        _ arguments: [String], environment: [String: String], pids: URL
    ) async throws {
        let tool = try #require(fudge, "swift test builds the fudge tool")
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var started: [pid_t] = []
        for _ in 0..<250 where started.count < 2 {
            started = ((try? String(contentsOf: pids, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            if started.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(started.count == 2, "the stand-in started")

        let clock = ContinuousClock.now
        process.terminate()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 128 + SIGTERM)
        while !started.allSatisfy(isGone), ContinuousClock.now - clock < .seconds(2) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(started.allSatisfy(isGone), "the stand-in and its child are gone")
        #expect(ContinuousClock.now - clock < .seconds(2))
        for pid in started where !isGone(pid) { kill(pid, SIGKILL) }
    }
}

@Test func terminatingFudgeScanEndsNodeAndEverythingItStarted() async throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let node = folder.appendingPathComponent("node")
    let pids = folder.appendingPathComponent("pids")
    try Tool.neverExiting(at: node, pids: pids)
    try await Tool.expectTerminationEndsEverything(
        ["scan", Fixtures.repository.appendingPathComponent("runtime/test/fixtures/scan/supported").path],
        environment: [
            "HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_NODE": node.path, "FUDGE_ESBUILD": "/usr/bin/true",
            "FUDGE_COMPAT_SCAN": "/dev/null",
        ],
        pids: pids)
}

@Test func terminatingFudgeBuildEndsEsbuildAndEverythingItStarted() async throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let esbuild = folder.appendingPathComponent("esbuild")
    let pids = folder.appendingPathComponent("pids")
    try Tool.neverExiting(at: esbuild, pids: pids)
    let source = try Fixtures.greeterCopy()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let extensions = folder.appendingPathComponent("extensions")
    try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
    try await Tool.expectTerminationEndsEverything(
        ["build", source.path, "--into", extensions.path],
        environment: ["HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": esbuild.path],
        pids: pids)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("extensions/greeter").path))
}
