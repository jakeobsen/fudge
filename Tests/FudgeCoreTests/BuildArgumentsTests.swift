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

@Test(arguments: [
    ([], "usage"),
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

@Suite(.enabled(if: Fixtures.esbuild != nil, "needs esbuild: run `make test`, which installs it"))
struct BuildIntoTests {
    @Test func buildIntoInstallsThereAndNowhereElse() throws {
        let into = try Fixtures.temporaryDirectory()
        let support = try Fixtures.temporaryDirectory()
        let defaultFolder = FudgePaths.standard(environment: ["FUDGE_SUPPORT_DIR": support.path]).extensionsDirectory
        let arguments = try BuildArguments.parse([Fixtures.greeter.path, "--into", into.path])
        let builder = ExtensionBuilder(esbuild: Fixtures.esbuild ?? URL(fileURLWithPath: "/missing"))
        let installed = try builder.build(
            source: arguments.source, into: arguments.destination ?? defaultFolder)
        #expect(installed.directory.deletingLastPathComponent().standardizedFileURL == into.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: defaultFolder.path), "the default folder is untouched")
    }
}
