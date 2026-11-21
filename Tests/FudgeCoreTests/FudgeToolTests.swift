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

    /// The node on `PATH`, which `make test` runs the runtime's tests with.
    static let node: URL? = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    /// The scan fixtures the runtime's tests use.
    static let scanFixtures = Fixtures.repository.appendingPathComponent("runtime/test/fixtures/scan")

    /// Runs `fudge scan` from a checkout: the TypeScript scanner with node and esbuild's binary, and no
    /// `FUDGE_RAYCAST_TYPES`, so the scanner reads the vendored types. Returns the status, stdout and stderr.
    static func scan(_ arguments: [String], esbuild: String? = nil) throws -> (Int32, String, String) {
        let tool = try #require(fudge, "swift test builds the fudge tool")
        let node = try #require(node)
        let esbuild = try esbuild ?? #require(Fixtures.esbuild).path
        let process = Process()
        process.executableURL = tool
        process.arguments = ["scan"] + arguments
        process.environment = [
            "HOME": FileManager.default.temporaryDirectory.path, "PATH": "/usr/bin:/bin", "FUDGE_NODE": node.path,
            "FUDGE_ESBUILD": esbuild,
            "FUDGE_COMPAT_SCAN": Fixtures.repository.appendingPathComponent("runtime/scripts/compat/fudge-scan.ts")
                .path,
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

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
    // The build's scratch folder goes in `TMPDIR`: this test's folder, not the user's.
    let temporary = folder.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    try await Tool.expectTerminationEndsEverything(
        ["build", source.path, "--into", extensions.path],
        environment: [
            "HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": esbuild.path, "TMPDIR": temporary.path + "/",
        ],
        pids: pids)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("extensions/greeter").path))
    // esbuild runs once both folders exist, so a terminated build has both to delete.
    #expect(try FileManager.default.contentsOfDirectory(atPath: extensions.path) == [], "no .staging-* is left")
    #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == [], "no fudge-build-* is left")
}

@Suite(.enabled(if: Fixtures.esbuild != nil && Tool.node != nil, "needs esbuild and node: run `make test`"))
struct FudgeScanEndToEnd {
    @Test func scansTheFixturesThroughTheRealTool() throws {
        let (status, json, _) = try Tool.scan([Tool.scanFixtures.appendingPathComponent("gaps").path, "--json"])
        #expect(status == 0)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(report["extension"] as? String == "scan-gaps" && report["supported"] as? Bool == false)
        let gaps = try #require(report["gaps"] as? [[String: String]])
        #expect(
            gaps == [
                ["api": "AI.ask", "kind": "missing", "byDesign": "AI"],
                ["api": "captureMemorySnapshot", "kind": "missing"],
            ])

        let (supportedStatus, text, _) = try Tool.scan([Tool.scanFixtures.appendingPathComponent("supported").path])
        #expect(supportedStatus == 0 && text == "scan-supported: Fudge supports everything it uses.\n")
        let (gapsStatus, gapsText, _) = try Tool.scan([Tool.scanFixtures.appendingPathComponent("gaps").path])
        #expect(gapsStatus == 0)
        #expect(
            gapsText == """
                scan-gaps uses things Fudge doesn't have yet:
                  captureMemorySnapshot (not in Fudge)
                scan-gaps uses AI, which Fudge leaves out:
                  AI.ask

                """)
    }

    @Test func aSrcThatIsAFileIsAClearErrorWithExitCode2() throws {
        let folder = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "{}".write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "not a folder".write(to: folder.appendingPathComponent("src"), atomically: true, encoding: .utf8)
        let (status, out, err) = try Tool.scan([folder.path])
        #expect(status == 2 && out.isEmpty)
        #expect(err == "\(folder.path) isn't an extension: it needs a package.json file and a src folder\n")
    }

    @Test func anEsbuildThatCantRunFailsTheScanClearly() throws {
        for esbuild in ["/usr/bin/false", "/nonexistent/esbuild"] {
            let (status, out, err) = try Tool.scan(
                [Tool.scanFixtures.appendingPathComponent("supported").path, "--json"], esbuild: esbuild)
            #expect(status == 1 && out.isEmpty, "\(esbuild)")
            #expect(err.hasPrefix("can't run esbuild at \(esbuild): "), "\(err)")
            #expect(!err.contains("unreadable") && !err.contains("    at "), "no list of unreadable files, no stack")
        }
    }
}
