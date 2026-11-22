import Foundation
import Testing

@testable import FudgeCore

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
        "Fixtures")
    static let greeter = directory.appendingPathComponent("greeter", isDirectory: true)
    /// Made up: a camel-case command and a dotted one, as Raycast accepts them.
    static let commandNames = directory.appendingPathComponent("command-names", isDirectory: true)
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The esbuild binary that `make` installs for the extension host, if it's there.
    static let esbuild: URL? = {
        let packages = repository.appendingPathComponent("runtime/node_modules/@esbuild")
        let platforms = (try? FileManager.default.contentsOfDirectory(atPath: packages.path)) ?? []
        return platforms.lazy
            .map { packages.appendingPathComponent($0).appendingPathComponent("bin/esbuild") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// The Node.js Fudge bundles, which `make test` downloads, checks and hands the tests (`FUDGE_TEST_NODE`). Only
    /// the tests read that variable: the app and the tool find Node.js beside themselves (`Runtime.locateNode`).
    static let node: URL? = ProcessInfo.processInfo.environment["FUDGE_TEST_NODE"]
        .map(URL.init(fileURLWithPath:))
        .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A copy of the greeter fixture that a test may change.
    static func greeterCopy() throws -> URL {
        try copy(of: greeter)
    }

    /// A copy of a fixture that a test may change.
    static func copy(of fixture: URL) throws -> URL {
        let copy = try temporaryDirectory().appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }

    /// Whether the temporary folder's disk ignores case, as the Mac's does by default.
    static let temporaryDiskIgnoresCase: Bool = {
        guard let folder = try? temporaryDirectory() else { return false }
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = FileManager.default.createFile(atPath: folder.appendingPathComponent("Case").path, contents: nil)
        return written && FileManager.default.fileExists(atPath: folder.appendingPathComponent("case").path)
    }()

    /// Replaces the `"commands"` of the manifest in `source` with these, each a no-view command titled by its name.
    static func setCommands(_ names: [String], in source: URL) throws {
        let file = source.appendingPathComponent("package.json")
        var manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        manifest["commands"] = names.map { ["name": $0, "title": $0, "mode": "no-view"] }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
}

@Suite(.enabled(if: Fixtures.esbuild != nil, "needs esbuild: run `make test`, which installs it"))
struct ExtensionBuilderTests {
    let builder = ExtensionBuilder(esbuild: Fixtures.esbuild ?? URL(fileURLWithPath: "/missing"))

    @Test func compilesEveryCommandAndInstallsManifestAndAssets() throws {
        let extensions = try Fixtures.temporaryDirectory()
        let installed = try builder.build(source: Fixtures.greeter, into: extensions)

        #expect(installed.directory == extensions.appendingPathComponent("greeter", isDirectory: true))
        #expect(installed.manifest.name == "greeter")
        // Each command beside the manifest and assets, as Raycast installs it (SPEC-123).
        #expect(installed.entry(for: "greet") == installed.directory.appendingPathComponent("greet.cjs"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: installed.directory.path).sorted() == [
                "assets", "greet.cjs", "package.json", "quiet.cjs",
            ])
        let greet = try String(contentsOf: installed.entry(for: "greet"), encoding: .utf8)
        #expect(greet.contains("require(\"@raycast/api\")"))
        #expect(greet.contains("require(\"react/jsx-runtime\")"))
        #expect(greet.contains("hello, "), "local modules are bundled in")
        #expect(!greet.contains("react.production"), "React itself stays out of the bundle")
        #expect(FileManager.default.fileExists(atPath: installed.entry(for: "quiet").path))
        #expect(
            FileManager.default.fileExists(atPath: installed.assetsDirectory.appendingPathComponent("icon.png").path))
        #expect(try InstalledExtension.load(from: installed.directory) == installed)
    }

    @Test func neverWritesIntoTheSourceFolder() throws {
        let source = try Fixtures.greeterCopy()
        let before = try FileManager.default.subpathsOfDirectory(atPath: source.path).sorted()
        try builder.build(source: source, into: try Fixtures.temporaryDirectory())
        #expect(try FileManager.default.subpathsOfDirectory(atPath: source.path).sorted() == before)
    }

    @Test func rebuildingReplacesTheInstalledCopy() throws {
        let source = try Fixtures.greeterCopy()
        let extensions = try Fixtures.temporaryDirectory()
        let first = try builder.build(source: source, into: extensions)
        try FileManager.default.removeItem(at: source.appendingPathComponent("assets"))
        let second = try builder.build(source: source, into: extensions)

        #expect(second.directory == first.directory)
        #expect(!FileManager.default.fileExists(atPath: second.assetsDirectory.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: extensions.path)
        #expect(leftovers == ["greeter"], "no staging or old copies are left behind")
    }

    @Test func listsInstalledExtensions() throws {
        let extensions = try Fixtures.temporaryDirectory()
        try builder.build(source: Fixtures.greeter, into: extensions)
        try FileManager.default.createDirectory(
            at: extensions.appendingPathComponent("not-an-extension"),
            withIntermediateDirectories: true
        )
        #expect(InstalledExtension.all(in: extensions).map(\.manifest.name) == ["greeter"])
    }

    @Test func reportsACommandWithoutSource() throws {
        let source = try Fixtures.greeterCopy()
        try FileManager.default.removeItem(at: source.appendingPathComponent("src/quiet.ts"))
        #expect(
            throws: BuildError.missingEntry(
                command: "quiet",
                searched: [
                    "src/quiet.tsx", "src/quiet.ts", "src/quiet.jsx", "src/quiet.js",
                ])
        ) {
            try builder.build(source: source, into: try Fixtures.temporaryDirectory())
        }
    }

    @Test func rejectsANameThatIsntKebabCase() throws {
        let source = try Fixtures.greeterCopy()
        let manifest = source.appendingPathComponent("package.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        try text.replacingOccurrences(of: #""name": "greeter""#, with: #""name": "../greeter""#)
            .write(to: manifest, atomically: true, encoding: .utf8)
        #expect(throws: BuildError.invalidName("../greeter")) {
            try builder.build(source: source, into: try Fixtures.temporaryDirectory())
        }
    }

    /// SPEC-143: Raycast accepts command names with capitals and dots (`caffeinateWhile`), and each built file keeps
    /// the name's case.
    @Test func buildsCommandsNamedAsRaycastAcceptsThem() throws {
        let extensions = try Fixtures.temporaryDirectory()
        let installed = try builder.build(source: Fixtures.commandNames, into: extensions)

        #expect(installed.manifest.commands.map(\.name) == ["stayAwake", "show-recent.command"])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: installed.directory.path).sorted() == [
                "package.json", "show-recent.command.cjs", "stayAwake.cjs",
            ])
        #expect(installed.entry(for: "stayAwake") == installed.directory.appendingPathComponent("stayAwake.cjs"))
        let detail = try String(contentsOf: installed.entry(for: "show-recent.command"), encoding: .utf8)
        #expect(detail.contains("recent"))
        #expect(try InstalledExtension.load(from: installed.directory) == installed)

        // A second build replaces the install (`holdsOnlyABuild` knows the files by the names).
        let again = try builder.build(source: Fixtures.commandNames, into: extensions)
        #expect(again.directory == installed.directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: extensions.path) == ["command-names"])
    }

    /// The entry file is found as the disk finds it, so on the Mac's usual disk `fooBar`'s may be `src/FooBar.ts`, as
    /// some store extensions have it, and the built file still has the name's case.
    @Test(.enabled(if: Fixtures.temporaryDiskIgnoresCase, "needs a disk that ignores case"))
    func aCommandsFileMayDifferFromItsNameInCase() throws {
        let source = try Fixtures.copy(of: Fixtures.commandNames)
        try Fixtures.setCommands(["fooBar"], in: source)
        try "export default async function Command() {}\n".write(
            to: source.appendingPathComponent("src/FooBar.ts"), atomically: true, encoding: .utf8)
        let extensions = try Fixtures.temporaryDirectory()

        let installed = try builder.build(source: source, into: extensions)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: installed.directory.path).sorted() == [
                "fooBar.cjs", "package.json",
            ])
        let again = try builder.build(source: source, into: extensions)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: again.directory.path).sorted() == [
                "fooBar.cjs", "package.json",
            ])
        #expect(try FileManager.default.contentsOfDirectory(atPath: extensions.path) == ["command-names"])
    }

    /// Their built files would be one file on a disk that ignores case.
    @Test func refusesCommandNamesThatDifferOnlyInCase() throws {
        let source = try Fixtures.copy(of: Fixtures.commandNames)
        try Fixtures.setCommands(["stayAwake", "show-recent.command", "StayAwake"], in: source)
        #expect(throws: BuildError.commandNamesDifferOnlyInCase("stayAwake", "StayAwake")) {
            try builder.build(source: source, into: try Fixtures.temporaryDirectory())
        }
        #expect(
            BuildError.commandNamesDifferOnlyInCase("stayAwake", "StayAwake").description
                == "the command names \"stayAwake\" and \"StayAwake\" differ only in case, so their built files "
                + "would be one file")
    }

    @Test func refusesACommandNameThatCouldReachOutsideItsFolder() throws {
        for name in ["../stayAwake", ".hidden", "a b", "stay/awake", ":group"] {
            let source = try Fixtures.copy(of: Fixtures.commandNames)
            try Fixtures.setCommands([name], in: source)
            #expect(throws: BuildError.invalidCommandName(name), "\(name)") {
                try builder.build(source: source, into: try Fixtures.temporaryDirectory())
            }
        }
        #expect(
            BuildError.invalidCommandName("a b").description
                == "the command name \"a b\" may use only letters, digits, ., - and _, starting with a letter or digit")
    }

    @Test func reportsCompileErrors() throws {
        let source = try Fixtures.greeterCopy()
        try "export default function Command( {".write(
            to: source.appendingPathComponent("src/greet.tsx"),
            atomically: true,
            encoding: .utf8
        )
        #expect(throws: ShellError.self) {
            try builder.build(source: source, into: try Fixtures.temporaryDirectory())
        }
    }
}

@Test func locatesEsbuildFromTheEnvironmentNextToTheExecutableOrOnThePath() throws {
    #expect(
        ExtensionBuilder.locateEsbuild(environment: ["FUDGE_ESBUILD": "/opt/esbuild"], executable: nil)?.path
            == "/opt/esbuild")

    let helpers = try Fixtures.temporaryDirectory()
    let esbuild = helpers.appendingPathComponent("esbuild")
    try "#!/bin/sh\n".write(to: esbuild, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: esbuild.path)
    let fudge = helpers.appendingPathComponent("fudge")
    #expect(ExtensionBuilder.locateEsbuild(environment: [:], executable: fudge) == esbuild)
    #expect(
        ExtensionBuilder.locateEsbuild(environment: ["PATH": "/nonexistent:\(helpers.path)"], executable: nil)
            == esbuild)
    #expect(ExtensionBuilder.locateEsbuild(environment: ["PATH": "/nonexistent"], executable: nil) == nil)
}

@Test func theBuildsScratchFolderGoesInAnAbsoluteTMPDIR() {
    #expect(ExtensionBuilder.temporaryDirectory(environment: ["TMPDIR": "/tmp/x/"]).path == "/tmp/x")
    let usual = FileManager.default.temporaryDirectory
    #expect(ExtensionBuilder.temporaryDirectory(environment: [:]) == usual)
    #expect(ExtensionBuilder.temporaryDirectory(environment: ["TMPDIR": ""]) == usual)
    #expect(ExtensionBuilder.temporaryDirectory(environment: ["TMPDIR": "relative/tmp"]) == usual)
}

@Test func dependenciesWithoutFudgesNodeAreAClearError() throws {
    // npm is Fudge's own, beside the tool; with none there, an extension with dependencies can't build.
    let source = try Fixtures.greeterCopy()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let manifest = source.appendingPathComponent("package.json")
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    object["dependencies"] = ["left-pad": "1.3.0"]
    try JSONSerialization.data(withJSONObject: object).write(to: manifest)
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    let builder = ExtensionBuilder(esbuild: URL(fileURLWithPath: "/missing"), node: nil)
    #expect(throws: BuildError.noNode) { try builder.build(source: source, into: extensions) }
    #expect("\(BuildError.noNode)".contains("use the fudge inside Fudge.app"))
}
