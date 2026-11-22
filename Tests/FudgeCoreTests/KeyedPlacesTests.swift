import Foundation
import Testing

@testable import FudgeCore

/// Three extensions named `github` (FUD-183): Raycast's, one from the repository `someone/tools` and a development
/// build, each placed by the test in its own folder and made with the loader's init, as the walk finds them.
private struct ThreeGitHubs {
    let raycast: InstalledExtension
    let added: InstalledExtension
    let development: InstalledExtension
    var all: [InstalledExtension] { [raycast, added, development] }

    struct NotMade: Error {}

    init(in extensions: URL, owner: String = "someone") throws {
        func make(_ folder: String) throws -> InstalledExtension {
            let directory = extensions.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent("github", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = """
                {"name":"github","title":"GitHub","author":"\(owner)","commands":[
                {"name":"search","title":"Search","mode":"view"},{"name":"bar","title":"Bar","mode":"menu-bar"}]}
                """
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("package.json"))
            guard let repository = InstalledExtension.Repository(folder: folder),
                let id = ExtensionID(name: "github", repositoryFolder: folder)
            else { throw NotMade() }
            return try InstalledExtension.load(from: directory, id: id, repository: repository)
        }
        raycast = try make("raycast/extensions")
        added = try make("someone/tools")
        development = try make("fudgeapp/development")
    }
}

private func id(_ key: String) throws -> ExtensionID { try #require(ExtensionID(stored: key)) }

@Test func theThreeGitHubsHaveTheirOwnIDs() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    #expect(three.all.map(\.id.key) == ["github", "someone+tools+github", "fudgeapp+development+github"])
    #expect(InstalledExtension.index(three.all).count == 3)
}

@Test func eachGitHubHasItsOwnFoldersAndSeesItsOwnName() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let command = try #require(three.raycast.manifest.commands.first)
    var seen: Set<String> = []
    for installed in three.all {
        let environment = LaunchEnvironment.make(for: installed, command: command, paths: paths, appearance: "light")
        // The extension sees its manifest name, as in Raycast, whichever repository it's from.
        #expect(environment.extensionName == "github")
        #expect(environment.supportPath.hasSuffix("/extension-data/\(installed.id.key)"))
        #expect(environment.cachePath.hasSuffix("/cache/\(installed.id.key)"))
        #expect(environment.localStoragePath.hasSuffix("/local-storage/\(installed.id.key).json"))
        seen.formUnion([environment.supportPath, environment.cachePath, environment.localStoragePath])
    }
    #expect(seen.count == 9)
}

@Test func aPreferenceSetForOneGitHubIsntReadByTheOthers() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let store = PreferenceStore(directory: try Fixtures.temporaryDirectory())
    for installed in three.all {
        var preferences = StoredPreferences()
        preferences.extensionValues["token"] = .string("secret of \(installed.id.key)")
        try store.save(preferences, for: installed.id)
    }
    for installed in three.all {
        #expect(store.load(installed.id).extensionValues["token"] == .string("secret of \(installed.id.key)"))
    }
    #expect(store.load(try id("other")).extensionValues.isEmpty)
}

@Test func formValuesAndDropdownValuesAreKeptPerGitHub() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let forms = FormValueStore(directory: try Fixtures.temporaryDirectory())
    try forms.save(["query": .string("added")], extension: three.added.id, command: "search")
    #expect(forms.load(extension: three.added.id, command: "search") == ["query": .string("added")])
    #expect(forms.load(extension: three.raycast.id, command: "search").isEmpty)
    #expect(forms.load(extension: three.development.id, command: "search").isEmpty)
    let keys = three.all.map { SearchBarDropdown.Store.key(extension: $0.id, command: "search", dropdown: "kind") }
    #expect(
        keys == [
            "github/search/kind", "someone+tools+github/search/kind", "fudgeapp+development+github/search/kind",
        ])
}

@Test func commandIDsTakeAnOwner() throws {
    #expect(FudgeSettings.commandID(owner: .group(.system), command: "sleep") == ":system/sleep")
    #expect(
        FudgeSettings.commandID(owner: .extension(try id("someone+tools+github")), command: "search")
            == "someone+tools+github/search")
    #expect(RootItem.commandID(owner: .extension(try id("github")), command: "search") == "command:github/search")
}

@Test func twoGitHubsKeepTheirOwnHotkeysAliasesAndEnabled() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    for (index, installed) in three.all.enumerated() {
        let commandID = FudgeSettings.commandID(owner: .extension(installed.id), command: "search")
        settings.commands[commandID] = FudgeSettings.CommandSettings(
            hotkey: "cmd+opt+\(index + 1)", alias: "gh\(index)")
    }
    settings.setEnabled(false, owner: .extension(three.added.id))
    try settings.save(to: file)
    let read = FudgeSettings.load(from: file)
    #expect(read.commands.count == 3)
    #expect(read.commands["someone+tools+github/search"]?.alias == "gh1")
    #expect(read.isEnabled(owner: .extension(three.raycast.id)))
    #expect(!read.isEnabled(owner: .extension(three.added.id)))
    #expect(read.isEnabled(owner: .extension(three.development.id)))
    #expect(read.isEnabled(commandID: "github/search") && !read.isEnabled(commandID: "someone+tools+github/search"))
    let ids = Set(three.all.map { FudgeSettings.commandID(owner: .extension($0.id), command: "search") })
    #expect(Set(read.availableHotkeys(installed: ids).keys) == ["github/search", "fudgeapp+development+github/search"])
}

@Test func rootSearchListsEachGitHubUnderItsOwnIDAndSaysWhereItsFrom() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    var metadata = CommandMetadata()
    metadata.setSubtitle("Mine", extension: three.added.id, command: "search")
    let items = three.all.flatMap { RootItem.commands(of: $0, metadata: metadata) }.filter { $0.title == "Search" }
    #expect(
        items.map(\.id) == [
            "command:github/search", "command:someone+tools+github/search",
            "command:fudgeapp+development+github/search",
        ])
    #expect(items.map(\.subtitle) == ["GitHub", "Mine (someone/tools)", "GitHub (development)"])
    #expect(metadata.subtitle(extension: three.raycast.id, command: "search") == nil)
    #expect(Set(items.compactMap(\.commandSettingsID)).count == 3)
    let autosaveNames = three.all.map {
        MenuBarStore.autosaveName(FudgeSettings.commandID(owner: .extension($0.id), command: "bar"))
    }
    #expect(Set(autosaveNames).count == 3)
    #expect(autosaveNames[1] == "menubar:someone+tools+github/bar")
}

@Test func signInsArePerGitHubAndSigningOutOfOneLeavesTheOthers() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let secrets = MemorySecretStore()
    let store = OAuthTokenStore(secrets: secrets)
    for installed in three.all {
        var tokens = StoredTokenSet(accessToken: "token of \(installed.id.key)", updatedAt: "2026-11-22T12:00:00Z")
        tokens.relayProvider = installed.id == three.raycast.id ? nil : "github"
        try store.save(tokens, extension: installed.id, provider: "github")
    }
    for installed in three.all {
        #expect(
            try store.tokens(extension: installed.id, provider: "github")?.accessToken == "token of \(installed.id.key)"
        )
    }
    let entries = try store.entries()
    #expect(Set(entries.map(\.extensionKey)) == ["github", "someone+tools+github", "fudgeapp+development+github"])
    #expect(entries.allSatisfy { $0.providerID == "github" && $0.extensionID != nil })
    // Raycast's `github` has no relay sign-in of its own, and the others' never count for it.
    #expect(try !SignInCalls(store: store, extension: three.raycast.id, pending: []).hasRelaySignIn(provider: "github"))
    #expect(try SignInCalls(store: store, extension: three.added.id, pending: []).hasRelaySignIn(provider: "github"))
    try store.remove(extension: three.raycast.id, provider: "github")
    #expect(try store.tokens(extension: three.raycast.id, provider: "github") == nil)
    #expect(try store.tokens(extension: three.added.id, provider: "github") != nil)
    #expect(try store.tokens(extension: three.development.id, provider: "github") != nil)
}

@Test func aQualifiedIDsLogLinesReachItsOwnFile() throws {
    let folder = try Fixtures.temporaryDirectory()
    let url = try #require(LogFile.extension(try id("someone+tools+github")).url(in: folder))
    #expect(url.lastPathComponent == "someone+tools+github.log")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Extensions")
    #expect(
        LogSource(extension: "someone+tools+github", command: "search")?.extensionID == (try id("someone+tools+github"))
    )
    #expect(LogSource(extension: "Bad Key", command: "search")?.extensionID == nil)
}

@Test func installLinesNameTheRepository() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let stamps = InstallStamp.of(three.all, bundled: nil)
    #expect(stamps.count == 3)
    #expect(
        InstallStamp.changes(from: [:], to: stamps) == [
            "installed github (fudgeapp/development)", "installed github", "installed github (someone/tools)",
        ])
    #expect(InstallStamp.changes(from: stamps, to: [:]).contains("removed github (someone/tools)"))
}

@Test func theLaunchMessageCarriesTheIDBesideTheEnvironment() throws {
    let message = AppMessage.launch(
        session: "s-1", entry: "/x.cjs", mode: "view", launchProps: LaunchProps(),
        extensionId: try id("someone+tools+github"))
    let object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    #expect(object["extensionId"] as? String == "someone+tools+github")
}

@Test func bundledChecksCompareWholeIDs() throws {
    let lookalikeStore = try id("someone+tools+fudge-extension-store")
    let lookalikeClipboard = try id("fudgeapp+development+fudge-clipboard-history")
    #expect(BundledCalls.mayCall(.storeRepositories, from: ExtensionStore.id))
    #expect(!BundledCalls.mayCall(.storeRepositories, from: lookalikeStore))
    #expect(ClipboardHistory.mayCall(ClipboardHistory.id))
    #expect(!ClipboardHistory.mayCall(lookalikeClipboard) && !ClipboardHistory.mayCall(nil))
    #expect(ExtensionStore.sessionOnScreen("s-1", extension: ExtensionStore.id, isRunning: { _ in true }) == "s-1")
    #expect(ExtensionStore.sessionOnScreen("s-1", extension: lookalikeStore, isRunning: { _ in true }) == nil)
    let off = FudgeSettings()
    #expect(ExtensionStore.isOff(ExtensionStore.id, settings: off))
    #expect(!ExtensionStore.isOff(lookalikeStore, settings: off))
    // Only the store's Enabled defaults to off.
    #expect(!off.isEnabled(owner: .extension(ExtensionStore.id)) && off.isEnabled(owner: .extension(lookalikeStore)))
}

@Test func aSignInNoticeCarriesTheID() throws {
    let added = try id("someone+tools+github")
    let notice = try #require(
        SignInNotice(
            notice: SignInNotice.Kind.cancelled.rawValue, message: "", extension: added, extensionTitle: "GitHub",
            commandID: "someone+tools+github/search"))
    let targets = notice.actions.flatMap(\.entries).compactMap { entry -> RootAction? in
        if case .root(let action) = entry.target { action } else { nil }
    }
    #expect(targets.contains(.retryCommand("someone+tools+github/search")))
    let off = try #require(
        SignInNotice(
            notice: SignInNotice.Kind.off.rawValue, message: "", extension: added, extensionTitle: "GitHub",
            commandID: nil))
    let offTargets = off.actions.flatMap(\.entries).compactMap { entry -> RootAction? in
        if case .root(let action) = entry.target { action } else { nil }
    }
    #expect(offTargets.contains(.configureExtension(added)))
}

// MARK: - Today's files, with typed keys (C.9)

@Test func aGroupInTodaysSettingsFileIsReadAndWrittenAsBefore() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(
        #"{"extensions":{":system":{"enabled":false}},"commands":{":system/sleep":{"hotkey":"cmd+opt+s"}}}"#.utf8
    ).write(to: file)
    var settings = FudgeSettings.load(from: file)
    #expect(!settings.isEnabled(owner: .group(.system)))
    #expect(!settings.isEnabled(commandID: ":system/sleep"))
    #expect(settings.availableHotkeys(installed: [":system/sleep"]).isEmpty)
    settings.setEnabled(true, owner: .group(.system))
    try settings.save(to: file)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["extensions"] == nil)
    #expect(
        ((object["commands"] as? [String: Any])?[":system/sleep"] as? [String: Any])?["hotkey"] as? String
            == "cmd+opt+s")
    #expect(FudgeSettings.load(from: file).availableHotkeys(installed: [":system/sleep"]).count == 1)
}

@Test func todaysSettingsExtensionsKeepAKeyThatIsNoOwner() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(
        #"""
        {"extensions":{"github":{"enabled":false},"someone+tools+github":{"enabled":false},":tools":{"enabled":false},
        "Bad Key":{"enabled":false,"note":"kept"}},"commands":{"github/search":{"alias":"gh"}}}
        """#.utf8
    ).write(to: file)
    var settings = FudgeSettings.load(from: file)
    #expect(settings.extensions.count == 3)
    #expect(!settings.isEnabled(owner: .extension(try id("github"))))
    #expect(!settings.isEnabled(owner: .group(.tools)))
    #expect(settings.commands["github/search"]?.alias == "gh")
    settings.setEnabled(true, owner: .extension(try id("github")))
    try settings.save(to: file)
    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let extensions = try #require(object["extensions"] as? [String: Any])
    #expect(extensions["github"] == nil)
    #expect((extensions["Bad Key"] as? [String: Any])?["enabled"] as? Bool == false)
    #expect((extensions["Bad Key"] as? [String: Any])?["note"] as? String == "kept")
    #expect((extensions["someone+tools+github"] as? [String: Any])?["enabled"] as? Bool == false)
    #expect((extensions[":tools"] as? [String: Any])?["enabled"] as? Bool == false)
}

@Test func todaysLaunchPermissionsKeepKeysThatAreNoIDs() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("launch-permissions.json")
    try Data(#"{"raycast-script":{"github":true,"Bad Key":false},"Bad Key":{"github":true}}"#.utf8).write(to: file)
    #expect(!LaunchPermissions.isUnreadable(file))
    var permissions = LaunchPermissions.load(from: file)
    #expect(permissions.answer(caller: try id("raycast-script"), target: try id("github")) == true)
    #expect(permissions.entries.count == 1)
    permissions.record(false, caller: try id("fudgeapp+development+github"), target: try id("github"))
    try permissions.save(to: file)
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Bool]])
    #expect(
        object == [
            "raycast-script": ["github": true, "Bad Key": false], "Bad Key": ["github": true],
            "fudgeapp+development+github": ["github": false],
        ])
    #expect(LaunchPermissions.load(from: file).entries.count == 2)
}

@Test func todaysCommandMetadataIsFoundUnderTheSameKey() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("command-metadata.json")
    try Data(#"{"github/search":{"subtitle":"Raycast's"}}"#.utf8).write(to: file)
    let metadata = CommandMetadata.load(from: file)
    #expect(metadata.subtitle(extension: try id("github"), command: "search") == "Raycast's")
    #expect(metadata.subtitle(extension: try id("someone+tools+github"), command: "search") == nil)
}

// MARK: - launchCommand with two extensions of one name (F)

private func request(_ name: String = "github", owner: String = "someone") -> LaunchRequest {
    LaunchRequest(name: "search", type: .userInitiated, extensionName: name, ownerOrAuthorName: owner)
}

@Test func launchCommandPicksTheCallerItselfFirst() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    for caller in three.all {
        let target = try CommandLocator.locate(request(), caller: caller, in: three.all)
        #expect(target.installed.id == caller.id && !target.isOtherExtension)
    }
}

/// Another extension, `caller`, installed in the repository folder `folder`.
private func caller(in folder: String) throws -> InstalledExtension {
    let directory = try Fixtures.temporaryDirectory().appendingPathComponent("caller", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"name":"caller","title":"Caller","author":"other"}"#.utf8)
        .write(to: directory.appendingPathComponent("package.json"))
    guard let repository = InstalledExtension.Repository(folder: folder),
        let id = ExtensionID(name: "caller", repositoryFolder: folder)
    else { throw ThreeGitHubs.NotMade() }
    return try InstalledExtension.load(from: directory, id: id, repository: repository)
}

@Test func launchCommandPicksTheCallersRepositoryThenRaycastsThenTheDevelopmentBuild() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    // A caller from `someone/tools` gets its own repository's `github`.
    let fromTools = try caller(in: "someone/tools")
    let target = try CommandLocator.locate(request(), caller: fromTools, in: three.all + [fromTools])
    #expect(target.installed.id == three.added.id && target.isOtherExtension)
    #expect(target.rootItemID == "command:someone+tools+github/search")
    // A caller from anywhere else gets Raycast's, then the development build.
    let elsewhere = try caller(in: "other/place")
    #expect(try CommandLocator.locate(request(), caller: elsewhere, in: three.all).installed.id == three.raycast.id)
    #expect(
        try CommandLocator.locate(request(), caller: elsewhere, in: [three.added, three.development]).installed.id
            == three.development.id)
    // A development build's caller gets the development build first.
    let fromDevelopment = try caller(in: "fudgeapp/development")
    #expect(
        try CommandLocator.locate(request(), caller: fromDevelopment, in: three.all).installed.id
            == three.development.id)
}

@Test func launchCommandRefusesTwoAddedOnesItCantTellApart() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let others = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let otherTools = InstalledExtension(
        manifest: others.added.manifest, directory: others.added.directory, id: try id("other+tools+github"),
        repository: .added("other/tools"))
    let elsewhere = try caller(in: "other/place")
    #expect(throws: LaunchCommandError.ambiguous(name: "github")) {
        try CommandLocator.locate(request(), caller: elsewhere, in: [three.added, otherTools])
    }
    #expect(
        LaunchCommandError.ambiguous(name: "github").description
            == "More than one extension called github is installed, so Fudge can't tell which one to open.")
}

@Test func launchCommandTellsInstallsOfOneNameApartByID() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    // The caller's own command, named without an extension, is the caller's, never another `github`'s.
    let own = try CommandLocator.locate(
        LaunchRequest(name: "search", type: .userInitiated), caller: three.development, in: three.all)
    #expect(own.installed.id == three.development.id && !own.isOtherExtension)
    // Another owner's `github` is another extension, though it has the caller's name, so it needs the permission.
    let raycasts = try ThreeGitHubs(in: try Fixtures.temporaryDirectory(), owner: "raycast")
    let other = try CommandLocator.locate(
        request(owner: "raycast"), caller: three.development, in: [raycasts.raycast, three.development])
    #expect(other.installed.id == raycasts.raycast.id && other.isOtherExtension)
}

@Test func aLaunchPermissionIsKeptByID() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    var permissions = LaunchPermissions()
    permissions.record(true, caller: three.development.id, target: three.raycast.id)
    #expect(permissions.answer(caller: three.development.id, target: three.raycast.id) == true)
    #expect(permissions.answer(caller: three.development.id, target: three.added.id) == nil)
    #expect(permissions.answer(caller: three.added.id, target: three.raycast.id) == nil)
}

// MARK: - Backups (G)

@Test func aBackupTakesEachGitHubsPartsByItsID() throws {
    for key in ["github", "someone+tools+github", "fudgeapp+development+github"] {
        #expect(try Backup.part(of: "preferences/\(key).json") == .perExtension(folder: "preferences", name: key))
        #expect(try Backup.part(of: "local-storage/\(key).json") == .perExtension(folder: "local-storage", name: key))
        #expect(try Backup.part(of: "extension-data/\(key)/notes.txt") == .data(name: key, path: "notes.txt"))
    }
    for bad in ["Bad Key", "raycast+extensions+github", "someone+tools"] {
        #expect(throws: BackupError.self) { try Backup.part(of: "preferences/\(bad).json") }
        #expect(throws: BackupError.self) { try Backup.part(of: "extension-data/\(bad)/notes.txt") }
    }
}

@Test func aBackupListsEachGitHubWithWhereItsFrom() throws {
    let three = try ThreeGitHubs(in: try Fixtures.temporaryDirectory())
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let listed = Backup.listed(three.all, paths: paths)
    #expect(listed.map(\.key) == ["fudgeapp+development+github", "github", "someone+tools+github"])
    let byKey = Dictionary(uniqueKeysWithValues: listed.map { ($0.key, $0) })
    let raycast = try #require(byKey["github"])
    #expect(raycast.source == .local && raycast.id == nil && raycast.repository == nil)
    let development = try #require(byKey["fudgeapp+development+github"])
    #expect(development.source == .local && development.repository == "fudgeapp/development")
    let added = try #require(byKey["someone+tools+github"])
    #expect(added.source == .repository && added.repository == "someone/tools" && added.name == "github")
    #expect(Backup.whereFrom(added) == "from someone/tools")
    #expect(Backup.whereFrom(development) == "built from a local folder")
    // The new fields are written, and read back.
    let decoded = try JSONDecoder().decode(Backup.Listed.self, from: JSONEncoder().encode(added))
    #expect(decoded == added)
}

@Test func aBackupFromBeforeIDsListsEachExtensionByItsName() throws {
    let entry = try JSONDecoder().decode(
        Backup.Listed.self, from: Data(#"{"name":"github","title":"GitHub","source":"store","storeTree":"abc"}"#.utf8))
    #expect(entry.key == "github" && entry.id == nil && entry.repository == nil && entry.source == .store)
    let raycastEntry =
        try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Backup.Listed(name: "github", title: "GitHub", source: .local)))
        as? [String: Any]
    #expect(raycastEntry?["id"] == nil && raycastEntry?["repository"] == nil)
}
