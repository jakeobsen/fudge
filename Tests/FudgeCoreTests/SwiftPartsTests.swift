import Foundation
import Testing

@testable import FudgeCore

extension Fixtures {
    /// Made up: an extension with a part written in Swift, as 49 of the store's have (SPEC-145).
    static let swiftPart = directory.appendingPathComponent("swift-part", isDirectory: true)

    /// A tools folder holding the made-up `swift` (`Fixtures/fake-swift`, copied to `usr/bin`), as the Command Line
    /// Tools hold theirs. It logs its runs to `usr/bin/runs.log` and its environments to `usr/bin/environment.log`.
    static func fakeCommandLineTools() throws -> CommandLineTools.Tools {
        let folder = try temporaryDirectory().appendingPathComponent("CommandLineTools", isDirectory: true)
        let bin = folder.appendingPathComponent("usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("fake-swift"), to: bin)
        return CommandLineTools.Tools(
            folder: folder, swift: bin.appendingPathComponent("swift"),
            version: CommandLineTools.SwiftVersion(major: 6, minor: 3, text: "6.3.3"))
    }
}

extension CommandLineTools.Tools {
    var runs: [String] {
        let log = swift.deletingLastPathComponent().appendingPathComponent("runs.log")
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var environments: String {
        let log = swift.deletingLastPathComponent().appendingPathComponent("environment.log")
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }
}

/// What `fudge build` says without `--swift-parts`, and with `build` but no tools (`scripts/compile/swift.ts`).
private let chooseSwiftParts =
    "this extension has a part written in Swift: choose --swift-parts build or --swift-parts leave-out"
private let toolsNotSetUp = "Apple's Command Line Tools aren't set up. Set them up in Settings → Development."

/// What a failed compile printed (`BuildError.compileFailed`), or nil when `build` didn't fail that way.
private func compileOutput(_ build: () throws -> Void) -> String? {
    do {
        try build()
    } catch BuildError.compileFailed(_, let output) {
        return output
    } catch {
        Issue.record("another failure: \(error)")
    }
    return nil
}

/// Every file under `folder`, with its contents, to tell that a build left it as it was.
private func snapshot(_ folder: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        let path = url.path.replacingOccurrences(of: folder.path, with: "")
        files[path] = (try? Data(contentsOf: url)) ?? Data()
    }
    return files
}

@Suite(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
struct SwiftPartsBuildTests {
    func builder(
        _ swiftParts: BuildArguments.SwiftParts?, tools: CommandLineTools.Tools?, asked: AskCounter = AskCounter()
    ) throws -> ExtensionBuilder {
        var builder = Fixtures.builder()
        builder.swiftParts = swiftParts
        builder.commandLineTools = {
            asked.add()
            return tools
        }
        builder.swiftPackageCache = try Fixtures.temporaryDirectory().appendingPathComponent("SwiftPM")
        return builder
    }

    final class AskCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test func buildsTheSwiftPartIntoRaycastsPathWithModeSevenFiveFive() throws {
        let tools = try Fixtures.fakeCommandLineTools()
        let extensions = try Fixtures.temporaryDirectory()
        let before = try snapshot(Fixtures.swiftPart)
        let builder = try builder(.build, tools: tools)
        let installed = try builder.build(source: Fixtures.swiftPart, into: extensions)

        let program = installed.directory.appendingPathComponent("assets/compiled_raycast_swift/swift")
        let mode = try FileManager.default.attributesOfItem(atPath: program.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(!FileManager.default.fileExists(atPath: installed.directory.appendingPathComponent("swift").path))
        #expect(SwiftPartsRecord.load(from: installed.directory) == SwiftPartsRecord(swiftParts: .build))
        #expect(try snapshot(Fixtures.swiftPart) == before, "the source folder is as it was: no .build in it")
        // SwiftPM ran in a copy, with the shared cache, and with the tools' folder as DEVELOPER_DIR.
        #expect(tools.runs.count == 3)
        #expect(tools.runs.allSatisfy { !$0.hasPrefix(Fixtures.swiftPart.path) })
        #expect(
            tools.runs[1].hasSuffix("build -c release --product swift --cache-path \(builder.swiftPackageCache.path)"))
        #expect(tools.environments.contains("\nDEVELOPER_DIR=\(tools.folder.path)\n"))
        let greet = try String(contentsOf: installed.directory.appendingPathComponent("greet.cjs"), encoding: .utf8)
        #expect(greet.contains(#"environment.assetsPath, "compiled_raycast_swift", "swift")"#))
    }

    @Test func leavesTheSwiftPartOutRunningNothing() throws {
        let tools = try Fixtures.fakeCommandLineTools()
        let asked = AskCounter()
        let installed = try builder(.leaveOut, tools: tools, asked: asked)
            .build(source: Fixtures.swiftPart, into: try Fixtures.temporaryDirectory())
        #expect(tools.runs.isEmpty, "no swift ran")
        #expect(asked.value == 0, "the tools aren't even looked for")
        #expect(SwiftPartsRecord.load(from: installed.directory) == SwiftPartsRecord(swiftParts: .leaveOut))
        #expect(!FileManager.default.fileExists(atPath: installed.directory.appendingPathComponent("assets").path))
        let greet = try String(contentsOf: installed.directory.appendingPathComponent("greet.cjs"), encoding: .utf8)
        #expect(
            greet.contains(#"Reinstall it with Apple's Command Line Tools set up in Settings \u2192 Development."#),
            "esbuild writes the arrow escaped")
    }

    @Test func withoutTheFlagOrTheToolsNothingIsInstalled() throws {
        for (swiftParts, message) in [(nil, chooseSwiftParts), (BuildArguments.SwiftParts.build, toolsNotSetUp)] {
            let extensions = try Fixtures.temporaryDirectory()
            let builder = try builder(swiftParts, tools: nil)
            let output = try #require(
                compileOutput { try builder.build(source: Fixtures.swiftPart, into: extensions) })
            #expect(output.contains("✘ [ERROR] \(message) [plugin swift]"), "\(output)")
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: extensions.path).filter { !$0.hasPrefix(".") } == []
            )
        }
    }

    @Test func withoutASwiftPartTheFlagChangesNothing() throws {
        let tools = try Fixtures.fakeCommandLineTools()
        for swiftParts in [nil, BuildArguments.SwiftParts.build, .leaveOut] {
            let installed = try builder(swiftParts, tools: tools)
                .build(source: Fixtures.greeter, into: try Fixtures.temporaryDirectory())
            #expect(SwiftPartsRecord.load(from: installed.directory) == nil)
        }
        #expect(tools.runs.isEmpty)
    }

    @Test func anUpdateOverAnInstallWithoutItsSwiftPartIsntRefused() throws {
        let tools = try Fixtures.fakeCommandLineTools()
        let extensions = try Fixtures.temporaryDirectory()
        let first = try builder(.leaveOut, tools: tools).build(source: Fixtures.swiftPart, into: extensions)
        #expect(SwiftPartsRecord.load(from: first.directory)?.swiftParts == .leaveOut)
        let second = try builder(.build, tools: tools).build(source: Fixtures.swiftPart, into: extensions)
        #expect(SwiftPartsRecord.load(from: second.directory)?.swiftParts == .build)
        let third = try builder(.leaveOut, tools: tools).build(source: Fixtures.swiftPart, into: extensions)
        #expect(SwiftPartsRecord.load(from: third.directory)?.swiftParts == .leaveOut)
        #expect(
            !FileManager.default.fileExists(atPath: third.directory.appendingPathComponent("assets").path),
            "the program built before goes with the old install")
    }

    @Test func aFailedSwiftBuildFailsTheInstallWithSwiftPMsOutput() throws {
        let tools = try Fixtures.fakeCommandLineTools()
        // The fake fails when a file named `fail` is beside it: an environment variable would reach other tests.
        try Data().write(to: tools.swift.deletingLastPathComponent().appendingPathComponent("fail"))
        let extensions = try Fixtures.temporaryDirectory()
        let builder = try builder(.build, tools: tools)
        let output = try #require(compileOutput { try builder.build(source: Fixtures.swiftPart, into: extensions) })
        #expect(
            output.contains(
                "the part written in Swift didn't build\nSources/X/Y.swift:1:1: error: cannot find 'x' in scope"),
            "\(output)")
    }
}

/// SPEC-145 §2: `fudge build` run as the Extension Store runs it, with the store's environment: SwiftPM gets it as it is,
/// with `DEVELOPER_DIR` added and nothing else changed, and the tools come from `settings.json`, as Settings →
/// Development finds them.
@Test(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
func fromTheStoreSwiftPMGetsTheStoresEnvironmentAndDeveloperDir() async throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let tools = try Fixtures.fakeCommandLineTools()
    let support = folder.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    var settings = FudgeSettings()
    settings.commandLineTools = tools.folder.path
    try settings.save(to: FudgePaths(supportDirectory: support).settingsFile)
    let extensions = folder.appendingPathComponent("extensions")
    try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
    let tool = try Tool.bundled(in: folder.appendingPathComponent("app"), node: Tool.node)

    // `storeEnvironment()` in the store's git.ts: its git settings and a proxy.
    let store = [
        "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "HTTPS_PROXY": "http://proxy.invalid:3128",
    ]
    let (status, out, err) = try await Tool.run(
        tool, ["build", Fixtures.swiftPart.path, "--into", extensions.path, "--swift-parts", "build"],
        environment: store.merging([
            "HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_ESBUILD": try #require(Fixtures.esbuild).path,
            "FUDGE_BUNDLER": try #require(Fixtures.bundler).path, "TMPDIR": folder.path + "/",
            "FUDGE_SUPPORT_DIR": support.path,
        ]) { _, new in new })
    #expect(status == 0, "\(out)\(err)")
    let seen = tools.environments
    for (name, value) in store { #expect(seen.contains("\n\(name)=\(value)\n"), "\(name)") }
    #expect(seen.contains("\nDEVELOPER_DIR=\(tools.folder.path)\n"))
    #expect(
        tools.runs.contains { $0.contains("--cache-path \(support.path)/Caches/SwiftPM") },
        "the shared cache follows FUDGE_SUPPORT_DIR")
    let program = extensions.appendingPathComponent("swift-part/assets/compiled_raycast_swift/swift")
    #expect(FileManager.default.isExecutableFile(atPath: program.path))
}

@Test func theRecordSaysLeftOutWhenAnyPackageWas() throws {
    let folder = try Fixtures.temporaryDirectory()
    let report = folder.appendingPathComponent("report.json")
    #expect(SwiftPartsRecord(report: report) == nil, "no report: no Swift part")
    for (text, expected) in [
        (#"{}"#, nil),
        (#"{"/a/swift": "build"}"#, SwiftPartsRecord(swiftParts: .build)),
        (#"{"/a/swift": "leave-out"}"#, SwiftPartsRecord(swiftParts: .leaveOut)),
        (#"{"/a/swift": "build", "/a/more": "leave-out"}"#, SwiftPartsRecord(swiftParts: .leaveOut)),
        (#"{"/a/swift": "other"}"#, nil),
        ("not json", nil),
    ] as [(String, SwiftPartsRecord?)] {
        try Data(text.utf8).write(to: report)
        #expect(SwiftPartsRecord(report: report) == expected, "\(text)")
    }
    try SwiftPartsRecord(swiftParts: .leaveOut).write(to: folder)
    #expect(
        try String(contentsOf: folder.appendingPathComponent("swift-parts.json"), encoding: .utf8)
            == #"{"swiftParts":"leave-out"}"#)
    #expect(SwiftPartsRecord.load(from: folder) == SwiftPartsRecord(swiftParts: .leaveOut))
    #expect(ExtensionBuilder.installedItems.contains(SwiftPartsRecord.fileName))
}

@Test func theSwiftPackageCacheFollowsTheSupportFolder() {
    #expect(
        FudgePaths.swiftPackageCache(environment: ["FUDGE_SUPPORT_DIR": "/tmp/support"]).path
            == "/tmp/support/Caches/SwiftPM")
    #expect(FudgePaths.swiftPackageCache(environment: [:]).path.hasSuffix("/Library/Caches/Fudge/SwiftPM"))
}
