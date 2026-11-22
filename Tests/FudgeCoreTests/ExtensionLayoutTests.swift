import Foundation
import Testing

@testable import FudgeCore

// SPEC-123: commands sit beside `assets/` and `package.json`, as in Raycast, and installs from before move over.

private var files: FileManager { .default }

private func write(_ text: String, to url: URL) throws {
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: false, encoding: .utf8)
}

/// An install as builds from before SPEC-123 wrote it: `package.json`, `assets/`, and each command in `dist/`.
private func oldInstall(in extensions: URL, name: String = "x", commands: [String] = ["a", "b"]) throws -> URL {
    let directory = extensions.appendingPathComponent(name, isDirectory: true)
    let declared = commands.map { #"{"name":"\#($0)","title":"\#($0)","mode":"no-view"}"# }
    try write(
        #"{"name":"\#(name)","title":"X","commands":[\#(declared.joined(separator: ","))]}"#,
        to: directory.appendingPathComponent("package.json"))
    try write("{}", to: directory.appendingPathComponent("assets/data.json"))
    for command in commands {
        try write("module.exports = \"\(command)\"", to: directory.appendingPathComponent("dist/\(command).cjs"))
    }
    return directory
}

private func names(in directory: URL) throws -> [String] {
    try files.contentsOfDirectory(atPath: directory.path).sorted()
}

@Test func anOldInstallMovesUpWholeAndDistGoes() throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory())
    #expect(ExtensionLayout.moveUp(install) == .moved)
    #expect(try names(in: install) == ["a.cjs", "assets", "b.cjs", "package.json"])
    #expect(
        try String(contentsOf: install.appendingPathComponent("a.cjs"), encoding: .utf8) == #"module.exports = "a""#)
    let installed = try InstalledExtension.load(from: install)
    #expect(installed.entry(for: "a") == install.appendingPathComponent("a.cjs"))
    #expect(ExtensionLayout.moveUp(install) == nil, "nothing is left to move")
}

@Test func aMoveStoppedHalfwayLaunchesFromBothPlacesAndFinishesNextTime() throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory())
    // Stopped after the first rename.
    try files.moveItem(at: install.appendingPathComponent("dist/a.cjs"), to: install.appendingPathComponent("a.cjs"))
    let installed = try InstalledExtension.load(from: install)
    #expect(installed.entry(for: "a") == install.appendingPathComponent("a.cjs"))
    #expect(installed.entry(for: "b") == install.appendingPathComponent("dist/b.cjs"))

    #expect(ExtensionLayout.moveUp(install) == .moved)
    #expect(try names(in: install) == ["a.cjs", "assets", "b.cjs", "package.json"])
}

@Test func aMoveStoppedBeforeDistWentRemovesIt() throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory(), commands: ["a"])
    try files.moveItem(at: install.appendingPathComponent("dist/a.cjs"), to: install.appendingPathComponent("a.cjs"))
    #expect(ExtensionLayout.moveUp(install) == .moved)
    #expect(try names(in: install) == ["a.cjs", "assets", "package.json"])
}

@Test(arguments: ["notes.txt", "c.cjs", ".DS_Store", "a.js"])
func anythingElseInDistLeavesTheInstallAsItIs(_ stray: String) throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory())
    try write("", to: install.appendingPathComponent("dist/\(stray)"))
    let before = try files.subpathsOfDirectory(atPath: install.path).sorted()

    #expect(ExtensionLayout.moveUp(install) == .leftAlone(.unknownItem))
    #expect(try files.subpathsOfDirectory(atPath: install.path).sorted() == before, "nothing half-moved")
    let installed = try InstalledExtension.load(from: install)
    #expect(installed.entry(for: "a") == install.appendingPathComponent("dist/a.cjs"), "the fallback still finds it")
}

@Test func aCommandInDistThatIsALinkIsntMoved() throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory())
    let elsewhere = install.deletingLastPathComponent().appendingPathComponent("elsewhere.cjs")
    try write("", to: elsewhere)
    try files.removeItem(at: install.appendingPathComponent("dist/b.cjs"))
    try files.createSymbolicLink(at: install.appendingPathComponent("dist/b.cjs"), withDestinationURL: elsewhere)
    #expect(ExtensionLayout.moveUp(install) == .leftAlone(.unknownItem))
    #expect(files.fileExists(atPath: install.appendingPathComponent("dist/a.cjs").path))
}

@Test func aCommandInBothPlacesIsNeverReplaced() throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory())
    try write("newer", to: install.appendingPathComponent("b.cjs"))
    #expect(ExtensionLayout.moveUp(install) == .leftAlone(.inBothPlaces))
    #expect(try String(contentsOf: install.appendingPathComponent("b.cjs"), encoding: .utf8) == "newer")
    #expect(files.fileExists(atPath: install.appendingPathComponent("dist/b.cjs").path))
    let installed = try InstalledExtension.load(from: install)
    #expect(installed.entry(for: "b") == install.appendingPathComponent("b.cjs"), "the root comes first")
}

@Test func aDistThatIsntAFolderIsLeftAlone() throws {
    let extensions = try Fixtures.temporaryDirectory()
    let install = try oldInstall(in: extensions)
    let real = extensions.appendingPathComponent("real-dist")
    try files.moveItem(at: install.appendingPathComponent("dist"), to: real)
    try files.createSymbolicLink(at: install.appendingPathComponent("dist"), withDestinationURL: real)
    #expect(ExtensionLayout.moveUp(install) == .leftAlone(.notAFolder))
    #expect(try names(in: real) == ["a.cjs", "b.cjs"])
}

@Test func aFolderThatIsntAFudgeBuildIsNeverTouched() throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory())
    try write("mine", to: install.appendingPathComponent("notes.txt"))
    #expect(ExtensionLayout.moveUp(install) == nil)
    #expect(try names(in: install.appendingPathComponent("dist")) == ["a.cjs", "b.cjs"])
}

@Test func theExtensionsFolderMovesEachInstallThatHasSomethingToMove() throws {
    let extensions = try Fixtures.temporaryDirectory()
    let old = try oldInstall(in: extensions, name: "old")
    let stray = try oldInstall(in: extensions, name: "stray")
    try write("", to: stray.appendingPathComponent("dist/notes.txt"))
    let new = extensions.appendingPathComponent("new")
    try write(#"{"name":"new","title":"New","commands":[]}"#, to: new.appendingPathComponent("package.json"))
    let staging = try oldInstall(in: extensions, name: ".staging-old-1")

    #expect(ExtensionLayout.moveUp(in: extensions) == ["old": .moved, "stray": .leftAlone(.unknownItem)])
    #expect(try names(in: old) == ["a.cjs", "assets", "b.cjs", "package.json"])
    #expect(
        files.fileExists(atPath: staging.appendingPathComponent("dist/a.cjs").path), "hidden folders are the build's")
    #expect(ExtensionLayout.moveUp(in: extensions) == ["stray": .leftAlone(.unknownItem)])
}

@Test func anEntryIsAtTheRootWhenItsInNeitherPlace() throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory())
    let installed = try InstalledExtension.load(from: install)
    #expect(installed.entry(for: "missing") == install.appendingPathComponent("missing.cjs"))
}

// MARK: - The install check

@Test func aBuildsRootMayHoldItsCommandsAndNothingElseNew() throws {
    let install = try oldInstall(in: try Fixtures.temporaryDirectory())
    #expect(ExtensionBuilder.holdsOnlyABuild(install), "the old layout")
    #expect(ExtensionLayout.moveUp(install) == .moved)
    #expect(ExtensionBuilder.holdsOnlyABuild(install), "the new layout")
    try write("", to: install.appendingPathComponent(".DS_Store"))
    #expect(ExtensionBuilder.holdsOnlyABuild(install))
    try write("", to: install.appendingPathComponent("c.cjs"))
    #expect(!ExtensionBuilder.holdsOnlyABuild(install), "a .cjs file the manifest doesn't name")
}

@Test func aCommandFileWithoutAManifestIsntABuild() throws {
    let folder = try Fixtures.temporaryDirectory().appendingPathComponent("x")
    try write("", to: folder.appendingPathComponent("a.cjs"))
    #expect(!ExtensionBuilder.holdsOnlyABuild(folder))
    #expect(ExtensionBuilder.holdsOnlyABuild(folder.appendingPathComponent("missing")), "nothing there")
}

// MARK: - Built and run through the host

/// Builds the `own-files` fixture, whose `read` command reads `${__dirname}/assets/services.json` and
/// `${__dirname}/package.json`, as the store's amazon-aws extension does, and whose `plain` command reads nothing.
@Suite(
    .enabled(
        if: Fixtures.canBuild && HostFixture.node != nil && HostFixture.runtimeInstalled,
        "needs esbuild and Fudge's Node.js: run `make test`"))
struct OwnFilesTests {
    static let source = Fixtures.directory.appendingPathComponent("own-files", isDirectory: true)
    let builder = Fixtures.builder()

    /// Runs `command` of `installed` through the host, as the app launches it, with the Greeting preference set to
    /// "hi", and returns what it logged, or its error.
    func run(_ command: String, of installed: InstalledExtension) async throws -> Result<[String], ExtensionError> {
        let host = try HostFixture.start()
        defer { host.stop() }
        var messages = host.messages.makeAsyncIterator()
        let declared = try #require(installed.manifest.commands.first { $0.name == command })
        let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
        try host.send(
            .launch(
                session: command, entry: installed.entry(for: command).path, mode: "no-view",
                launchProps: LaunchProps(), preferences: ["greeting": .string("hi")],
                environment: LaunchEnvironment.make(for: installed, command: declared, paths: paths, appearance: "dark")
            ))
        var logged: [String] = []
        while true {
            let message = try await next(&messages, timeout: .seconds(30)) { $0.session == command }
            switch message {
            case .log(_, _, let line, _): logged.append(line)
            case .error(_, let text, _, _, _): return .failure(ExtensionError(message: text))
            case .exit(_, let reason):
                return reason == "finished" ? .success(logged) : .failure(ExtensionError(message: reason))
            default: continue
            }
        }
    }

    struct ExtensionError: Error, Equatable { var message: String }

    @Test func aCommandReadsItsOwnFilesThroughDirname() async throws {
        let installed = try builder.build(source: Self.source, into: try Fixtures.temporaryDirectory())
        #expect(
            try names(in: installed.directory) == ["assets", "package.json", "plain.cjs", "read.cjs"],
            "no dist/, and nothing esbuild wrote besides the commands")
        #expect(try await run("read", of: installed) == .success(["own-files: s3, ec2; read.cjs"]))
    }

    @Test func anOldInstallLoadsMovesAndLaunches() async throws {
        let extensions = try Fixtures.temporaryDirectory()
        let built = try builder.build(source: Self.source, into: extensions)
        // As builds from before SPEC-123 installed it.
        let dist = built.directory.appendingPathComponent("dist")
        try files.createDirectory(at: dist, withIntermediateDirectories: false)
        for command in ["read", "plain"] {
            try files.moveItem(
                at: built.directory.appendingPathComponent("\(command).cjs"),
                to: dist.appendingPathComponent("\(command).cjs"))
        }
        #expect(InstalledExtension.all(in: extensions).map(\.manifest.name) == ["own-files"])
        // The bug: one folder down, `${__dirname}/assets` isn't there.
        guard case .failure(let error) = try await run("read", of: built) else {
            Issue.record("read its files from dist/")
            return
        }
        #expect(error.message.contains("ENOENT"), "\(error.message)")

        #expect(ExtensionLayout.moveUp(in: extensions) == ["own-files": .moved])
        let installed = try #require(InstalledExtension.all(in: extensions).first)
        #expect(try names(in: installed.directory) == ["assets", "package.json", "plain.cjs", "read.cjs"])
        #expect(try await run("read", of: installed) == .success(["own-files: s3, ec2; read.cjs"]))
        #expect(try await run("plain", of: installed) == .success(["plain ran: hi"]))
    }

    @Test func aMoveStoppedHalfwayStillLaunchesEveryCommand() async throws {
        let extensions = try Fixtures.temporaryDirectory()
        let built = try builder.build(source: Self.source, into: extensions)
        // Stopped after `read` moved: `plain` is still in dist/.
        let dist = built.directory.appendingPathComponent("dist")
        try files.createDirectory(at: dist, withIntermediateDirectories: false)
        try files.moveItem(
            at: built.directory.appendingPathComponent("plain.cjs"), to: dist.appendingPathComponent("plain.cjs"))

        let installed = try #require(InstalledExtension.all(in: extensions).first)
        #expect(installed.entry(for: "plain") == installed.directory.appendingPathComponent("dist/plain.cjs"))
        #expect(try await run("read", of: installed) == .success(["own-files: s3, ec2; read.cjs"]))
        #expect(try await run("plain", of: installed) == .success(["plain ran: hi"]))

        #expect(ExtensionLayout.moveUp(in: extensions) == ["own-files": .moved])
        #expect(try await run("plain", of: installed) == .success(["plain ran: hi"]))
        #expect(!files.fileExists(atPath: dist.path))
    }

    /// The deprecated `preferences` comes from the manifest the app names, so a command still in `dist/` gets it.
    @Test func anInstallWithSomethingElseInDistStillLaunches() async throws {
        let extensions = try Fixtures.temporaryDirectory()
        let built = try builder.build(source: Self.source, into: extensions)
        let dist = built.directory.appendingPathComponent("dist")
        try files.createDirectory(at: dist, withIntermediateDirectories: false)
        try files.moveItem(
            at: built.directory.appendingPathComponent("plain.cjs"), to: dist.appendingPathComponent("plain.cjs"))
        try write("", to: dist.appendingPathComponent("plain.cjs.map"))

        #expect(ExtensionLayout.moveUp(in: extensions) == ["own-files": .leftAlone(.unknownItem)])
        let installed = try #require(InstalledExtension.all(in: extensions).first)
        #expect(try await run("plain", of: installed) == .success(["plain ran: hi"]))
        #expect(try await run("read", of: installed) == .success(["own-files: s3, ec2; read.cjs"]))
    }

    @Test func onlyTheCommandsEsbuildWroteAreInstalled() throws {
        let source = try Fixtures.temporaryDirectory().appendingPathComponent("own-files")
        try files.copyItem(at: Self.source, to: source)
        // A stylesheet an import pulls in is an output of its own beside the command's.
        try write("body { color: red }", to: source.appendingPathComponent("src/style.css"))
        let plain = source.appendingPathComponent("src/plain.ts")
        try write("import \"./style.css\";\n" + String(contentsOf: plain, encoding: .utf8), to: plain)
        let extensions = try Fixtures.temporaryDirectory()

        let installed = try builder.build(source: source, into: extensions)
        #expect(try names(in: installed.directory) == ["assets", "package.json", "plain.cjs", "read.cjs"])
        try builder.build(source: source, into: extensions)
    }

    /// The commands an install may hold are the ones its own `package.json` names, not the next version's.
    @Test func anUpdateThatRenamesACommandReplacesTheInstall() throws {
        let extensions = try Fixtures.temporaryDirectory()
        try builder.build(source: Self.source, into: extensions)
        let source = try Fixtures.temporaryDirectory().appendingPathComponent("own-files")
        try files.copyItem(at: Self.source, to: source)
        let manifest = source.appendingPathComponent("package.json")
        try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: #""name": "plain""#, with: #""name": "simple""#)
            .write(to: manifest, atomically: true, encoding: .utf8)
        try files.moveItem(
            at: source.appendingPathComponent("src/plain.ts"), to: source.appendingPathComponent("src/simple.ts"))

        let updated = try builder.build(source: source, into: extensions)
        #expect(try names(in: updated.directory) == ["assets", "package.json", "read.cjs", "simple.cjs"])
    }

    @Test func aRebuildReplacesAnOldInstall() throws {
        let extensions = try Fixtures.temporaryDirectory()
        let built = try builder.build(source: Self.source, into: extensions)
        let dist = built.directory.appendingPathComponent("dist")
        try files.createDirectory(at: dist, withIntermediateDirectories: false)
        try files.moveItem(
            at: built.directory.appendingPathComponent("read.cjs"), to: dist.appendingPathComponent("read.cjs"))

        let rebuilt = try builder.build(source: Self.source, into: extensions)
        #expect(try names(in: rebuilt.directory) == ["assets", "package.json", "plain.cjs", "read.cjs"])
    }
}
