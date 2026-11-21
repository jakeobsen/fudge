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

@Test func theBundledStoreIsAlwaysListedAndHasASettingsPage() throws {
    let (paths, resources) = try storeFixture()
    #expect(ExtensionStore.bundledDirectory(resources: resources) != nil)
    #expect(ExtensionStore.bundledDirectory(resources: paths.supportDirectory) == nil, "no store in that folder")
    #expect(ExtensionStore.bundledDirectory(resources: nil) == nil)

    let installed = InstalledExtension.all(paths: paths, resources: resources)
    #expect(installed.map(\.manifest.title) == ["Extension Store", "Weather"], "on the Commands page, enabled or not")
    #expect(
        InstalledExtension.all(paths: paths, resources: nil).map(\.manifest.title) == ["Weather"],
        "an app without a bundled store")
    #expect(
        InstalledExtension.settingsPages(of: installed).map(\.manifest.title) == ["Extension Store"],
        "the store's page holds its switch; Weather has no preferences")

    // A user's extension can't take the store's name.
    let impostor = paths.extensionsDirectory.appendingPathComponent("impostor")
    try FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: true)
    try Data(
        #"{ "name": "\#(ExtensionStore.extensionName)", "title": "Impostor", "commands": [] }"#.utf8
    ).write(to: impostor.appendingPathComponent("package.json"))
    #expect(
        InstalledExtension.all(paths: paths, resources: resources).map(\.manifest.title) == [
            "Extension Store", "Weather",
        ])
}

@Test func theStoreIsDisabledByDefaultAndEveryOtherExtensionEnabled() throws {
    let store = ExtensionStore.extensionName
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    #expect(!settings.isEnabled(extension: store))
    #expect(!settings.isEnabled(extension: store, command: "main"), "so it's not in root search or launchCommand")
    #expect(settings.isEnabled(extension: "weather") && settings.isEnabled(extension: "weather", command: "main"))
    settings.commands["\(store)/main"] = .init(hotkey: "option+e")
    #expect(settings.availableHotkeys(installed: ["\(store)/main"]).isEmpty, "its hotkey isn't registered either")

    settings.setEnabled(true, extension: store)
    settings.setEnabled(true, extension: "weather")
    try settings.save(to: file)
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let extensions = try #require(object["extensions"] as? [String: Any])
    #expect((extensions[store] as? [String: Any])?["enabled"] as? Bool == true, "the store's is written when on")
    #expect(extensions["weather"] == nil, "enabled is the default for every other extension")
    #expect(FudgeSettings.load(from: file).isEnabled(extension: store, command: "main"))
    #expect(FudgeSettings.load(from: file).availableHotkeys(installed: ["\(store)/main"]).count == 1)

    settings.setEnabled(false, extension: store)
    settings.setEnabled(false, extension: "weather")
    try settings.save(to: file)
    object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(((object["extensions"] as? [String: Any])?[store] as? [String: Any])?["enabled"] as? Bool == false)
    let loaded = FudgeSettings.load(from: file)
    #expect(!loaded.isEnabled(extension: store) && !loaded.isEnabled(extension: "weather"))
}

@Test func anInstallWithTheStoreAlreadyOnStartsWithItEnabled() throws {
    let store = ExtensionStore.extensionName
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(#"{ "extensionStore": true, "extensionStoreConsentAt": "2026-11-20T22:30:00Z" }"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file).isEnabled(extension: store), "nothing that worked disappears")
    try Data(#"{ "extensionStore": true }"#.utf8).write(to: file)
    #expect(!FudgeSettings.load(from: file).isEnabled(extension: store), "a hand-set true is off")
    try Data(
        #"{ "extensionStore": true, "extensionStoreConsentAt": "2026-11-20T22:30:00Z", "extensions": { "\#(store)": { "enabled": false } } }"#
            .utf8
    ).write(to: file)
    #expect(!FudgeSettings.load(from: file).isEnabled(extension: store), "disabled on the Commands page since")
}

@Test func theSwitchLeavesTheStoresEnabledAsItIs() throws {
    let store = ExtensionStore.extensionName
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-21T08:00:00Z"))

    // An install from before, which took Enabled from the switch, stays enabled when the switch goes off.
    var settings = FudgeSettings()
    settings.extensionStore = true
    settings.extensionStoreConsentAt = "2026-11-20T22:30:00Z"
    settings.setExtensionStore(false, now: now)
    #expect(!settings.isExtensionStoreOn && settings.extensionStoreConsentAt == nil)
    #expect(settings.isEnabled(extension: store))

    // A new install: turning the switch on doesn't enable the store.
    settings = FudgeSettings()
    settings.setExtensionStore(true, now: now)
    #expect(settings.isExtensionStoreOn && settings.extensionStoreConsentAt == "2026-11-21T08:00:00Z")
    #expect(!settings.isEnabled(extension: store))

    // Enabled, then switched on and off again.
    settings.setEnabled(true, extension: store)
    settings.setExtensionStore(false, now: now)
    #expect(settings.isEnabled(extension: store))
    settings.setExtensionStore(true, now: now)
    #expect(settings.isEnabled(extension: store))
}

@Test func theStoresOffViewIsChosenWhileItsOff() {
    let store = ExtensionStore.extensionName
    var settings = FudgeSettings()
    #expect(ExtensionStore.isOff(store, settings: settings))
    #expect(!ExtensionStore.isOff("weather", settings: settings), "only the store")
    settings.extensionStore = true
    #expect(ExtensionStore.isOff(store, settings: settings), "a hand-set true counts as off")
    settings.extensionStoreConsentAt = "2026-11-20T22:30:00Z"
    #expect(!ExtensionStore.isOff(store, settings: settings))

    #expect(ExtensionStore.Off.title == "The Extension Store is off.")
    let entries = RootActions.extensionStoreOffSections.flatMap(\.entries)
    #expect(entries.map(\.title) == ["Open Extension Store Settings"])
    #expect(entries.first?.target == .root(.configureExtension(store)), "what ⌘⇧, does")
    #expect(entries.first?.shortcut == KeyShortcut(key: "return", modifiers: []))
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
            == "This adds the Extension Store to Fudge. It downloads extensions from Raycast's open-source extensions "
            + "repository on GitHub.")
    #expect(
        ExtensionStore.Consent.note
            == "Fudge aims to run Raycast extensions, but not all of them work yet. If you find one that doesn't, "
            + "please file an issue.")
    #expect(ExtensionStore.Consent.note.contains(ExtensionStore.Consent.issueLinkText), "the link is in the text")
    #expect(ExtensionStore.Consent.issuesURL.absoluteString == "https://github.com/jakeobsen/fudge/issues")
    #expect(ExtensionStore.Consent.confirm == "Turn On")
    #expect(ExtensionStore.Consent.cancel == "Cancel")
}
