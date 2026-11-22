import Darwin
import Foundation
import Testing

@testable import FudgeCore

/// A shared fixture under `runtime/test/fixtures`, which the store's tests read too.
private func sharedCases(_ name: String) throws -> (valid: [[String: Any]], invalid: [[String: Any]]) {
    let file = Fixtures.repository.appendingPathComponent("runtime/test/fixtures/\(name)")
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let valid = try #require(object["valid"] as? [[String: Any]])
    let invalid = try #require(object["invalid"] as? [[String: Any]])
    #expect(!valid.isEmpty && !invalid.isEmpty)
    return (valid, invalid)
}

@Test func readsOutcomesAsTheSharedFixtureSays() throws {
    let cases = try sharedCases("build-outcome.json")
    for item in cases.valid {
        let file = try #require(item["file"] as? String)
        let text = try #require(item["text"] as? String)
        let outcome = try #require(BuildOutcomeFile.parse(fileName: file, data: Data(text.utf8)), "\(file)")
        #expect(outcome.status == Int32(try #require(item["status"] as? Int)), "\(file)")
        #expect(BuildOutcomeFile.time(outcome.endedAt) == item["endedAt"] as? String, "\(file)")
        #expect(BuildOutcomeFile.fileName(pid: outcome.pid) == file)
    }
    for item in cases.invalid {
        let text = try #require(item["text"] as? String)
        let file = try #require(item["file"] as? String)
        #expect(
            BuildOutcomeFile.parse(fileName: file, data: Data(text.utf8)) == nil,
            "\(item["why"] ?? "")")
    }
}

@Test func readsRecordsAsTheSharedFixtureSays() throws {
    let cases = try sharedCases("build-records.json")
    for item in cases.valid {
        let file = try #require(item["file"] as? String)
        let text = try #require(item["text"] as? String)
        let record = try #require(StoreBuildRecord.parse(fileName: file, data: Data(text.utf8)), "\(file)")
        #expect(record.pid == 4242)
        #expect(record.name == item["name"] as? String)
        #expect(record.dir == item["dir"] as? String)
        #expect(record.title == item["title"] as? String)
        #expect(record.updating == item["updating"] as? Bool)
        #expect(record.startedAt == item["startedAt"] as? String)
        #expect(record.build == InstallBuild(pid: 4242, startedAt: record.startedAt))
    }
    for item in cases.invalid {
        let text = try #require(item["text"] as? String)
        let file = try #require(item["file"] as? String)
        #expect(
            StoreBuildRecord.parse(fileName: file, data: Data(text.utf8)) == nil,
            "\(item["why"] ?? "")")
    }
}

@Test func anOutcomeIsWrittenAtomicallyAsTheStoreReadsIt() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let endedAt = try #require(StoreBuildRecord.time("2026-11-18T11:06:40.123Z"))
    let outcome = BuildOutcomeFile(pid: 4242, status: 143, endedAt: endedAt)
    try outcome.write(in: folder)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["4242.ended.json"], "no temporary file")
    let data = try Data(contentsOf: folder.appendingPathComponent("4242.ended.json"))
    #expect(
        String(decoding: data, as: UTF8.self)
            == "{ \"pid\": 4242, \"status\": 143, \"endedAt\": \"2026-11-18T11:06:40.123Z\" }\n")
    #expect(BuildOutcomeFile.parse(fileName: "4242.ended.json", data: data) == outcome)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: folder.appendingPathComponent("4242.ended.json").path)
    let mode = try #require(attributes[.posixPermissions] as? Int)
    #expect(mode == 0o600)
    // A second write replaces it, as `rename` does.
    try BuildOutcomeFile(pid: 4242, status: 0, endedAt: endedAt).write(in: folder)
    #expect(
        BuildOutcomeFile.parse(
            fileName: "4242.ended.json", data: try Data(contentsOf: folder.appendingPathComponent("4242.ended.json")))?
            .status == 0)
}

@Test func theRecorderWritesOnceAndOnlyWithAFolder() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reported = Lines()
    let recorder = BuildOutcomeRecorder(pid: 77, now: { Date(timeIntervalSince1970: 0) }, report: { reported.add($0) })
    recorder.ended(status: 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [], "no folder, nothing written")
    recorder.record(into: folder)
    recorder.ended(status: 143)
    recorder.ended(status: 0)
    let data = try Data(contentsOf: folder.appendingPathComponent("77.ended.json"))
    #expect(BuildOutcomeFile.parse(fileName: "77.ended.json", data: data)?.status == 143, "the first exit wins")
    #expect(reported.all == [])

    let locked = folder.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
    let refused = BuildOutcomeRecorder(pid: 78, report: { reported.add($0) })
    refused.record(into: locked)
    refused.ended(status: 1)
    #expect(reported.all == ["fudge: couldn't save the build's outcome in \(locked.path): Permission denied"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path) == [])
}

@Test func buildTakesAnOutcomeFolderAsItTakesInto() throws {
    let exists: (String) -> Bool = { $0 == "/support/installing" || $0 == "/extensions" }
    let parsed = try BuildArguments.parse(
        ["/src", "--into", "/extensions", "--outcome", "/support/installing"], isDirectory: exists)
    #expect(parsed.outcome == URL(fileURLWithPath: "/support/installing", isDirectory: true))
    #expect(parsed.destination == URL(fileURLWithPath: "/extensions", isDirectory: true))
    #expect(try BuildArguments.parse(["/src"], isDirectory: exists).outcome == nil)
    #expect(throws: BuildArguments.Invalid(description: "--outcome needs an absolute path: installing")) {
        try BuildArguments.parse(["/src", "--outcome", "installing"], isDirectory: exists)
    }
    #expect(throws: BuildArguments.Invalid(description: "--outcome: no such folder: /nowhere")) {
        try BuildArguments.parse(["/src", "--outcome", "/nowhere"], isDirectory: exists)
    }
    #expect(throws: BuildArguments.Invalid(description: BuildArguments.usage)) {
        try BuildArguments.parse(["/src", "--outcome"], isDirectory: exists)
    }
}

/// Lines a test collects from another thread.
private final class Lines: @unchecked Sendable {
    // @unchecked: `lines` is behind `lock`.
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// The real tool, ended in each way it can end, with `--outcome`.
enum OutcomeRun {
    /// Runs `tool` with its stdout and stderr in files this test opened, as the Extension Store runs it, and returns its
    /// pid, status and both files' text.
    static func run(_ tool: URL, _ arguments: [String], environment: [String: String], in folder: URL) async throws -> (
        pid: pid_t, status: Int32, out: String, err: String
    ) {
        let out = folder.appendingPathComponent("build.out")
        let err = folder.appendingPathComponent("build.err")
        for file in [out, err] { #expect(FileManager.default.createFile(atPath: file.path, contents: nil)) }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let exited = try await OffThePool.run(within: Tool.noHang) {
            process.waitUntilExit()
            return true
        }
        try #require(exited == true, "the tool exited")
        return (
            process.processIdentifier, process.terminationStatus, try String(contentsOf: out, encoding: .utf8),
            try String(contentsOf: err, encoding: .utf8)
        )
    }

    /// The one outcome in `folder`, which must be `pid`'s.
    static func outcome(in folder: URL, pid: pid_t) throws -> BuildOutcomeFile {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == ["\(pid).ended.json"])
        let data = try Data(contentsOf: folder.appendingPathComponent("\(pid).ended.json"))
        return try #require(BuildOutcomeFile.parse(fileName: "\(pid).ended.json", data: data))
    }

    static func folders() throws -> (root: URL, extensions: URL, temporary: URL, outcome: URL) {
        let root = try Fixtures.temporaryDirectory()
        let made = ["extensions", "tmp", "installing"].map { root.appendingPathComponent($0, isDirectory: true) }
        for folder in made { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return (root, made[0], made[1], made[2])
    }
}

@Test func aBuildThatFailsWritesStatus1AndItsOutputLandsInTheFiles() async throws {
    let (root, extensions, temporary, installing) = try OutcomeRun.folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try Tool.bundled(in: root.appendingPathComponent("app"), node: nil)
    let started = Date()
    let ran = try await OutcomeRun.run(
        tool, ["build", Fixtures.greeter.path, "--into", extensions.path, "--outcome", installing.path],
        environment: [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": "/nonexistent/esbuild",
            "TMPDIR": temporary.path + "/",
        ], in: root)
    #expect(ran.status == 1)
    #expect(
        ran.err == "fudge: compiling needs Fudge's own Node.js and its bundling script, which aren't beside this fudge "
            + "tool; use the fudge inside Fudge.app\n", "stderr went to the file the test opened")
    let outcome = try OutcomeRun.outcome(in: installing, pid: ran.pid)
    #expect(outcome.status == 1 && outcome.pid == ran.pid)
    #expect(outcome.endedAt >= started.addingTimeInterval(-1) && outcome.endedAt <= Date().addingTimeInterval(1))
}

@Test func aBuildTheLockRefusesWritesStatus75() async throws {
    let (root, extensions, temporary, installing) = try OutcomeRun.folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try Tool.bundled(in: root.appendingPathComponent("app"), node: Tool.node)
    let holder = try await LockHolder.start(locking: ExtensionBuilder.lockFile(of: "greeter", in: extensions))
    defer { holder.stop() }
    let ran = try await OutcomeRun.run(
        tool, ["build", Fixtures.greeter.path, "--into", extensions.path, "--outcome", installing.path],
        environment: [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": "/nonexistent/esbuild",
            "TMPDIR": temporary.path + "/",
        ], in: root)
    #expect(ran.status == 75)
    #expect(try OutcomeRun.outcome(in: installing, pid: ran.pid).status == 75)
}

/// A folder the build can't write to: its stderr gets exactly one more line, and its status stays what it was.
@Test func anOutcomeThatCantBeWrittenAddsOneLineAndKeepsTheStatus() async throws {
    let (root, extensions, temporary, installing) = try OutcomeRun.folders()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installing.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installing.path)
    let tool = try Tool.bundled(in: root.appendingPathComponent("app"), node: nil)
    let ran = try await OutcomeRun.run(
        tool, ["build", Fixtures.greeter.path, "--into", extensions.path, "--outcome", installing.path],
        environment: [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": "/nonexistent/esbuild",
            "TMPDIR": temporary.path + "/",
        ], in: root)
    #expect(ran.status == 1)
    #expect(
        ran.err == "fudge: compiling needs Fudge's own Node.js and its bundling script, which aren't beside this fudge "
            + "tool; use the fudge inside Fudge.app\n"
            + "fudge: couldn't save the build's outcome in \(installing.path): Permission denied\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: installing.path) == [])
}

@Test(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
func aBuildThatInstallsWritesStatus0() async throws {
    let (root, extensions, temporary, installing) = try OutcomeRun.folders()
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = try Tool.bundled(in: root.appendingPathComponent("app"), node: Tool.node)
    let source = try Fixtures.greeterCopy()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let ran = try await OutcomeRun.run(
        tool, ["build", source.path, "--into", extensions.path, "--outcome", installing.path],
        environment: [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": try #require(Fixtures.esbuild).path,
            "FUDGE_BUNDLER": try #require(Fixtures.bundler).path, "TMPDIR": temporary.path + "/",
        ], in: root)
    #expect(ran.status == 0, "\(ran.err)")
    #expect(ran.out.contains("→ installed"), "stdout went to the file the test opened: \(ran.out)")
    #expect(try OutcomeRun.outcome(in: installing, pid: ran.pid).status == 0)
}

/// SIGTERM ends the build through its signal path, which writes 143; SIGKILL writes nothing.
@Test func aBuildEndedBySIGTERMWrites143AndOneEndedBySIGKILLWritesNothing() async throws {
    for signal in [SIGTERM, SIGKILL] {
        let (root, extensions, temporary, installing) = try OutcomeRun.folders()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = root.appendingPathComponent("node")
        let pids = root.appendingPathComponent("pids")
        try Tool.neverExiting(at: node, pids: pids)
        let tool = try Tool.bundled(in: root.appendingPathComponent("app"), node: node)
        let source = try Fixtures.greeterCopy()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["build", source.path, "--into", extensions.path, "--outcome", installing.path]
        process.environment = [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": "/nonexistent/esbuild",
            "FUDGE_BUNDLER": "/nonexistent/bundle-extension.cjs", "TMPDIR": temporary.path + "/",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var started: [pid_t] = []
        // Whatever happens, nothing of this test's is left running: the tool, the stand-in and its child.
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            for pid in started where !Tool.isGone(pid) { kill(pid, SIGKILL) }
        }
        let launched = ContinuousClock.now
        while started.count < 2, ContinuousClock.now - launched < Tool.noHang {
            started = ((try? String(contentsOf: pids, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            if started.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(started.count == 2, "the stand-in started")
        kill(process.processIdentifier, signal)
        let exited = try await OffThePool.run(within: Tool.noHang) {
            process.waitUntilExit()
            return true
        }
        try #require(exited == true, "the tool exited")
        if signal == SIGTERM {
            #expect(process.terminationReason == .exit && process.terminationStatus == 143)
            #expect(try OutcomeRun.outcome(in: installing, pid: process.processIdentifier).status == 143)
        } else {
            #expect(process.terminationReason == .uncaughtSignal)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: installing.path) == [], "SIGKILL writes nothing")
        }
    }
}
