import Darwin
import Foundation
import Testing

@testable import FudgeCore

/// A `/usr/bin/perl` of the test's own that holds a build's lock, as another `fudge build` would, until the test stops
/// it by its pid.
final class LockHolder: Sendable {
    let pid: pid_t
    private let process: Process

    private init(_ process: Process) {
        self.process = process
        pid = process.processIdentifier
    }

    /// Starts the holder on `file` and returns once it holds the lock.
    static func start(locking file: URL) async throws -> LockHolder {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "use Fcntl qw(:flock); open(my $f, '>>', $ARGV[0]) or die $!; flock($f, LOCK_EX) or die $!; $| = 1; "
                + "print \"locked\\n\"; sleep 600",
            file.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let holder = LockHolder(process)
        let line = try await OffThePool.run(within: Tool.noHang) {
            String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        }
        guard line == "locked\n" else {
            holder.stop()
            throw ChildProcesses.SpawnError(description: "the lock holder didn't take the lock: \(line ?? "no answer")")
        }
        return holder
    }

    /// Ends it with `signal`, by its own pid, and waits for it to be gone.
    func stop(_ signal: Int32 = SIGTERM) {
        if process.isRunning { kill(pid, signal) }
        process.waitUntilExit()
    }
}

/// What a build did: installed, or refused with an error's words.
enum BuildOutcome: Equatable, Sendable {
    case installed
    case refused(String)

    static func of(_ build: @escaping @Sendable () throws -> InstalledExtension) async throws -> BuildOutcome {
        let outcome = try await OffThePool.run(within: Tool.noHang) { () -> BuildOutcome in
            do {
                _ = try build()
                return .installed
            } catch {
                return .refused(String(describing: error))
            }
        }
        return try #require(outcome, "the build hung")
    }
}

/// The lines a build logs, from whichever thread logs them.
private final class LockTestLog: @unchecked Sendable {
    // @unchecked: `stored` is behind `lock`.
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

/// Every name in `folder`, sorted.
private func names(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

private func alreadyBuilding(_ name: String, _ folder: URL) -> BuildOutcome {
    .refused(String(describing: BuildError.alreadyBuilding(name, folder.path)))
}

/// One build of an extension into one extensions folder at a time (SPEC-153 A).
@Suite(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
struct BuildLockTests {
    @Test func aBuildWhoseLockAnotherProcessHoldsStopsBeforeWritingAnything() async throws {
        let extensions = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extensions) }
        let installed = try Fixtures.builder().build(source: Fixtures.greeter, into: extensions)
        let created = try FileManager.default.attributesOfItem(atPath: installed.directory.path)[.creationDate] as? Date
        let files = try FileManager.default.subpathsOfDirectory(atPath: installed.directory.path).sorted()

        let holder = try await LockHolder.start(locking: ExtensionBuilder.lockFile(of: "greeter", in: extensions))
        defer { holder.stop() }
        let log = LockTestLog()
        let builder = Fixtures.builder(log: { log.append($0) })
        // The holder sleeps for 10 minutes, so a build that waited for the lock would hang until `noHang`.
        #expect(
            try await BuildOutcome.of { try builder.build(source: Fixtures.greeter, into: extensions) }
                == alreadyBuilding("greeter", extensions))
        #expect(log.lines.isEmpty, "nothing was installed or compiled")
        #expect(try names(in: extensions) == [".build-greeter.lock", "greeter"], "no .staging-* folder")
        #expect(
            try FileManager.default.attributesOfItem(atPath: installed.directory.path)[.creationDate] as? Date
                == created, "the install from before is the same folder")
        #expect(try FileManager.default.subpathsOfDirectory(atPath: installed.directory.path).sorted() == files)
    }

    @Test func aLockHolderKilledWithSIGKILLLeavesNoLock() async throws {
        let extensions = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extensions) }
        let holder = try await LockHolder.start(locking: ExtensionBuilder.lockFile(of: "greeter", in: extensions))
        holder.stop(SIGKILL)
        #expect(
            try await BuildOutcome.of { try Fixtures.builder().build(source: Fixtures.greeter, into: extensions) }
                == .installed, "the kernel dropped the lock with the process")
        #expect(try names(in: extensions) == [".build-greeter.lock", "greeter"], "the lock file stays")
    }

    @Test func theLockIsPerNameAndPerFolder() async throws {
        let extensions = try Fixtures.temporaryDirectory()
        let other = try Fixtures.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: extensions)
            try? FileManager.default.removeItem(at: other)
        }
        let holder = try await LockHolder.start(locking: ExtensionBuilder.lockFile(of: "greeter", in: extensions))
        defer { holder.stop() }
        #expect(
            try await BuildOutcome.of { try Fixtures.builder().build(source: Fixtures.commandNames, into: extensions) }
                == .installed, "another name, into the same folder")
        #expect(
            try await BuildOutcome.of { try Fixtures.builder().build(source: Fixtures.greeter, into: other) }
                == .installed, "the same name, into another folder")
    }

    /// Two builds of one extension into one folder, in one process: the first holds the lock just before `replace`
    /// while the second tries. Two opens of one file conflict under `flock`, so the second is refused.
    @Test func twoBuildsCantRaceToReplaceTheInstall() async throws {
        let extensions = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extensions) }
        try Fixtures.builder().build(source: Fixtures.greeter, into: extensions)

        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var first = Fixtures.builder()
        first.beforeReplace = {
            reached.signal()
            release.wait()
        }
        let paused = first
        let firstBuild = Task {
            try await BuildOutcome.of { try paused.build(source: Fixtures.greeter, into: extensions) }
        }
        let waited = try await OffThePool.run(within: Tool.noHang) { reached.wait(timeout: .now() + 60) == .success }
        try #require(waited == true, "the first build reached its replace")

        #expect(
            try await BuildOutcome.of { try Fixtures.builder().build(source: Fixtures.greeter, into: extensions) }
                == alreadyBuilding("greeter", extensions))
        release.signal()
        #expect(try await firstBuild.value == .installed)

        #expect(try names(in: extensions) == [".build-greeter.lock", "greeter"], "no .staging-* or .old-* is left")
        let installed = try InstalledExtension.topLevel(from: extensions.appendingPathComponent("greeter"))
        #expect(
            try names(in: installed.directory) == ["assets", "greet.cjs", "package.json", "quiet.cjs"],
            "one whole build")
    }

    /// A program the build started outlives it (the build was killed with SIGKILL, so it couldn't end its children):
    /// it was given no descriptor (`POSIX_SPAWN_CLOEXEC_DEFAULT`, and `O_CLOEXEC` on the lock), so it doesn't hold the
    /// lock, and the next build goes ahead.
    @Test func aChildLeftRunningDoesntKeepTheLock() async throws {
        let folder = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The compile step's Node.js is a stand-in that sleeps, with a child that sleeps too.
        let node = folder.appendingPathComponent("node")
        let pids = folder.appendingPathComponent("pids")
        try Tool.neverExiting(at: node, pids: pids)
        let tool = try Tool.bundled(in: folder.appendingPathComponent("app"), node: node)
        let extensions = folder.appendingPathComponent("extensions")
        let temporary = folder.appendingPathComponent("tmp")
        for made in [extensions, temporary] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
        let build = Process()
        build.executableURL = tool
        build.arguments = ["build", Fixtures.greeter.path, "--into", extensions.path]
        build.environment = [
            "HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": "/nonexistent/esbuild",
            "FUDGE_BUNDLER": "/nonexistent/bundle-extension.cjs", "TMPDIR": temporary.path + "/",
        ]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        let started = try await OffThePool.run(within: Tool.noHang) { () -> [pid_t] in
            while true {
                let text = (try? String(contentsOf: pids, encoding: .utf8)) ?? ""
                let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
                if numbers.count == 2 { return numbers }
                usleep(20_000)
            }
        }
        let children = try #require(started, "the stand-in started")
        defer {
            for pid in children { kill(pid, SIGKILL) }
        }
        kill(build.processIdentifier, SIGKILL)
        build.waitUntilExit()
        #expect(children.allSatisfy { kill($0, 0) == 0 }, "the build's programs live on")

        #expect(
            try await BuildOutcome.of { try Fixtures.builder().build(source: Fixtures.greeter, into: extensions) }
                == .installed, "the next build isn't refused")
    }
}

/// `fudge build` with the lock held: status 75, which only this uses, and its one line; nothing else is made. The
/// Extension Store reads the same status, and the shared fixture pins both.
@Test func theToolSaysAnotherBuildIsRunningWithStatus75() async throws {
    let fixture = Fixtures.repository.appendingPathComponent("runtime/test/fixtures/build-statuses.json")
    let statuses = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
    #expect(statuses["alreadyBuilding"] as? Int == Int(BuildError.alreadyBuildingStatus))
    #expect(BuildError.alreadyBuildingStatus == 75 && BuildError.alreadyBuilding("a", "/b").exitStatus == 75)
    #expect(BuildError.noCommands.exitStatus == 1)

    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let tool = try Tool.bundled(in: folder.appendingPathComponent("app"), node: Tool.node)
    let extensions = folder.appendingPathComponent("extensions")
    let temporary = folder.appendingPathComponent("tmp")
    for made in [extensions, temporary] {
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    }
    let holder = try await LockHolder.start(locking: ExtensionBuilder.lockFile(of: "greeter", in: extensions))
    defer { holder.stop() }
    let (status, out, err) = try await Tool.run(
        tool, ["build", Fixtures.greeter.path, "--into", extensions.path],
        environment: [
            "HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": "/nonexistent/esbuild",
            "TMPDIR": temporary.path + "/",
        ])
    #expect(status == 75)
    #expect(!out.contains("installed"), "\(out)")
    #expect(
        err
            == "fudge: another fudge build is installing greeter into \(extensions.path); try again when it has finished\n"
    )
    #expect(try names(in: extensions) == [".build-greeter.lock"], "no .staging-* folder")
    #expect(try names(in: temporary) == [], "no fudge-build-* folder")
}

/// Whether the spawning threads of `theLockIsFreeAgainAtOnceWhileOtherThreadsStartPrograms` should stop.
private final class StopFlag: @unchecked Sendable {
    // @unchecked: `stopped` is behind `lock`.
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}

/// A build's lock, given back, is free again at once, while other threads of the process start programs. A program
/// being started holds a copy of every descriptor from `posix_spawn`'s copy of the table until its exec drops the
/// close-on-exec ones, so with `close` alone the lock stayed with that copy for a moment, and a build of the same
/// name right after was refused (`unlockBuild` releases it with `LOCK_UN` first). Four threads start `/usr/bin/true`
/// over and over, with `POSIX_SPAWN_CLOEXEC_DEFAULT`, which doesn't help here, while the lock is taken and given back
/// 20,000 times; not one take may be refused.
@Test func theLockIsFreeAgainAtOnceWhileOtherThreadsStartPrograms() async throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    let stop = StopFlag()
    let spawners = DispatchGroup()
    for _ in 0..<4 {
        spawners.enter()
        Thread {
            defer { spawners.leave() }
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
            let program = strdup("/usr/bin/true")
            defer { free(program) }
            let argv: [UnsafeMutablePointer<CChar>?] = [program, nil]
            let envp: [UnsafeMutablePointer<CChar>?] = [nil]
            while !stop.isSet {
                var pid: pid_t = 0
                guard posix_spawn(&pid, "/usr/bin/true", nil, &attributes, argv, envp) == 0 else { continue }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            }
        }.start()
    }
    let refused = try await OffThePool.run(within: Tool.noHang) { () -> Int in
        defer {
            stop.set()
            spawners.wait()
        }
        var refused = 0
        for _ in 0..<20_000 {
            do {
                ExtensionBuilder.unlockBuild(try ExtensionBuilder.lockBuild(of: "greeter", in: extensions))
            } catch BuildError.alreadyBuilding {
                refused += 1
            }
        }
        return refused
    }
    let count = try #require(refused, "the takes hung")
    #expect(count == 0, "takes refused while the lock was free")
}
