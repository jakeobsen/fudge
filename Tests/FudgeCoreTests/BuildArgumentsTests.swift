import Foundation
import Testing

@testable import FudgeCore

@Test func buildTakesAFolderAndAnOptionalInstallFolder() throws {
    let folders: Set<String> = ["/tmp/ext"]
    let exists = { folders.contains($0) }
    let plain = try BuildArguments.parse(["src/greeter"], isDirectory: exists)
    #expect(plain.destination == nil, "the default extensions folder")
    #expect(plain.source.path.hasSuffix("/src/greeter"))

    let into = try BuildArguments.parse(["src/greeter", "--into", "/tmp/ext"], isDirectory: exists)
    #expect(into.destination?.path == "/tmp/ext")
    #expect(try BuildArguments.parse(["--into", "/tmp/ext", "src/greeter"], isDirectory: exists) == into, "any order")
}

@Test func buildTakesWhatToDoWithSwiftParts() throws {
    let exists = { $0 == "/tmp/ext" }
    #expect(try BuildArguments.parse(["src/greeter"], isDirectory: exists).swiftParts == nil)
    let build = try BuildArguments.parse(["src/greeter", "--swift-parts", "build"], isDirectory: exists)
    #expect(build.swiftParts == .build)
    let leaveOut = try BuildArguments.parse(
        ["--swift-parts", "leave-out", "src/greeter", "--into", "/tmp/ext"], isDirectory: exists)
    #expect(leaveOut.swiftParts == .leaveOut && leaveOut.destination?.path == "/tmp/ext")
}

@Test(arguments: [
    ([], "usage"),
    (["src", "--swift-parts"], "--swift-parts takes build or leave-out"),
    (["src", "--swift-parts", "compile"], "--swift-parts takes build or leave-out"),
    (["src", "--swift-parts", "--into"], "--swift-parts takes build or leave-out"),
    (["a", "b"], "usage"),
    (["src", "--into"], "usage"),
    (["src", "--into", "relative/ext"], "absolute path"),
    (["src", "--into", "/tmp/missing"], "no such folder"),
    (["--into", "/tmp/ext"], "usage"),
])
func buildRefusesBadArguments(arguments: [String], reason: String) {
    #expect {
        try BuildArguments.parse(arguments, isDirectory: { $0 == "/tmp/ext" })
    } throws: { error in
        String(describing: error).contains(reason)
    }
}

@Suite(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
struct BuildIntoTests {
    @Test func buildIntoInstallsThereAndNowhereElse() throws {
        let into = try Fixtures.temporaryDirectory()
        let support = try Fixtures.temporaryDirectory()
        let defaultFolder = FudgePaths.standard(environment: ["FUDGE_SUPPORT_DIR": support.path]).extensionsDirectory
        let arguments = try BuildArguments.parse([Fixtures.greeter.path, "--into", into.path])
        let builder = Fixtures.builder()
        let installed = try builder.build(
            source: arguments.source, into: arguments.destination ?? defaultFolder)
        #expect(installed.directory.deletingLastPathComponent().standardizedFileURL == into.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: defaultFolder.path), "the default folder is untouched")
    }
}

/// The source folder must never be what a build replaces (#51's review): these are refused before anything is
/// compiled, so they need no esbuild.
struct BuildNeverReplacesItsSourceTests {
    let builder = ExtensionBuilder(esbuild: URL(fileURLWithPath: "/missing-esbuild"))

    private func sourceFiles(_ folder: URL) -> [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: folder.path))?.sorted() ?? []
    }

    @Test func intoTheSourcesOwnParentIsRefused() throws {
        let source = try Fixtures.greeterCopy()  // <tmp>/greeter, named "greeter"
        let before = sourceFiles(source)
        #expect(
            throws: BuildError.sourceIsDestination(
                source.deletingLastPathComponent().appendingPathComponent("greeter").path)
        ) {
            try builder.build(source: source, into: source.deletingLastPathComponent())
        }
        #expect(sourceFiles(source) == before, "the source is untouched")
    }

    @Test func aCaseDifferentSourceFolderIsTheSameFolder() throws {
        let parent = try Fixtures.temporaryDirectory()
        let source = parent.appendingPathComponent("Greeter")
        try FileManager.default.copyItem(at: Fixtures.greeter, to: source)
        #expect {
            try builder.build(source: source, into: parent)
        } throws: { error in
            if case BuildError.sourceIsDestination = error { return true }
            return false
        }
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("src").path))
    }

    @Test func intoTheSourceItselfIsRefused() throws {
        let source = try Fixtures.greeterCopy()
        #expect {
            try builder.build(source: source, into: source)
        } throws: { error in
            if case BuildError.sourceIsDestination = error { return true }
            return false
        }
    }

    @Test func aFolderThatIsntAFudgeBuildIsNeverReplaced() throws {
        let extensions = try Fixtures.temporaryDirectory()
        let inTheWay = extensions.appendingPathComponent("greeter")
        try FileManager.default.createDirectory(
            at: inTheWay.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: inTheWay.appendingPathComponent("src/notes.txt"))
        #expect(throws: BuildError.notAnInstall(inTheWay.path)) {
            try builder.build(source: Fixtures.greeter, into: extensions)
        }
        #expect(FileManager.default.fileExists(atPath: inTheWay.appendingPathComponent("src/notes.txt").path))
    }

    @Test func anEarlierBuildMayBeReplaced() throws {
        let extensions = try Fixtures.temporaryDirectory()
        let installed = extensions.appendingPathComponent("greeter")
        try FileManager.default.createDirectory(
            at: installed.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: installed.appendingPathComponent("package.json"))
        try Data().write(to: installed.appendingPathComponent(".DS_Store"))
        try ExtensionBuilder.checkDestination(installed, source: Fixtures.greeter)
    }

    /// SPEC-123: a build's commands sit beside its `package.json`, which names them.
    @Test func aBuildsCommandsBesideItsManifestMayBeReplaced() throws {
        let installed = try Fixtures.temporaryDirectory().appendingPathComponent("greeter")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Fixtures.greeter.appendingPathComponent("assets"), to: installed.appendingPathComponent("assets"))
        try FileManager.default.copyItem(
            at: Fixtures.greeter.appendingPathComponent("package.json"),
            to: installed.appendingPathComponent("package.json"))
        for file in ["greet.cjs", "quiet.cjs", "compatibility.json"] {
            try Data().write(to: installed.appendingPathComponent(file))
        }
        try ExtensionBuilder.checkDestination(installed, source: Fixtures.greeter)
    }

    @Test(arguments: ["stray.cjs", "greet.js", "dist.cjs"])
    func aFileItsManifestDoesntNameIsntABuild(_ stray: String) throws {
        let installed = try Fixtures.temporaryDirectory().appendingPathComponent("greeter")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Fixtures.greeter.appendingPathComponent("package.json"),
            to: installed.appendingPathComponent("package.json"))
        try Data().write(to: installed.appendingPathComponent("greet.cjs"))
        try Data().write(to: installed.appendingPathComponent(stray))
        #expect(throws: BuildError.notAnInstall(installed.path)) {
            try ExtensionBuilder.checkDestination(installed, source: Fixtures.greeter)
        }
    }

    @Test func commandFilesWithoutAManifestArentABuild() throws {
        let installed = try Fixtures.temporaryDirectory().appendingPathComponent("greeter")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data().write(to: installed.appendingPathComponent("greet.cjs"))
        #expect(throws: BuildError.notAnInstall(installed.path)) {
            try ExtensionBuilder.checkDestination(installed, source: Fixtures.greeter)
        }
    }
}
