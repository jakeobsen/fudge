import Foundation
import Testing

@testable import FudgeCore

// SPEC-124: the log files.

private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

private func lines(_ url: URL) -> [String] { read(url).split(separator: "\n").map(String.init) }

private func id(_ key: String) -> ExtensionID { ExtensionID(stored: key)! }

@Test func theLogsFolderIsTheUsersOrTheThrowawaySupportFolders() {
    let user = FudgePaths.logsDirectory(environment: [:])
    #expect(user.path.hasSuffix("/Library/Logs/Fudge"))
    #expect(user.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    #expect(FudgePaths.logsDirectory(environment: ["FUDGE_SUPPORT_DIR": "/tmp/run"]).path == "/tmp/run/Logs")
    #expect(FudgePaths.logsDirectory(environment: ["FUDGE_SUPPORT_DIR": ""]) == user)

    let folder = URL(fileURLWithPath: "/tmp/run/Logs")
    #expect(LogFile.fudge.url(in: folder)?.path == "/tmp/run/Logs/Fudge.log")
    #expect(LogFile.extension(id("amazon-aws")).url(in: folder)?.path == "/tmp/run/Logs/Extensions/amazon-aws.log")
    #expect(ExtensionID(stored: "../x") == nil && ExtensionID(stored: "") == nil, "neither names an extension's file")
}

@Test func eachLevelRecordsItselfAndTheLevelsAbove() {
    #expect(LogLevel.error.records(.error))
    #expect(!LogLevel.error.records(.warning))
    #expect(LogLevel.warning.records(.error) && LogLevel.warning.records(.warning) && !LogLevel.warning.records(.info))
    #expect(LogLevel.info.records(.info) && !LogLevel.info.records(.debug))
    #expect(LogLevel.allCases.allSatisfy { LogLevel.debug.records($0) })
    #expect(LogLevel.allCases.map(\.title) == ["Errors", "Warnings", "Info", "Debug"])
}

@Test func theLogLevelIsErrorsUntilChosenAndOnlyAChoiceIsSaved() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    #expect(FudgeSettings.load(from: file).logLevel == .error)
    var settings = FudgeSettings.load(from: file)
    settings.logLevel = .debug
    try settings.save(to: file)
    #expect(FudgeSettings.load(from: file).logLevel == .debug)
    settings.logLevel = .error
    try settings.save(to: file)
    #expect(!read(file).contains("logLevel"))
    try Data(#"{"logLevel":"verbose"}"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file).logLevel == .error)
}

@Test func aLineHasItsLocalTimeWithItsOffsetItsLevelItsCommandAndIndentsItsFurtherLines() throws {
    let zone = try #require(TimeZone(secondsFromGMT: 3600))
    let date = Date(timeIntervalSince1970: 1_795_729_501.123)
    #expect(
        LogLine.format(
            date: date, level: .error, command: "console", message: "Error: nope\n    at a\nat b\n", timeZone: zone)
            == "2026-11-26T22:45:01.123+01:00 error [console] Error: nope\n        at a\n    at b\n")
    #expect(
        LogLine.format(date: date, level: .info, message: "installed x 1.0", timeZone: zone)
            == "2026-11-26T22:45:01.123+01:00 info installed x 1.0\n")
}

@Test func filesAreMadeWithTheFirstLineEachGettingTheHeaderFirst() throws {
    let folder = try Fixtures.temporaryDirectory().appendingPathComponent("Logs")
    let writer = LogWriter(folder: folder, header: "Fudge 1.2.3 (v1.2.3)")
    writer.flush()
    #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing logged, nothing made")
    writer.write(.error, "first", to: .fudge)
    writer.write(.error, "an extension's", command: "console", to: .extension(id("amazon-aws")))
    writer.write(.error, "second", to: .fudge)
    writer.flush()
    let fudge = lines(folder.appendingPathComponent("Fudge.log"))
    #expect(fudge.count == 3)
    #expect(fudge[0].hasSuffix(" info Fudge 1.2.3 (v1.2.3)"))
    #expect(fudge[1].hasSuffix(" error first") && fudge[2].hasSuffix(" error second"))
    let aws = lines(folder.appendingPathComponent("Extensions/amazon-aws.log"))
    #expect(
        aws.count == 2 && aws[0].hasSuffix("Fudge 1.2.3 (v1.2.3)")
            && aws[1].hasSuffix(" error [console] an extension's"))
}

@Test func pastItsCapAFileBecomesTheOneOldFileAndANewOneStarts() throws {
    let folder = try Fixtures.temporaryDirectory().appendingPathComponent("Logs")
    let writer = LogWriter(folder: folder, header: nil, caps: [.fudge: 400])
    let line = String(repeating: "x", count: 60)
    for index in 1...20 {
        writer.write(.error, "\(index) \(line)", to: .fudge)
        writer.flush()
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(files == ["Fudge.log", "Fudge.old.log"], "exactly one old file")
    let current = read(folder.appendingPathComponent("Fudge.log"))
    let old = read(folder.appendingPathComponent("Fudge.old.log"))
    #expect(current.utf8.count <= 400 && old.utf8.count <= 400)
    #expect(current.contains(" error 20 "), "the newest line is in the current file")
    #expect(!old.contains(" error 20 ") && old.contains(" error 19 ") || current.contains(" error 19 "))
    #expect(!current.contains(" error 1 ") && !old.contains(" error 1 "), "older ones are gone")
}

/// A file deleted while Fudge runs (by the user, in Finder) starts again with the next line, which isn't lost to a
/// rotation of a file that's gone, and the old file is kept.
@Test func aFileDeletedMeanwhileStartsAgainWithTheNextLine() throws {
    let folder = try Fixtures.temporaryDirectory().appendingPathComponent("Logs")
    let writer = LogWriter(folder: folder, header: nil, caps: [.fudge: 400])
    let line = String(repeating: "x", count: 60)
    for index in 1...8 {
        writer.write(.error, "\(index) \(line)", to: .fudge)
        writer.flush()
    }
    let current = folder.appendingPathComponent("Fudge.log")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Fudge.old.log").path))
    let old = read(folder.appendingPathComponent("Fudge.old.log"))
    try FileManager.default.removeItem(at: current)
    // Past the cap by the size the writer last knew: a rotation would try to move the file that's gone.
    for index in 9...10 {
        writer.write(.error, "\(index) \(line)", to: .fudge)
        writer.flush()
    }
    let after = read(current)
    #expect(after.contains(" error 9 ") && after.contains(" error 10 "), "the lines after the deletion: \(after)")
    #expect(read(folder.appendingPathComponent("Fudge.old.log")) == old, "the old file is kept")
}

@Test func aFloodFillsOnlyItsOwnBufferAndTheDroppedCountFollowsWhenItDrains() throws {
    let folder = try Fixtures.temporaryDirectory().appendingPathComponent("Logs")
    // A suspended queue stands in for a disk that's slow to take the lines.
    let disk = DispatchQueue(label: "test.slow-disk")
    disk.suspend()
    let writer = LogWriter(folder: folder, header: nil, pendingLimit: 10, queue: disk)
    for index in 1...25 { writer.write(.error, "flood \(index)", to: .extension(id("flood"))) }
    for index in 1...3 { writer.write(.error, "steady \(index)", to: .extension(id("steady"))) }
    disk.resume()
    writer.flush()
    let flood = lines(folder.appendingPathComponent("Extensions/flood.log")).map {
        $0.components(separatedBy: " error ").last ?? $0
    }
    #expect(Array(flood.prefix(10)) == (1...10).map { "flood \($0)" })
    #expect(flood.count == 11 && flood[10].hasSuffix(" warning … 15 lines dropped"))
    let steady = lines(folder.appendingPathComponent("Extensions/steady.log")).map {
        $0.components(separatedBy: " error ").last ?? $0
    }
    #expect(steady == ["steady 1", "steady 2", "steady 3"])
}

@Test func writingNeverHappensOnTheCallersThread() throws {
    let folder = try Fixtures.temporaryDirectory().appendingPathComponent("Logs")
    let disk = DispatchQueue(label: "test.held-disk")
    disk.suspend()
    let writer = LogWriter(folder: folder, header: nil, queue: disk)
    let started = ContinuousClock.now
    for index in 1...2500 { writer.write(.error, "line \(index)", to: .fudge) }
    // With the disk held, every write still returned: nothing waited for it.
    #expect(ContinuousClock.now - started < .seconds(1))
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    disk.resume()
    writer.flush()
    #expect(lines(folder.appendingPathComponent("Fudge.log")).count == 2001)
}

@Test func installsUpdatesAndRemovalsAreOneLineEach() {
    let old = Date(timeIntervalSince1970: 1)
    let new = Date(timeIntervalSince1970: 2)
    let before = [
        id("kept"): InstallStamp(version: "1.0", created: old),
        id("bumped"): InstallStamp(version: "1.0", created: old),
        id("rebuilt"): InstallStamp(version: "2.0", created: old),
        id("gone"): InstallStamp(version: nil, created: old),
    ]
    let after = [
        id("kept"): InstallStamp(version: "1.0", created: old),
        id("bumped"): InstallStamp(version: "1.1", created: new),
        id("rebuilt"): InstallStamp(version: "2.0", created: new),
        id("added"): InstallStamp(version: "0.1", created: new),
    ]
    #expect(
        InstallStamp.changes(from: before, to: after) == [
            "installed added 0.1", "updated bumped from 1.0 to 1.1", "removed gone", "updated rebuilt 2.0",
        ])
}

/// `FudgeLog` is the app's one writer, so these share it, one at a time, and leave it unset.
@Suite(.serialized)
struct FudgeLogTests {

    /// MUST 2: a command printing errors in a tight loop never reaches the main actor. Every log line is handed over
    /// on the thread that reads the host, none is handled on the main thread, and none comes through `messages`,
    /// which the main actor reads. The host keeps 1,000 lines a second and counts the rest, so the file holds every
    /// line as kept or counted, ending with the count, and another command's lines still arrive, in order.
    /// (A main-actor timer can't show this in the full suite: other tests hold the main actor for longer than a flood
    /// would.)
    @Test(
        .enabled(if: HostFixture.node != nil && HostFixture.runtimeInstalled, "needs Fudge's Node.js: run `make test`"))
    @MainActor
    func aFloodingCommandHoldsUpNeitherTheMainActorNorAnotherCommandsLines() async throws {
        let folder = try Fixtures.temporaryDirectory().appendingPathComponent("Logs")
        let writer = LogWriter(folder: folder, header: nil)
        FudgeLog.start(writer: writer, level: .error)
        defer { FudgeLog.start(writer: nil, level: .error) }
        let calls = LogCalls()
        let host = try ExtensionHost(
            node: try #require(HostFixture.node), script: HostFixture.runtime.appendingPathComponent("src/host.ts"),
            log: { session, level, message, source in
                calls.record()
                FudgeLog.command(
                    level, message, session: session, extension: source?.extensionID, command: source?.command)
            })
        defer { host.stop() }
        try host.send(.logLevel(.error))

        let support = folder.deletingLastPathComponent()
        for (session, name) in [("s-flood", "flood"), ("s-steady", "steady")] {
            try host.send(
                .launch(
                    session: session, entry: HostFixture.runtimeFixture("\(name)-no-view.cjs").path, mode: "no-view",
                    launchProps: LaunchProps(),
                    environment: LaunchEnvironment(
                        extensionName: name, commandName: "print", commandMode: "no-view", assetsPath: support.path,
                        manifestPath: support.appendingPathComponent("package.json").path, supportPath: support.path,
                        cachePath: support.path,
                        localStoragePath: support.appendingPathComponent("\(name).json").path,
                        ownerOrAuthorName: "test", appearance: "light", isDevelopment: false),
                    extensionId: id(name)))
        }
        var exited: Set<String> = []
        var logMessages = 0
        for await message in host.messages {
            if case .log = message { logMessages += 1 }
            if case .exit(let session, _) = message { exited.insert(session) }
            if exited.count == 2 { break }
        }
        writer.flush()

        #expect(logMessages == 0, "log lines came through the main actor's messages")
        #expect(calls.onMainThread == 0, "log lines handled on the main thread")
        #expect(calls.offMainThread > 1000)
        let flood = lines(folder.appendingPathComponent("Extensions/flood.log")).map {
            $0.components(separatedBy: " [print] ").last ?? $0
        }
        let kept = flood.compactMap { $0.hasPrefix("flood ") ? Int($0.dropFirst("flood ".count)) : nil }
        let counted = flood.compactMap { line -> Int? in
            guard line.hasPrefix("… "), line.hasSuffix(" lines dropped") else { return nil }
            return Int(line.dropFirst("… ".count).dropLast(" lines dropped".count))
        }
        #expect(kept.count + counted.count == flood.count, "only kept lines and counts: \(flood.prefix(3))")
        #expect(kept.count + counted.reduce(0, +) == 20000)
        #expect(kept.count < 20000 && kept == kept.sorted())
        #expect(flood.last?.hasSuffix(" lines dropped") == true)
        let steady = lines(folder.appendingPathComponent("Extensions/steady.log")).map {
            $0.components(separatedBy: " [print] ").last ?? $0
        }
        #expect(steady == (1...50).map { "steady \($0)" })
    }
    @Test func fudgesOwnLinesFollowTheLevelAndAnExtensionsGoOnlyToItsOwnFile() throws {
        let folder = try Fixtures.temporaryDirectory().appendingPathComponent("Logs")
        let writer = LogWriter(folder: folder, header: nil)
        FudgeLog.start(writer: writer, level: .error)
        defer { FudgeLog.start(writer: nil, level: .error) }
        FudgeLog.error("test-own-error")
        FudgeLog.info("test-own-info")
        FudgeLog.command(.error, "test-command-error", session: "s", extension: id("amazon-aws"), command: "console")
        FudgeLog.command(.info, "test-command-info", session: "s", extension: id("amazon-aws"), command: "console")
        FudgeLog.setLevel(.info)
        FudgeLog.info("test-own-info-later")
        writer.flush()
        let fudge = read(folder.appendingPathComponent("Fudge.log"))
        #expect(fudge.contains(" error test-own-error"))
        #expect(!fudge.contains("test-own-info\n"))
        #expect(fudge.contains(" info test-own-info-later"))
        #expect(!fudge.contains("test-command"), "an extension's lines are never in Fudge.log")
        let aws = read(folder.appendingPathComponent("Extensions/amazon-aws.log"))
        #expect(aws.contains(" error [console] test-command-error"))
        #expect(!aws.contains("test-command-info"))
    }

    /// Through the real host: what a command logs at the default level lands in its extension's file with the
    /// command's name, and the launch's typed argument and password preference are in neither file, at any level.
    /// Its errors, handled as `LauncherModel` handles them (`FudgeLog.commandError`), leave only a line of Fudge's own
    /// in `Fudge.log`.
    @Test(
        .enabled(if: HostFixture.node != nil && HostFixture.runtimeInstalled, "needs Fudge's Node.js: run `make test`"),
        arguments: [LogLevel.error, .debug])
    func aCommandsErrorsLandInItsExtensionsFile(level: LogLevel) async throws {
        let folder = try Fixtures.temporaryDirectory().appendingPathComponent("Logs")
        let writer = LogWriter(folder: folder, header: "Fudge test")
        FudgeLog.start(writer: writer, level: level)
        defer { FudgeLog.start(writer: nil, level: .error) }
        let host = try ExtensionHost(
            node: try #require(HostFixture.node), script: HostFixture.runtime.appendingPathComponent("src/host.ts"),
            log: { session, level, message, source in
                FudgeLog.command(
                    level, message, session: session, extension: source?.extensionID, command: source?.command)
            })
        defer { host.stop() }
        var messages = host.messages.makeAsyncIterator()
        try host.send(.logLevel(level))
        let seeds = ["typed": "SEED-TYPED-4F1C", "password": "SEED-PASSWORD-9A2E"]
        let support = folder.deletingLastPathComponent()
        let environment = LaunchEnvironment(
            extensionName: "amazon-aws", commandName: "console", commandMode: "no-view", assetsPath: support.path,
            manifestPath: support.appendingPathComponent("package.json").path, supportPath: support.path,
            cachePath: support.path,
            localStoragePath: support.appendingPathComponent("local-storage.json").path, ownerOrAuthorName: "test",
            appearance: "light", isDevelopment: false)
        try host.send(
            .launch(
                session: "s-logs", entry: HostFixture.runtimeFixture("logs-no-view.cjs").path, mode: "no-view",
                launchProps: LaunchProps(arguments: ["query": seeds["typed"]!]),
                preferences: ["apiKey": .string(seeds["password"]!)], environment: environment,
                extensionId: id("amazon-aws")))
        // Each error the command reports goes where `LauncherModel` sends it, until the command exits.
        var errors: [Bool] = []
        while true {
            let message = try await next(&messages) {
                switch $0 {
                case .error, .exit: true
                default: false
                }
            }
            guard case .error(let session, let text, let stack, let fatal, _) = message else { break }
            errors.append(fatal)
            FudgeLog.commandError(
                text, stack: stack, fatal: fatal, session: session, extension: id("amazon-aws"), command: "console")
        }
        writer.flush()
        #expect(errors.contains(true), "the throw at the end is a fatal error: \(errors)")

        let aws = read(folder.appendingPathComponent("Extensions/amazon-aws.log"))
        #expect(aws.contains(" error [console] an error line, with something typed and a key"))
        #expect(aws.contains(" error [console] Failure toast: Failed to fetch latest data\n    ENOENT: no such file"))
        #expect(aws.contains(" error [console] Error: rejected\n    "))
        #expect(aws.contains(" error [console] Error: thrown at the end\n    "))
        #expect(aws.contains("a warning line") == (level == .debug))
        #expect(aws.contains("a log line") == (level == .debug))
        #expect(aws.contains("a debug line") == (level == .debug))
        let fudge = read(folder.appendingPathComponent("Fudge.log"))
        #expect(!fudge.contains("an error line"), "an extension's lines are never in Fudge.log")
        // MUST 1: the command's error, its text and its stack, is in its own file only. Fudge.log has a line of
        // Fudge's own, naming the command and that it failed.
        #expect(!fudge.contains("thrown at the end") && !fudge.contains("rejected"), "Fudge.log: \(fudge)")
        #expect(fudge.contains(" error amazon-aws/console failed; its error is in Extensions/amazon-aws.log\n"))
        #expect(!fudge.contains("    at "), "no stack in Fudge.log")
        for seed in seeds.values {
            #expect(!aws.contains(seed) && !fudge.contains(seed), "\(seed) was logged")
        }
    }
}

/// The calls `ExtensionHost` makes to hand over log lines, by whether they came on the main thread.
private final class LogCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0
    private var other = 0

    func record() {
        let isMain = Thread.isMainThread
        lock.withLock {
            if isMain { main += 1 } else { other += 1 }
        }
    }

    var onMainThread: Int { lock.withLock { main } }
    var offMainThread: Int { lock.withLock { other } }
}
