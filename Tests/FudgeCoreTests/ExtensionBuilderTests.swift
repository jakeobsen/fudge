import Foundation
import Testing

@testable import FudgeCore

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
        "Fixtures")
    static let greeter = directory.appendingPathComponent("greeter", isDirectory: true)
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

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A copy of the greeter fixture that a test may change.
    static func greeterCopy() throws -> URL {
        let copy = try temporaryDirectory().appendingPathComponent("greeter")
        try FileManager.default.copyItem(at: greeter, to: copy)
        return copy
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
