import Foundation
import Testing

@testable import FudgeCore

extension InstalledExtension {
    /// A made-up install at the extensions folder's top level: Raycast's, keyed by its manifest name, as the loader
    /// keys one there.
    static func topLevel(
        manifest: ExtensionManifest, directory: URL, compatibility: CommandCompatibility = .init()
    ) -> InstalledExtension {
        guard let id = ExtensionID(stored: manifest.name) else { fatalError("Not a valid name: \(manifest.name)") }
        return InstalledExtension(
            manifest: manifest, directory: directory, id: id, repository: .raycast, compatibility: compatibility)
    }

    /// The install in `directory`, read as the loader reads one at the top level.
    static func topLevel(from directory: URL) throws -> InstalledExtension {
        try #require(try loadUnmoved(from: directory))
    }
}

private func manifest(_ name: String, title: String) throws -> ExtensionManifest {
    try JSONDecoder().decode(ExtensionManifest.self, from: Data(#"{"name":"\#(name)","title":"\#(title)"}"#.utf8))
}

private func install(_ name: String, title: String = "GitHub", in folder: String) throws -> InstalledExtension {
    let repository = try #require(InstalledExtension.Repository(folder: folder))
    return InstalledExtension(
        manifest: try manifest(name, title: title),
        directory: URL(fileURLWithPath: "/nonexistent/\(folder)/\(name)"),
        id: try #require(ExtensionID(name: name, repositoryFolder: folder)),
        repository: repository)
}

@Test func aRepositoryIsKnownByItsFolder() {
    #expect(InstalledExtension.Repository(folder: "raycast/extensions") == .raycast)
    #expect(InstalledExtension.Repository(folder: "fudgeapp/development") == .development)
    #expect(InstalledExtension.Repository(folder: "fudgeapp/tools") == .added("fudgeapp/tools"))
    #expect(InstalledExtension.Repository(folder: "someone/tools") == .added("someone/tools"))
    #expect(
        InstalledExtension.Repository(folder: "git.example.org_8443/team/extensions")
            == .added("git.example.org_8443/team/extensions"))
    for folder in ["", "development", "Someone/tools", "../x", "someone/tools/extra"] {
        #expect(InstalledExtension.Repository(folder: folder) == nil, "\(folder)")
    }
    for repository in [InstalledExtension.Repository.raycast, .development, .added("someone/tools")] {
        #expect(repository.folder.flatMap(InstalledExtension.Repository.init(folder:)) == repository)
    }
    #expect(InstalledExtension.Repository.bundled.folder == nil)
}

@Test func theIndexKeepsTwoInstallsOfOneNameApartAndTheFirstOfOneId() throws {
    let raycast = try install("github", in: "raycast/extensions")
    let added = try install("github", in: "someone/tools")
    let development = try install("github", in: "fudgeapp/development")
    let index = InstalledExtension.index([raycast, added, development])
    #expect(index.count == 3)
    #expect(index[try #require(ExtensionID(stored: "github"))] == raycast)
    #expect(index[try #require(ExtensionID(stored: "someone+tools+github"))] == added)
    #expect(index[try #require(ExtensionID(stored: "fudgeapp+development+github"))] == development)

    let again = try install("github", title: "Another GitHub", in: "someone/tools")
    let first = InstalledExtension.index([added, again])
    #expect(first.count == 1)
    #expect(first[added.id]?.manifest.title == "GitHub")
}

@Test func anInstallAtTheTopLevelIsRaycastsUnderItsName() throws {
    let extensions = try Fixtures.temporaryDirectory()
    try FileManager.default.copyItem(at: Fixtures.greeter, to: extensions.appendingPathComponent("greeter"))
    let found = try #require(InstalledExtension.all(in: extensions).first)
    #expect(found.id.key == "greeter")
    #expect(found.repository == .raycast)
    #expect(ExtensionTitles.forTests([found]).title(of: found) == found.manifest.title)
}

@Test func anInstallWhoseNameTheIdRuleRefusesIsSkipped() throws {
    let extensions = try Fixtures.temporaryDirectory()
    let folder = extensions.appendingPathComponent("odd")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"name":"Odd Name","title":"Odd","commands":[]}"#.utf8).write(
        to: folder.appendingPathComponent("package.json"))
    #expect(InstalledExtension.all(in: extensions).isEmpty)
}

/// Each bundled extension's id is a constant, which must be the name its manifest in `runtime/<folder>` has.
@Test func eachBundledExtensionsIdIsItsManifestsName() throws {
    #expect(BundledExtensions.folders.count == 4)
    for folder in BundledExtensions.folders {
        let manifest = try ExtensionManifest.load(
            from: Fixtures.repository.appendingPathComponent("runtime/\(folder)/package.json"))
        #expect(BundledExtensions.id(ofFolder: folder)?.key == manifest.name, "\(folder)")
    }
    #expect(BundledExtensions.id(ofFolder: "nope") == nil)
    #expect(
        [ExtensionStore.id, FileSearch.id, BundledExtensions.emojiID, ClipboardHistory.id].map(\.key) == [
            ExtensionStore.extensionName, FileSearch.extensionName, "fudge-emoji", ClipboardHistory.extensionName,
        ])
}

@Test func theBundledExtensionsLoadWithTheirIdsAsBundled() throws {
    let resources = Fixtures.repository.appendingPathComponent("runtime")
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let bundled = InstalledExtension.all(paths: paths, resources: resources).filter { $0.repository == .bundled }
    #expect(
        Set(bundled.map(\.id))
            == [ExtensionStore.id, FileSearch.id, BundledExtensions.emojiID, ClipboardHistory.id])
    for installed in bundled { #expect(installed.id.key == installed.manifest.name) }
}
