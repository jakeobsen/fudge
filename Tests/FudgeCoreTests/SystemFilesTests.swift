import Foundation
import Testing

@testable import FudgeCore

// Only the failure is tested: trashing for real would fill the user's Trash on every run.
@Test func trashingAMissingFileFails() throws {
    let folder = try Fixtures.temporaryDirectory()
    #expect(throws: (any Error).self) { try SystemFiles.trash([folder.appendingPathComponent("missing").path]) }
}

@Test func tellsURLsFromFilePaths() {
    #expect(SystemFiles.url(for: "https://example.com/a").absoluteString == "https://example.com/a")
    #expect(SystemFiles.url(for: "vscode://file/x").scheme == "vscode")
    #expect(SystemFiles.url(for: "/tmp/a b").path == "/tmp/a b")
    #expect(
        SystemFiles.url(for: "~/x").path
            == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("x").path)
}

@Test func findsApplicationsForAFile() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("note.txt")
    try Data("x".utf8).write(to: file)
    let apps = SystemFiles.applications(forOpening: file.path)
    #expect(!apps.isEmpty, "something on every Mac opens text files")
    #expect(SystemFiles.defaultApplication(forOpening: file.path) != nil)
}

@Test func buildsTheLaunchEnvironment() throws {
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let manifest = try ExtensionManifest.load(from: Fixtures.greeter.appendingPathComponent("package.json"))
    let installed = InstalledExtension(manifest: manifest, directory: URL(fileURLWithPath: "/ext/greeter"))
    let environment = LaunchEnvironment.make(
        for: installed, command: manifest.commands[0], paths: paths, appearance: "dark")
    #expect(environment.extensionName == "greeter")
    #expect(environment.commandName == "greet")
    #expect(environment.commandMode == "view")
    #expect(environment.assetsPath == "/ext/greeter/assets")
    #expect(environment.manifestPath == "/ext/greeter/package.json")
    #expect(environment.supportPath == paths.supportDirectory.appendingPathComponent("extension-data/greeter").path)
    #expect(FileManager.default.fileExists(atPath: environment.supportPath), "the support folder is created")
    #expect(environment.localStoragePath.hasSuffix("local-storage/greeter.json"))
    #expect(environment.cachePath.hasSuffix("cache/greeter"))
}

@Test func readsTheOwnerOrAuthor() throws {
    let decode = { (json: String) in try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)) }
    #expect(try decode(#"{ "name": "x", "owner": "acme", "author": "me" }"#).ownerOrAuthorName == "acme")
    #expect(try decode(#"{ "name": "x", "author": "me" }"#).ownerOrAuthorName == "me")
    #expect(try decode(#"{ "name": "x" }"#).ownerOrAuthorName == "")
}
