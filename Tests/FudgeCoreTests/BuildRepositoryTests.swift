import Darwin
import Foundation
import Testing

@testable import FudgeCore

/// The names in `folder`, sorted; none when it's missing.
private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

private func created(_ folder: URL) throws -> Date? {
    try FileManager.default.attributesOfItem(atPath: folder.path)[.creationDate] as? Date
}

/// The real `fudge build`, laid out as in Fudge.app, with its support folder and the extensions folder in it.
private struct RealTool {
    let folder: URL
    let tool: URL
    var support: URL { folder.appendingPathComponent("support", isDirectory: true) }
    var extensions: URL { FudgePaths(supportDirectory: support).extensionsDirectory }

    init() throws {
        folder = try Fixtures.temporaryDirectory()
        tool = try Tool.bundled(in: folder.appendingPathComponent("app"), node: Tool.node)
        for made in [extensions, folder.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
    }

    /// `fudge build <source> --into <extensions>`, then `arguments`.
    func build(_ source: URL, _ arguments: [String] = []) async throws -> (status: Int32, out: String, err: String) {
        let (status, out, err) = try await Tool.run(
            tool, ["build", source.path, "--into", extensions.path] + arguments,
            environment: [
                "HOME": folder.path, "PATH": "/usr/bin:/bin", "FUDGE_SUPPORT_DIR": support.path,
                "FUDGE_ESBUILD": try #require(Fixtures.esbuild).path,
                "FUDGE_BUNDLER": try #require(Fixtures.bundler).path,
                "TMPDIR": folder.appendingPathComponent("tmp").path + "/",
            ])
        return (status, out, err)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// A copy of the greeter whose `greet` command says `text`, so each build's code is its own.
private func greeter(saying text: String) throws -> URL {
    let source = try Fixtures.greeterCopy()
    let command = source.appendingPathComponent("src/greet.tsx")
    let code = try String(contentsOf: command, encoding: .utf8)
    try (code + "\nexport const said = \(String(reflecting: text));\n").write(
        to: command, atomically: true, encoding: .utf8)
    return source
}

/// `fudge build --repository` (FUD-183), through the real tool.
@Suite(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
struct FudgeBuildRepositoryTests {
    @Test func eachRepositoryHasItsOwnFolderAndId() async throws {
        let run = try RealTool()
        defer { run.remove() }
        let cases: [([String], String)] = [
            (["--repository", "raycast/extensions"], "greeter raycast raycast/extensions/greeter"),
            (
                ["--repository", "someone/tools"],
                "someone+tools+greeter added(\"someone/tools\") someone/tools/greeter"
            ),
            ([], "fudgeapp+development+greeter development fudgeapp/development/greeter"),
        ]
        for (arguments, _) in cases {
            let ran = try await run.build(Fixtures.greeter, arguments)
            #expect(ran.status == 0, "\(arguments): \(ran.err)")
        }
        #expect(Layout.loaded(run.extensions) == cases.map(\.1).sorted())
        let development = Development.folder(in: run.extensions).appendingPathComponent("greeter")
        let before = try created(development)

        // `--repository fudgeapp/development` is the same as none: the same folder and id, rebuilt in place.
        let again = try await run.build(Fixtures.greeter, ["--repository", "fudgeapp/development"])
        #expect(again.status == 0, "\(again.err)")
        #expect(Layout.loaded(run.extensions) == cases.map(\.1).sorted())
        #expect(try created(development) != before, "the development build was replaced")
        #expect(
            names(in: run.extensions) == [
                ".build-fudgeapp+development+greeter.lock", ".build-greeter.lock", ".build-someone+tools+greeter.lock",
                ".move.lock", "fudgeapp", "raycast", "someone",
            ])
    }

    /// A development build and an added repository's build of a name Raycast's has installed each go beside it, and
    /// Raycast's install stays as it was.
    @Test func otherBuildsOfANameRaycastsHasInstalledGoBesideIt() async throws {
        let run = try RealTool()
        defer { run.remove() }
        let raycast = try greeter(saying: "raycast")
        let development = try greeter(saying: "development")
        let added = try greeter(saying: "added")
        defer {
            for source in [raycast, development, added] {
                try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            }
        }
        #expect(try await run.build(raycast, ["--repository", "raycast/extensions"]).status == 0)
        let installed = run.extensions.appendingPathComponent("raycast/extensions/greeter")
        let before = try created(installed)
        let code = try Data(contentsOf: installed.appendingPathComponent("greet.cjs"))

        #expect(try await run.build(development).status == 0)
        #expect(try await run.build(added, ["--repository", "someone/tools"]).status == 0)
        #expect(try created(installed) == before)
        #expect(try Data(contentsOf: installed.appendingPathComponent("greet.cjs")) == code)
        let loaded = InstalledExtension.load(walking: run.extensions).installed
        #expect(loaded.map(\.id.key).sorted() == ["fudgeapp+development+greeter", "greeter", "someone+tools+greeter"])
        for (id, said) in [
            ("greeter", "raycast"), ("fudgeapp+development+greeter", "development"), ("someone+tools+greeter", "added"),
        ] {
            let install = try #require(loaded.first { $0.id.key == id })
            #expect(
                try String(contentsOf: install.entry(for: "greet"), encoding: .utf8).contains("\"\(said)\""), "\(id)")
        }
    }

    /// `--repository raycast/extensions` replaces the Extension Store's install of that name, as a rebuild does, and
    /// never writes the store's `installed.json`.
    @Test func raycastsFolderIsReplacedAndTheStoresRecordIsLeftAsItWas() async throws {
        let run = try RealTool()
        defer { run.remove() }
        #expect(try await run.build(Fixtures.greeter, ["--repository", "raycast/extensions"]).status == 0)
        let store = FudgePaths(supportDirectory: run.support).supportDirectory(
            forExtension: ExtensionStore.extensionName)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let record = Data(
            #"{"greeter":{"tree":"abc","commit":"def","installedAt":"2026-01-01T00:00:00.000Z","dir":"greeter"}}"#.utf8)
        try record.write(to: store.appendingPathComponent("installed.json"))
        let installed = run.extensions.appendingPathComponent("raycast/extensions/greeter")
        let before = try created(installed)

        let mine = try greeter(saying: "mine")
        defer { try? FileManager.default.removeItem(at: mine.deletingLastPathComponent()) }
        #expect(try await run.build(mine, ["--repository", "raycast/extensions"]).status == 0)
        #expect(try created(installed) != before, "replaced")
        #expect(
            try String(contentsOf: installed.appendingPathComponent("greet.cjs"), encoding: .utf8).contains("\"mine\""))
        #expect(try Data(contentsOf: store.appendingPathComponent("installed.json")) == record, "byte for byte")
        #expect(Layout.loaded(run.extensions) == ["greeter raycast raycast/extensions/greeter"])
    }

    @Test func aRepositoryFolderThatIsntOneIsRefused() async throws {
        let run = try RealTool()
        defer { run.remove() }
        for folder in ["development", "../x", "Someone/tools", "fudgeapp"] {
            let ran = try await run.build(Fixtures.greeter, ["--repository", folder])
            #expect(ran.status == 2, "\(folder)")
            #expect(
                ran.err
                    == "fudge: --repository takes a repository folder, such as raycast/extensions or owner/repository: \(folder)\n"
            )
        }
        #expect(names(in: run.extensions) == [], "nothing was made")
    }

    /// An id over 200 bytes would make a log file's name too long: a host's folder of 160 bytes and a long name.
    @Test func anIdTooLongIsRefused() async throws {
        let run = try RealTool()
        defer { run.remove() }
        let source = try Fixtures.greeterCopy()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let long = String(repeating: "a", count: 60)
        try Fixtures.rename(source, to: long)
        // 160 bytes, the most a repository folder may have; with the name, the id has 221.
        let folder = "git.example.org/" + String(repeating: "b", count: 100) + "/" + String(repeating: "c", count: 43)
        let ran = try await run.build(source, ["--repository", folder])
        #expect(ran.status == 1)
        #expect(ran.err == "fudge: That extension's name is too long for Fudge to keep its files.\n")
        #expect(names(in: run.extensions) == [], "nothing was made")
    }

    /// A repository's folder inside an install: the build stops before writing anything there, the lock included.
    @Test func aRepositoryFolderInsideAnInstallIsRefusedBeforeAnythingIsWritten() async throws {
        let run = try RealTool()
        defer { run.remove() }
        let install = try Layout.install("extensions", at: "git.example.org/team/extensions", in: run.extensions)
        let before = names(in: install)
        let ran = try await run.build(Fixtures.greeter, ["--repository", "git.example.org/team/extensions"])
        #expect(ran.status == 1)
        #expect(ran.err == "fudge: That repository's folder is inside an installed extension.\n")
        #expect(names(in: install) == before)
        #expect(names(in: run.extensions) == [".move.lock", "git.example.org"], "no lock, no staging")
    }

    /// The move runs before the build works out where it goes: a legacy install named `fudgeapp` is filed with
    /// Raycast's first, so the development build isn't refused for going through it.
    @Test func aLegacyFudgeappInstallIsMovedBeforeADevelopmentBuild() async throws {
        let run = try RealTool()
        defer { run.remove() }
        try Layout.install("fudgeapp", at: "fudgeapp", in: run.extensions)
        let ran = try await run.build(Fixtures.greeter)
        #expect(ran.status == 0, "\(ran.err)")
        #expect(
            Layout.loaded(run.extensions) == [
                "fudgeapp raycast raycast/extensions/fudgeapp",
                "fudgeapp+development+greeter development fudgeapp/development/greeter",
            ])
    }
}

/// The builder in this process, where seams reach.
@Suite(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
struct BuildIntoARepositoryTests {
    /// Staging and the old copy are beside the destination, in the repository's folder, so the swap is a rename on one
    /// volume; the top of the extensions folder holds only the locks.
    @Test func stagingIsInTheRepositorysFolder() throws {
        let extensions = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extensions) }
        let repository = extensions.appendingPathComponent("someone/tools")
        let seen = LockedLines()
        var builder = Fixtures.builder()
        builder.beforeReplace = {
            for name in names(in: repository) { seen.append(name) }
            for name in names(in: extensions) { seen.append("top: \(name)") }
        }
        let installed = try builder.build(source: Fixtures.greeter, into: extensions, repository: "someone/tools")
        #expect(installed.directory == repository.appendingPathComponent("greeter", isDirectory: true))
        #expect(installed.id.key == "someone+tools+greeter" && installed.repository == .added("someone/tools"))
        let staged = seen.lines.filter { !$0.hasPrefix("top: ") }
        #expect(staged.count == 1 && staged.first?.hasPrefix(".staging-greeter-") == true, "\(seen.lines)")
        #expect(
            seen.lines.filter { $0.hasPrefix("top: ") }
                == ["top: .build-someone+tools+greeter.lock", "top: .move.lock", "top: someone"])
        #expect(names(in: repository) == ["greeter"])
    }

    /// The extensions folder is made first, then the move's lock is taken in it, so a first build works.
    @Test func aMissingExtensionsFolderIsMadeFirst() throws {
        let folder = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = folder.appendingPathComponent("extensions")
        let installed = try Fixtures.builder().build(source: Fixtures.greeter, into: extensions)
        #expect(installed.id == Development.id("greeter"))
        #expect(names(in: extensions) == [Development.lock("greeter"), ".move.lock", "fudgeapp"])
    }

    @Test func somethingOnTheWayThatIsntAFolderIsRefused() throws {
        let extensions = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extensions) }
        try Data().write(to: extensions.appendingPathComponent("someone"))
        #expect(throws: BuildError.notAFolder(extensions.appendingPathComponent("someone").path)) {
            try Fixtures.builder().build(source: Fixtures.greeter, into: extensions, repository: "someone/tools")
        }
    }
}

/// `fudge build` waits for another Fudge's move at most its bound (60 s; here a seam's 300 ms), then stops with
/// `cantLock`, before anything else.
@Test func aBuildGivesUpWaitingForAMove() async throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    let held = try ExtensionLayout.lockMove(in: extensions, waitingAtMost: .zero, every: .milliseconds(100))
    defer { ExtensionLayout.unlockMove(held) }
    var builder = Fixtures.builder()
    builder.moveLockWait = .milliseconds(300)
    let waiting = builder
    let outcome = try await BuildOutcome.of { try waiting.build(source: Fixtures.greeter, into: extensions) }
    #expect(
        outcome
            == .refused(
                String(
                    describing: BuildError.cantLock(
                        path: extensions.appendingPathComponent(".move.lock").path,
                        reason:
                            "another Fudge was still moving the installed extensions into their repositories' folders"))
            ))
    #expect(names(in: extensions) == [".move.lock"])
}
