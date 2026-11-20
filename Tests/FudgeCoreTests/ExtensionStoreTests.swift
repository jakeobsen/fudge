import Foundation
import Testing

@testable import FudgeCore

@Test func theStoreIsOnOnlyWithItsConsentDate() throws {
    let folder = try Fixtures.temporaryDirectory()
    let file = folder.appendingPathComponent("settings.json")
    try Data(#"{ "theme": "dark", "extensionStore": true }"#.utf8).write(to: file)
    #expect(!FudgeSettings.load(from: file).isExtensionStoreOn, "set by hand, without the sheet's date")
    try Data(#"{ "extensionStore": true, "extensionStoreConsentAt": "soon" }"#.utf8).write(to: file)
    #expect(!FudgeSettings.load(from: file).isExtensionStoreOn, "a date that isn't one")
    try Data(#"{ "theme": "dark" }"#.utf8).write(to: file)

    var settings = FudgeSettings.load(from: file)
    settings.extensionStore = true
    settings.extensionStoreConsentAt = "2026-11-20T22:30:00Z"
    try settings.save(to: file)
    #expect(FudgeSettings.load(from: file).isExtensionStoreOn)
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["extensionStore"] as? Bool == true)
    #expect(object["extensionStoreConsentAt"] as? String == "2026-11-20T22:30:00Z")
    #expect(object["theme"] as? String == "dark", "a key fudge doesn't know is kept")

    settings.extensionStore = false
    settings.extensionStoreConsentAt = nil
    try settings.save(to: file)
    object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["extensionStore"] == nil && object["extensionStoreConsentAt"] == nil, "off removes both keys")
    #expect(object["theme"] as? String == "dark")
}

/// A resources folder holding a bundled store, and a support folder with one extension of the user's.
private func storeFixture() throws -> (paths: FudgePaths, resources: URL) {
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let resources = try Fixtures.temporaryDirectory()
    func write(_ name: String, title: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest =
            #"{ "name": "\#(name)", "title": "\#(title)", "commands": [ { "name": "main", "title": "\#(title)", "mode": "view" } ] }"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("package.json"))
    }
    try write(
        ExtensionStore.extensionName, title: "Extension Store", in: resources.appendingPathComponent("store-extension"))
    try write("weather", title: "Weather", in: paths.extensionsDirectory.appendingPathComponent("weather"))
    return (paths, resources)
}

@Test func theBundledStoreIsListedOnlyWhileItsOn() throws {
    let (paths, resources) = try storeFixture()
    #expect(ExtensionStore.bundledDirectory(resources: resources) != nil)
    #expect(ExtensionStore.bundledDirectory(resources: paths.supportDirectory) == nil, "no store in that folder")
    #expect(ExtensionStore.bundledDirectory(resources: nil) == nil)

    var settings = FudgeSettings()
    #expect(
        InstalledExtension.all(paths: paths, settings: settings, resources: resources).map(\.manifest.title) == [
            "Weather"
        ])
    settings.extensionStore = true
    #expect(
        InstalledExtension.all(paths: paths, settings: settings, resources: resources).map(\.manifest.title) == [
            "Weather"
        ],
        "switched on by hand, without consent")
    settings.extensionStoreConsentAt = "2026-11-20T22:30:00Z"
    #expect(
        InstalledExtension.all(paths: paths, settings: settings, resources: resources).map(\.manifest.title)
            == ["Extension Store", "Weather"])
    #expect(
        InstalledExtension.all(paths: paths, settings: settings, resources: nil).map(\.manifest.title) == ["Weather"],
        "an app without a bundled store")
}

@Test func turningTheStoreOffDeletesOnlyItsDownloadedRepository() throws {
    let (paths, _) = try storeFixture()
    let repository = ExtensionStore.repositoryDirectory(paths)
    try FileManager.default.createDirectory(
        at: repository.appendingPathComponent("extensions"), withIntermediateDirectories: true)
    let installed = repository.deletingLastPathComponent().appendingPathComponent("installed.json")
    try Data("{}".utf8).write(to: installed)
    try ExtensionStore.deleteRepository(paths)
    #expect(!FileManager.default.fileExists(atPath: repository.path))
    #expect(FileManager.default.fileExists(atPath: installed.path), "the store keeps its record of what it installed")
    #expect(FileManager.default.fileExists(atPath: paths.extensionsDirectory.appendingPathComponent("weather").path))
    try ExtensionStore.deleteRepository(paths)  // nothing left to delete is fine
}

@Test func theHostTellsTheStoreWhereTheToolAndTheExtensionsFolderAre() {
    let paths = FudgePaths(supportDirectory: URL(fileURLWithPath: "/tmp/support"))
    let environment = ExtensionStore.hostEnvironment(
        cli: URL(fileURLWithPath: "/A/Fudge.app/Contents/Helpers/fudge"), paths: paths)
    #expect(environment["FUDGE_CLI"] == "/A/Fudge.app/Contents/Helpers/fudge")
    #expect(environment["FUDGE_EXTENSIONS_DIR"] == "/tmp/support/extensions")
    #expect(ExtensionStore.hostEnvironment(cli: nil, paths: paths)["FUDGE_CLI"] == nil, "no tool, so the store says so")
}

@Test func theConsentSheetIsBriefAndLinksToTheIssues() {
    #expect(ExtensionStore.Consent.title == "Turn on the Extension Store?")
    #expect(
        ExtensionStore.Consent.message
            == "This adds the Extension Store to fudge. It downloads extensions from Raycast's open-source extensions "
            + "repository on GitHub.")
    #expect(
        ExtensionStore.Consent.note
            == "fudge aims to run Raycast extensions, but not all of them work yet. If you find one that doesn't, "
            + "please file an issue.")
    #expect(ExtensionStore.Consent.note.contains(ExtensionStore.Consent.issueLinkText), "the link is in the text")
    #expect(ExtensionStore.Consent.issuesURL.absoluteString == "https://github.com/jakeobsen/fudge/issues")
    #expect(ExtensionStore.Consent.confirm == "Turn On")
    #expect(ExtensionStore.Consent.cancel == "Cancel")
}
