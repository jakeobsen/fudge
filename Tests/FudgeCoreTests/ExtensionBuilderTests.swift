import Foundation
import Testing

@testable import FudgeCore

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
        "Fixtures")
    static let greeter = directory.appendingPathComponent("greeter", isDirectory: true)
    /// Made up: an extension with a part written in Rust, as 12 of the store's have (SPEC-144).
    static let rustPart = directory.appendingPathComponent("rust-part", isDirectory: true)
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

    /// That Node.js with npm from its own distribution, as Fudge.app bundles them (`Runtime.locateNode`).
    static let bundledNode: BundledNode? = node.map {
        BundledNode(
            node: $0,
            npm: $0.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js"))
    }

    /// `fudge build`'s compile step as Fudge.app ships it (`bundle-extension.cjs`), made once for the run from
    /// `runtime/scripts/compile/` as `npm run build` makes it, so the tests build through the shipped file. Nil without
    /// Node.js or esbuild; a failure to make it is `bundlerProblem`, which a test reports.
    static let bundlerMade: (url: URL?, problem: String?) = {
        guard let node, esbuild != nil else { return (nil, nil) }
        do {
            let script = try temporaryDirectory().appendingPathComponent("bundle-extension.cjs")
            let maker = repository.appendingPathComponent("runtime/scripts/compile/make-bundler.ts")
            try Shell.run(node, [maker.path, script.path], in: repository.appendingPathComponent("runtime"))
            return (script, nil)
        } catch {
            return (nil, "\(error)")
        }
    }()
    static var bundler: URL? { bundlerMade.url }

    /// Whether extensions can be built here: esbuild, Fudge's Node.js and the compile step, which `make test` gives.
    static var canBuild: Bool { esbuild != nil && bundledNode != nil && bundler != nil }

    /// A builder as the `fudge` tool inside Fudge.app makes one.
    static func builder(
        log: @escaping @Sendable (String) -> Void = { _ in },
        scanCommands: (@Sendable (URL) throws -> CommandCompatibility)? = nil
    ) -> ExtensionBuilder {
        ExtensionBuilder(
            esbuild: esbuild ?? URL(fileURLWithPath: "/missing"), node: bundledNode, bundler: bundler, log: log,
            scanCommands: scanCommands)
    }

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

    /// What `fudge build` ran before SPEC-144: esbuild's command line with these flags, in the source folder, with
    /// installed dependencies in `NODE_PATH`. The compile step must write the same bytes.
    static func commandLine(entries: [URL], source: URL, output: URL) -> [String] {
        entries.map(\.path) + [
            "--bundle",
            "--platform=node",
            "--format=cjs",
            "--target=node22",
            "--jsx=automatic",
            "--outdir=\(output.path)",
            "--outbase=\(source.appendingPathComponent("src").path)",
            "--out-extension:.js=.cjs",
            "--define:process.env.NODE_ENV=\"production\"",
            "--legal-comments=none",
            "--log-level=warning",
        ] + ExtensionBuilder.providedModules.map { "--external:\($0)" }
    }

    /// Replaces the `"commands"` of the manifest in `source` with these, each a no-view command titled by its name.
    static func setCommands(_ names: [String], in source: URL) throws {
        let file = source.appendingPathComponent("package.json")
        var manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        manifest["commands"] = names.map { ["name": $0, "title": $0, "mode": "no-view"] }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
}

@Suite(.enabled(if: Fixtures.canBuild, "needs esbuild and Fudge's Node.js: run `make test`"))
struct ExtensionBuilderTests {
    let builder = Fixtures.builder()

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

    /// SPEC-144 §1: for an extension without `rust:` or `swift:` imports, the compile step writes what esbuild's
    /// command line wrote, byte for byte: the fixtures and the extensions Fudge.app bundles.
    @Test(
        arguments: [Fixtures.greeter, Fixtures.commandNames, Fixtures.directory.appendingPathComponent("own-files")]
            + BundledExtensions.folders.map { Fixtures.repository.appendingPathComponent("runtime/\($0)") })
    func compilesWhatTheCommandLineCompiled(source: URL) throws {
        let manifest = try ExtensionManifest.load(from: source.appendingPathComponent("package.json"))
        let installed = try builder.build(source: source, into: try Fixtures.temporaryDirectory())
        let output = try Fixtures.temporaryDirectory()
        let entries = try manifest.commands.map { try ExtensionBuilder.entry(for: $0.name, in: source) }
        try Shell.run(
            try #require(Fixtures.esbuild), Fixtures.commandLine(entries: entries, source: source, output: output),
            in: source)
        for command in manifest.commands {
            let file = ExtensionLayout.file(for: command.name)
            let built = try Data(contentsOf: installed.directory.appendingPathComponent(file))
            #expect(built == (try Data(contentsOf: output.appendingPathComponent(file))), "\(manifest.name)/\(file)")
        }
    }

    /// SPEC-144 R2: the dependencies a build installs reach esbuild through `nodePaths`, as they reached its command
    /// line through `NODE_PATH`; its JavaScript API doesn't read the variable. The dependency is made up and reachable
    /// only through that folder, and npm installs it from a folder of its own (`file:`), offline.
    @Test func installedDependenciesAreFoundAsTheCommandLineFoundThem() throws {
        let files = FileManager.default
        let scratch = try Fixtures.temporaryDirectory()
        defer { try? files.removeItem(at: scratch) }
        let dependency = scratch.appendingPathComponent("made-up-dependency", isDirectory: true)
        try files.createDirectory(at: dependency, withIntermediateDirectories: true)
        try #"{"name":"made-up-dependency","version":"1.0.0","main":"index.js"}"#.write(
            to: dependency.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "exports.shout = (text) => `${text.toUpperCase()}!`;\n".write(
            to: dependency.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let source = try Fixtures.greeterCopy()
        defer { try? files.removeItem(at: source.deletingLastPathComponent()) }
        let manifest = source.appendingPathComponent("package.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["dependencies"] = ["made-up-dependency": "file:\(dependency.path)"]
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        // npm reads the source's .npmrc (`installDependencies` copies it): no network, and a link to the folder.
        try "offline=true\nupdate-notifier=false\ninstall-links=false\n".write(
            to: source.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)
        try "import { shout } from \"made-up-dependency\";\nexport default async () => console.log(shout(\"hi\"));\n"
            .write(to: source.appendingPathComponent("src/quiet.ts"), atomically: true, encoding: .utf8)

        let installed = try builder.build(source: source, into: scratch.appendingPathComponent("extensions"))
        let built = try Data(contentsOf: installed.entry(for: "quiet"))
        #expect(String(decoding: built, as: UTF8.self).contains("toUpperCase"), "the dependency is bundled in")

        // The command line, with the folder npm makes in `NODE_PATH`.
        let modules = scratch.appendingPathComponent("dependencies/node_modules", isDirectory: true)
        try files.createDirectory(at: modules, withIntermediateDirectories: true)
        try files.createSymbolicLink(
            at: modules.appendingPathComponent("made-up-dependency"), withDestinationURL: dependency)
        let output = scratch.appendingPathComponent("command-line", isDirectory: true)
        let entries = try ["greet", "quiet"].map { try ExtensionBuilder.entry(for: $0, in: source) }
        try Shell.run(
            try #require(Fixtures.esbuild), Fixtures.commandLine(entries: entries, source: source, output: output),
            in: source, environment: ["NODE_PATH": modules.path])
        #expect(built == (try Data(contentsOf: output.appendingPathComponent("quiet.cjs"))))
    }

    /// What building `source` failed with in the compile step: its exit status, esbuild's output, and the message
    /// `fudge build` prints after `fudge: `. Records an issue when it built or failed some other way.
    func compileFailure(of source: URL) throws -> (status: Int32, output: String, message: String)? {
        do {
            try builder.build(source: source, into: try Fixtures.temporaryDirectory())
            Issue.record("it built")
        } catch let error as BuildError {
            if case .compileFailed(let status, let output) = error { return (status, output, "\(error)") }
            Issue.record("another failure: \(error)")
        }
        return nil
    }

    /// SPEC-144 N5: a failed compile says exactly what esbuild's command line said, and nothing on top of it. With
    /// more than 6 errors, that's the first 6 and how many there were (the command line's `--log-limit=6`).
    /// SPEC-147 A1: its first line names the compile step, never the request file in the build's scratch folder,
    /// which is gone by the time anyone reads it.
    @Test(arguments: [1, 10])
    func aFailedCompileSaysWhatTheCommandLineSaid(errors: Int) throws {
        let source = try Fixtures.greeterCopy()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let imports = (0..<errors).map { "import { missing\($0) } from \"./nowhere\($0 == 0 ? "" : "-\($0)")\";\n" }
        let uses = (0..<errors).map { "missing\($0)" }.joined(separator: ", ")
        try (imports.joined() + "export default function Command() { return [\(uses)]; }\n").write(
            to: source.appendingPathComponent("src/greet.tsx"), atomically: true, encoding: .utf8)
        let fromBuild = try #require(try compileFailure(of: source))
        let entries = try ["greet", "quiet"].map { try ExtensionBuilder.entry(for: $0, in: source) }
        let output = try Fixtures.temporaryDirectory()
        var fromCommandLine: String?
        do {
            try Shell.run(
                try #require(Fixtures.esbuild), Fixtures.commandLine(entries: entries, source: source, output: output),
                in: source)
        } catch let error as ShellError {
            fromCommandLine = error.output
        }
        let commandLine = try #require(fromCommandLine, "the command line built it")
        #expect(fromBuild.output.contains("✘ [ERROR] Could not resolve \"./nowhere\""), "\(fromBuild.output)")
        #expect(fromBuild.output.contains("6 of \(errors) errors shown") == (errors > 6), "\(fromBuild.output)")
        #expect(fromBuild.output == commandLine)
        #expect(
            fromBuild.message
                == "compiling the extension failed (exit 1):\n"
                + commandLine.trimmingCharacters(in: .whitespacesAndNewlines))
        // Only the first line is Fudge's: esbuild's own lines can name the scratch folder, for an error inside an
        // installed dependency, and are never rewritten.
        let firstLine = String(fromBuild.message.prefix { $0 != "\n" })
        for scratch in ["fudge-build-", "bundle-request.json", ExtensionBuilder.temporaryDirectory().path] {
            #expect(!firstLine.contains(scratch), "\(firstLine)")
        }
    }

    /// SPEC-144 §1: a build's warnings are the ones esbuild's command line printed, at most 6 and how many there were.
    @Test(arguments: [1, 9])
    func aBuildWarnsAsTheCommandLineWarned(warnings: Int) throws {
        let source = try Fixtures.greeterCopy()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        // esbuild warns about each duplicate key in an object literal, and builds anyway.
        let objects = (0..<warnings).map { "  { key\($0): 1, key\($0): 2 },\n" }.joined()
        try "export default function Command() {\n  return [\n\(objects)  ];\n}\n".write(
            to: source.appendingPathComponent("src/greet.tsx"), atomically: true, encoding: .utf8)
        let log = BuildLog()
        let builder = Fixtures.builder(log: { log.append($0) })
        try builder.build(source: source, into: try Fixtures.temporaryDirectory())
        let entries = try ["greet", "quiet"].map { try ExtensionBuilder.entry(for: $0, in: source) }
        let fromCommandLine = try Shell.run(
            try #require(Fixtures.esbuild),
            Fixtures.commandLine(entries: entries, source: source, output: try Fixtures.temporaryDirectory()),
            in: source
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(fromCommandLine.contains("▲ [WARNING] Duplicate key \"key0\" in object literal"), "\(fromCommandLine)")
        #expect(fromCommandLine.contains("6 of \(warnings) warnings shown") == (warnings > 6), "\(fromCommandLine)")
        #expect(log.lines.contains(fromCommandLine), "\(log.lines)")
    }

    /// SPEC-144: an extension with a Rust part installs as Raycast installs it on a Mac. Nothing of the Rust part goes
    /// into the install, and its functions refuse every call with Raycast's message (run in the runtime's tests).
    @Test func installsAnExtensionWithARustPart() throws {
        let extensions = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extensions) }
        let installed = try builder.build(source: Fixtures.rustPart, into: extensions)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: installed.directory.path).sorted() == [
                "direct.cjs", "on-windows.cjs", "package.json",
            ])
        for command in ["direct", "on-windows"] {
            let built = try String(contentsOf: installed.entry(for: command), encoding: .utf8)
            #expect(built.contains("Rust functions are not supported on macOS"), "\(command)")
            #expect(!built.contains("require(\"rust:"), "\(command)")
        }
    }

    /// SPEC-145 §2 (SPEC-144 §4 before it): a Swift part with no `--swift-parts` stops the build at the import, asking
    /// for one.
    @Test func aSwiftPartWithNoChoiceStopsTheBuildAtTheImport() throws {
        let source = try Fixtures.greeterCopy()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try "import { run } from \"swift:../swift\";\nexport default function Command() { return run; }\n".write(
            to: source.appendingPathComponent("src/greet.tsx"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("swift"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(
            to: source.appendingPathComponent("swift/Package.swift"), atomically: true, encoding: .utf8)
        let failure = try #require(try compileFailure(of: source))
        #expect(
            failure.output.contains(
                "✘ [ERROR] this extension has a part written in Swift: choose --swift-parts build or "
                    + "--swift-parts leave-out [plugin swift]"), "\(failure.output)")
        #expect(failure.output.contains("src/greet.tsx:1:20:"), "at the import")
    }

    @Test func reportsCompileErrors() throws {
        let source = try Fixtures.greeterCopy()
        try "export default function Command( {".write(
            to: source.appendingPathComponent("src/greet.tsx"),
            atomically: true,
            encoding: .utf8
        )
        let failure = try #require(try compileFailure(of: source))
        #expect(failure.message.hasPrefix("compiling the extension failed (exit 1):\n✘ [ERROR] "), "\(failure.message)")
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

/// The tests build through the compile step as shipped, made once for the run: making it mustn't fail.
@Test func theCompileStepIsMadeForTheTests() {
    #expect(Fixtures.bundlerMade.problem == nil, "\(Fixtures.bundlerMade.problem ?? "")")
}

@Test func locatesTheCompileStepFromTheEnvironmentOrInTheApp() throws {
    #expect(
        ExtensionBuilder.locateBundler(environment: ["FUDGE_BUNDLER": "/opt/bundle.cjs"], executable: nil)?.path
            == "/opt/bundle.cjs")
    let app = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: app) }
    let fudge = app.appendingPathComponent("Contents/Helpers/fudge")
    try FileManager.default.createDirectory(at: fudge.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n".write(to: fudge, atomically: true, encoding: .utf8)
    #expect(ExtensionBuilder.locateBundler(environment: [:], executable: fudge) == nil, "not in the app")
    let script = app.appendingPathComponent("Contents/Resources/runtime/bundle-extension.cjs")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "\n".write(to: script, atomically: true, encoding: .utf8)
    #expect(
        ExtensionBuilder.locateBundler(environment: [:], executable: fudge)?.path
            == script.resolvingSymlinksInPath().path)
    #expect(ExtensionBuilder.locateBundler(environment: [:], executable: nil) == nil)
}

/// SPEC-144 N3: every build runs Fudge's own Node.js and the compile step, so without either nothing is built, even
/// for an extension with no dependencies, and nothing is made in the extensions folder.
@Test func compilingWithoutFudgesNodeOrTheCompileStepIsAClearError() throws {
    let source = try Fixtures.greeterCopy()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    let missing = URL(fileURLWithPath: "/missing")
    let node = BundledNode(node: missing.appendingPathComponent("node"), npm: missing.appendingPathComponent("npm"))
    for builder in [
        ExtensionBuilder(esbuild: missing, node: nil, bundler: nil),
        ExtensionBuilder(esbuild: missing, node: node, bundler: nil),
        ExtensionBuilder(esbuild: missing, node: nil, bundler: missing.appendingPathComponent("bundle-extension.cjs")),
    ] {
        #expect(throws: BuildError.noBundler) { try builder.build(source: source, into: extensions) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: extensions.path) == [])
    #expect(
        BuildError.noBundler.description
            == "compiling needs Fudge's own Node.js and its bundling script, which aren't beside this fudge tool; "
            + "use the fudge inside Fudge.app")
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

/// The lines a build logs, from whichever thread logs them.
private final class BuildLog: @unchecked Sendable {
    // @unchecked: `stored` is behind `lock`.
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}
