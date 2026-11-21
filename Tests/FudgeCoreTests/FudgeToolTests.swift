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

    /// A ceiling that only catches a hang: each wait ends as soon as what it waits for has happened, so a CI runner
    /// that stalls for seconds can't fail it.
    static let noHang: Duration = .seconds(30)

    /// The pinned Node.js `make test` hands the tests.
    static let node = Fixtures.node

    /// The tool laid out as in Fudge.app, `<folder>/Contents/Helpers/fudge` (a hard link, else a copy), with `node`
    /// beside it, as a link, when given. The tool finds Node.js only there. The caller removes `folder`.
    static func bundled(in folder: URL, node: URL?) throws -> URL {
        let tool = try #require(fudge, "swift test builds the fudge tool")
        let files = FileManager.default
        let helpers = folder.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try files.createDirectory(at: helpers, withIntermediateDirectories: true)
        let bundled = helpers.appendingPathComponent("fudge")
        do { try files.linkItem(at: tool, to: bundled) } catch { try files.copyItem(at: tool, to: bundled) }
        if let node {
            try files.createSymbolicLink(at: helpers.appendingPathComponent("node"), withDestinationURL: node)
        }
        return bundled
    }

    /// Runs `tool` with `arguments` and `environment`, and returns its status, stdout and stderr.
    static func run(_ tool: URL, _ arguments: [String], environment: [String: String]) throws -> (Int32, String, String)
    {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment
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

    /// The scan fixtures the runtime's tests use.
    static let scanFixtures = Fixtures.repository.appendingPathComponent("runtime/test/fixtures/scan")

    /// Runs `fudge scan` from a checkout: the TypeScript scanner with node and esbuild's binary, and no
    /// `FUDGE_RAYCAST_TYPES`, so the scanner reads the vendored types. Returns the status, stdout and stderr.
    static func scan(_ arguments: [String], esbuild: String? = nil) throws -> (Int32, String, String) {
        let folder = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let node: URL = try #require(Tool.node, "make test hands the tests Fudge's Node.js")
        let tool = try bundled(in: folder, node: node)
        let esbuild = try esbuild ?? #require(Fixtures.esbuild).path
        return try run(
            tool, ["scan"] + arguments,
            environment: [
                "HOME": FileManager.default.temporaryDirectory.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": esbuild,
                "FUDGE_COMPAT_SCAN": Fixtures.repository.appendingPathComponent("runtime/scripts/compat/fudge-scan.ts")
                    .path,
            ])
    }

    /// Runs `fudge` with `arguments` until the stand-in has started, then sends it SIGTERM: the tool must exit
    /// with 143 and take the stand-in and its child with it.
    static func expectTerminationEndsEverything(
        _ arguments: [String], environment: [String: String], pids: URL, tool: URL? = nil
    ) async throws {
        let tool = try tool ?? #require(fudge, "swift test builds the fudge tool")
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var started: [pid_t] = []
        let launched = ContinuousClock.now
        while started.count < 2, ContinuousClock.now - launched < noHang {
            started = ((try? String(contentsOf: pids, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            if started.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(started.count == 2, "the stand-in started")

        let clock = ContinuousClock.now
        process.terminate()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 128 + SIGTERM)
        while !started.allSatisfy(isGone), ContinuousClock.now - clock < noHang {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(started.allSatisfy(isGone), "the stand-in and its child are gone")
        for pid in started where !isGone(pid) { kill(pid, SIGKILL) }
    }
}

@Test func terminatingFudgeScanEndsNodeAndEverythingItStarted() async throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let node = folder.appendingPathComponent("node")
    let pids = folder.appendingPathComponent("pids")
    try Tool.neverExiting(at: node, pids: pids)
    // The stand-in is the Node.js beside the tool, as Fudge.app has it.
    let tool = try Tool.bundled(in: folder.appendingPathComponent("app"), node: node)
    try await Tool.expectTerminationEndsEverything(
        ["scan", Fixtures.repository.appendingPathComponent("runtime/test/fixtures/scan/supported").path],
        environment: [
            "HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": "/usr/bin/true",
            "FUDGE_COMPAT_SCAN": "/dev/null",
        ],
        pids: pids, tool: tool)
}

@Test func theToolRunsOnlyTheNodeBesideIt() throws {
    // A Node.js on PATH and in FUDGE_NODE, which the tool used to take, is never run (SPEC-115).
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let elsewhere = folder.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let impostor = elsewhere.appendingPathComponent("node")
    let ran = folder.appendingPathComponent("ran")
    try "#!/bin/sh\ntouch '\(ran.path)'\n".write(to: impostor, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: impostor.path)
    let tool = try Tool.bundled(in: folder.appendingPathComponent("app"), node: nil)
    let (status, out, err) = try Tool.run(
        tool, ["scan", Fixtures.repository.appendingPathComponent("runtime/test/fixtures/scan/supported").path],
        environment: [
            "HOME": folder.path, "PATH": "\(elsewhere.path):/usr/bin:/bin", "FUDGE_NODE": impostor.path,
            "FUDGE_ESBUILD": "/usr/bin/true", "FUDGE_COMPAT_SCAN": "/dev/null",
        ])
    #expect(status == 1 && out.isEmpty)
    #expect(err == "fudge: can't find Fudge's own Node.js beside this fudge tool: use the fudge inside Fudge.app\n")
    #expect(!FileManager.default.fileExists(atPath: ran.path), "the other Node.js never ran")
}

@Test(.enabled(if: Fixtures.esbuild != nil, "needs esbuild: run `make test`"))
func buildInstallsDependenciesWithTheBundledNpm() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    // A stand-in for Node.js that writes down how it was run, and installs nothing.
    let node = folder.appendingPathComponent("node")
    let ran = folder.appendingPathComponent("ran")
    try "#!/bin/sh\nprintf '%s\\n' \"$PATH\" \"$@\" > '\(ran.path)'\n".write(
        to: node, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
    let tool = try Tool.bundled(in: folder.appendingPathComponent("app"), node: node)

    let source = try Fixtures.greeterCopy()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let manifest = source.appendingPathComponent("package.json")
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    object["dependencies"] = ["left-pad": "1.3.0"]
    try JSONSerialization.data(withJSONObject: object).write(to: manifest)
    let extensions = folder.appendingPathComponent("extensions")
    let temporary = folder.appendingPathComponent("tmp")
    for made in [extensions, temporary] {
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    }

    let (status, _, err) = try Tool.run(
        tool, ["build", source.path, "--into", extensions.path],
        environment: [
            "HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": try #require(Fixtures.esbuild).path,
            "TMPDIR": temporary.path + "/",
        ])
    #expect(status == 0, "\(err)")
    let lines = try String(contentsOf: ran, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.first?.split(separator: ":").first?.hasSuffix("/app/Contents/Helpers") == true, "\(lines)")
    #expect(lines.first?.hasSuffix(":/usr/bin:/bin") == true, "then the PATH it had")
    #expect(lines.dropFirst().first?.hasSuffix("/app/Contents/Resources/node/npm/bin/npm-cli.js") == true)
    #expect(
        Array(lines.dropFirst(2)) == ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error"])
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
                scan-gaps uses Raycast AI, which Fudge doesn't support:
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
