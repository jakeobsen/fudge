import Foundation
import Testing

@testable import FudgeCore

/// Adding a repository (FUD-182). The Extension Store's `repository-address.ts` is tested against the same fixture, so
/// the two parsers can't drift apart.
private func addressFixture() throws -> [String: Any] {
    let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("runtime/test/fixtures/repository-addresses.json")
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}

/// The repositories at `addresses`, each added beside those before it, as Settings adds them.
private func added(_ addresses: [String]) throws -> [ExtensionRepository] {
    var list: [ExtensionRepository] = []
    for address in addresses { list.append(try ExtensionRepository.parse(address: address, existing: list).get()) }
    return list
}

@Test func addressRefusalsHaveTheFixturesSentences() throws {
    let sentences = try #require(try addressFixture()["sentences"] as? [String: String])
    let own: [ExtensionRepository.Refusal] = [.https, .credentials, .development, .branch, .tooMany, .raycastBranch]
    #expect(Set(sentences.keys) == Set(own.map(\.key)))
    for refusal in own { #expect(sentences[refusal.key] == refusal.description, "\(refusal.key)") }
    // The folder rule's refusals say the folder rule's sentences, never words of their own.
    for refusal in ExtensionRepositoryFolder.Refusal.allCases {
        #expect(ExtensionRepository.Refusal.folder(refusal).description == refusal.description)
        #expect(ExtensionRepository.Refusal.folder(refusal).key == refusal.rawValue)
    }
}

@Test func parsesAddressesAsTheSharedFixtureSays() throws {
    let cases = try #require(try addressFixture()["addresses"] as? [[String: Any]])
    #expect(cases.contains { $0["repository"] != nil } && cases.contains { $0["refused"] != nil })
    for one in cases {
        let address = try #require(one["address"] as? String)
        let label = Comment(rawValue: "\(address.debugDescription) \(one["branch"] ?? "")")
        let result = ExtensionRepository.parse(
            address: address, branch: one["branch"] as? String, existing: try added(one["existing"] as? [String] ?? []))
        if let refused = one["refused"] as? String {
            guard case .failure(let refusal) = result else {
                Issue.record("accepted, expected \(refused): \(label.rawValue)")
                continue
            }
            #expect(refusal.key == refused, label)
        } else {
            let expected = try #require(one["repository"] as? [String: String])
            guard case .success(let repository) = result else {
                Issue.record("refused: \(label.rawValue)")
                continue
            }
            #expect(repository.identity == expected["identity"], label)
            #expect(repository.copyId == expected["copyId"], label)
            #expect(repository.name == expected["name"], label)
            #expect(repository.folder == expected["folder"], label)
            #expect(repository.branch == expected["branch"], label)
            #expect(repository.address == ExtensionRepository.trimmed(address), label)
        }
    }
}

@Test func validatesCopyIdsAsTheSharedFixtureSays() throws {
    let copyIds = try #require(try addressFixture()["copyIds"] as? [String: [String]])
    let valid = try #require(copyIds["valid"])
    let invalid = try #require(copyIds["invalid"])
    #expect(!valid.isEmpty && !invalid.isEmpty)
    for copyId in valid { #expect(ExtensionRepository.isValidCopyId(copyId), "\(copyId)") }
    for copyId in invalid { #expect(!ExtensionRepository.isValidCopyId(copyId), "\(copyId)") }
    #expect(ExtensionRepository.copyId(of: "https://github.com/someone/tools") == "8204a7a9998b0604")
}

/// The runtime's `isValidBranch` (`git.ts`) is what the Extension Store checks a branch with before it uses it.
@Test func branchNamesFollowTheExtensionStoresRule() {
    for name in ["main", "release/v1.2", "feature+x_y-z", "_x", "a.b", "v1.0.lock2"] {
        #expect(ExtensionRepository.isValidBranch(name), "\(name)")
    }
    for name in [
        "", "-main", "a..b", "main.", "a//b", ".hidden", "a/.b", "x.lock", "a/x.lock/b", "a b", "main~1", "main^",
        "a:b", "/main", "main/", "mäin", "a\\b",
    ] {
        #expect(!ExtensionRepository.isValidBranch(name), "\(name)")
    }
}

// MARK: - settings.json

private func settingsFile(_ text: String) throws -> URL {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(text.utf8).write(to: file)
    return file
}

private func object(_ file: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}

// MARK: - The Extension Store's question

/// One entry of the answer: texts and switches only.
private func entry(_ pairs: KeyValuePairs<String, Any>) -> JSONValue {
    .object(
        Dictionary(
            uniqueKeysWithValues: pairs.map { key, value in
                (key, (value as? Bool).map(JSONValue.bool) ?? .string(value as? String ?? "\(value)"))
            }))
}

/// Every repository at `addresses` in the list, as `settings.json` would hold them.
private func listed(_ addresses: [String]) throws -> [ListedRepository] {
    try added(addresses).map { ListedRepository(repository: $0) }
}

/// `count` repositories that aren't Raycast's or Fudge's, as `settings.json` would hold them.
private func others(_ count: Int) -> [String] {
    (1...count).map { "https://github.com/owner/repository-\($0)" }
}

/// Raycast's official repository's entry with no name, as a list from before SPEC-176 and the defaults have it.
private let raycastAlone = [ListedRepository(repository: .raycast)]

@Test func repositoriesAreWrittenAtEverySaveWithOffOnlyWhenTrue() throws {
    let file = try settingsFile(#"{ "theme": "dark", "extensionRepositories": [], "raycastRepository": "off" }"#)
    var settings = FudgeSettings.load(from: file)
    let tools = try ExtensionRepository.parse(address: " https://github.com/Someone/Tools ", branch: "main").get()
    let team = try ExtensionRepository.parse(address: "https://git.example.org/team/extensions", existing: [tools])
        .get()
    let raycast = try ExtensionRepository.parse(
        address: "https://github.com/Raycast/Extensions", existing: [tools, team]
    )
    .get()
    settings.extensionRepositories = [
        ListedRepository(repository: tools), ListedRepository(repository: team, on: false),
        ListedRepository(repository: raycast, label: "Raycast"),
    ]
    try settings.save(to: file)
    let written = try object(file)
    #expect(written["theme"] as? String == "dark", "a key Fudge doesn't know is kept")
    #expect(written["extensionRepositories"] == nil && written["raycastRepository"] == nil, "the old keys go")
    let entries = try #require(written["repositories"] as? [[String: Any]])
    #expect(entries.count == 3)
    #expect(entries[0]["address"] as? String == "https://github.com/Someone/Tools", "as typed, without the spaces")
    #expect(entries[0]["branch"] as? String == "main" && entries[0]["off"] == nil)
    #expect(entries[1]["branch"] == nil && entries[1]["off"] as? Bool == true)
    #expect(Set(entries[1].keys) == ["address", "off"])
    #expect(entries[2]["address"] as? String == "https://github.com/Raycast/Extensions")
    #expect(entries[2]["name"] as? String == "Raycast" && Set(entries[2].keys) == ["address", "name"])
    #expect(FudgeSettings.load(from: file) == settings)

    // An empty list is written too, so it never reads as the list from before.
    settings.extensionRepositories = []
    try settings.save(to: file)
    #expect(try object(file)["repositories"] as? [Any] != nil)
    #expect(try (object(file)["repositories"] as? [Any])?.isEmpty == true)
    #expect(FudgeSettings.load(from: file).extensionRepositories.isEmpty)
}

@Test func readingSkipsEntriesSettingsWouldRefuse() throws {
    let file = try settingsFile(
        #"""
        { "repositories": [
            { "address": "https://github.com/someone/tools", "off": 1 },
            { "address": "https://github.com/Someone/Tools.git" },
            { "address": "https://github.com/raycast/extensions", "branch": "main" },
            { "address": "https://github.com/raycast/extensions", "off": true },
            { "address": "https://github.com/Raycast/Extensions.git" },
            { "address": "http://git.example.org/team/extensions" },
            { "address": "https://git.example.org/team/extensions", "branch": "a..b" },
            { "address": "https://git.example.org/team/extensions", "branch": 7 },
            { "address": 5 }, "https://git.example.org/other/extensions",
            { "address": "https://git.example.org/team/extensions", "branch": " dev ", "off": false }
        ] }
        """#)
    let settings = FudgeSettings.load(from: file)
    #expect(
        settings.extensionRepositories.map(\.repository.address) == [
            "https://github.com/someone/tools", "https://github.com/raycast/extensions",
            "https://git.example.org/team/extensions",
        ], "Raycast's is an entry like any other, and its second is skipped as any duplicate is")
    #expect(settings.extensionRepositories.map(\.on) == [true, false, true], "only a JSON true turns one off")
    #expect(settings.extensionRepositories[1].repository.copyId == "raycast")
    #expect(settings.extensionRepositories.last?.repository.branch == "dev")

    // A thirteenth is skipped as Settings would refuse it, Raycast's counted.
    let thirteen = ["https://github.com/raycast/extensions"] + others(12)
    let entries = thirteen.map { #"{ "address": "\#($0)" }"# }.joined(separator: ",")
    let full = try settingsFile(#"{ "repositories": [\#(entries)] }"#)
    #expect(
        FudgeSettings.load(from: full).extensionRepositories.map(\.repository.address) == Array(thirteen.prefix(12)))
    // A value that isn't an array is an empty list.
    #expect(FudgeSettings.load(from: try settingsFile(#"{ "repositories": {} }"#)).extensionRepositories.isEmpty)
}

// MARK: - Reading the list (SPEC-176)

@Test func aRepositoriesListIsReadAsWrittenAndTheOldKeysAreIgnored() throws {
    let file = try settingsFile(
        #"""
        { "raycastRepository": "removed", "extensionRepositories": [{ "address": "https://github.com/old/one" }],
          "repositories": [
            { "address": "https://github.com/someone/tools", "name": "Tools" },
            { "address": "https://git.example.org/team/extensions" },
            { "address": "https://github.com/raycast/extensions", "name": "Raycast", "off": true }
        ] }
        """#)
    let settings = FudgeSettings.load(from: file)
    let expected = try added([
        "https://github.com/someone/tools", "https://git.example.org/team/extensions",
        "https://github.com/raycast/extensions",
    ])
    #expect(
        settings.extensionRepositories == [
            ListedRepository(repository: expected[0], label: "Tools"), ListedRepository(repository: expected[1]),
            ListedRepository(repository: expected[2], on: false, label: "Raycast"),
        ])
    guard case .array(let answer) = ExtensionRepository.storeAnswer(settings: settings) else {
        Issue.record("not an array")
        return
    }
    #expect(answer.count == 3)
    #expect(
        answer[2]
            == entry([
                "copyId": "raycast", "folder": "raycast/extensions", "address": "https://github.com/raycast/extensions",
                "name": "raycast/extensions", "label": "Raycast", "on": false,
            ]), "third, named and off, made as any entry is")
}

@Test func aFileFromBeforeIsReadWithRaycastsFirstAndNeverNamed() throws {
    let named = #"[{ "address": "https://github.com/Someone/Tools", "name": "Tools" }]"#
    let tools = try ExtensionRepository.parse(address: "https://github.com/Someone/Tools").get()
    let cases: [(String, [ListedRepository])] = [
        (
            #"{ "extensionRepositories": \#(named) }"#,
            [ListedRepository(repository: .raycast), ListedRepository(repository: tools, label: "Tools")]
        ),
        (
            #"{ "raycastRepository": "off", "extensionRepositories": \#(named) }"#,
            [ListedRepository(repository: .raycast, on: false), ListedRepository(repository: tools, label: "Tools")]
        ),
        (
            #"{ "raycastRepository": false, "extensionRepositories": \#(named) }"#,
            [ListedRepository(repository: .raycast, on: false), ListedRepository(repository: tools, label: "Tools")]
        ),
        (
            #"{ "raycastRepository": "removed", "extensionRepositories": \#(named) }"#,
            [ListedRepository(repository: tools, label: "Tools")]
        ),
        (#"{ "raycastRepository": "removed" }"#, []),
        (#"{ "raycastRepository": 0 }"#, raycastAlone),
    ]
    for (text, expected) in cases {
        let settings = FudgeSettings.load(from: try settingsFile(text))
        #expect(settings.extensionRepositories == expected, "\(text)")
        #expect(settings.extensionRepositories.allSatisfy { $0.repository.copyId != "raycast" || $0.label == nil })
        guard case .array(let answer) = ExtensionRepository.storeAnswer(settings: settings) else {
            Issue.record("not an array: \(text)")
            continue
        }
        #expect(answer.count == expected.count, "\(text)")
        if expected.first?.repository.copyId == "raycast" {
            #expect(
                answer.first
                    == entry([
                        "copyId": "raycast", "folder": "raycast/extensions",
                        "address": "https://github.com/raycast/extensions", "name": "raycast/extensions",
                        "on": expected[0].on,
                    ]), "\(text)")
        }
    }
    #expect(ListedRepository(repository: .raycast).repository.copyId == "raycast")
    #expect(ExtensionRepository.raycast.address == "https://github.com/raycast/extensions")
    #expect(ExtensionRepository.raycastAddress == "https://github.com/raycast/extensions.git", "the clone address")
}

@Test func aFileWithNoListHasRaycastsAloneWithNoNameAndNoFudges() throws {
    let folder = try Fixtures.temporaryDirectory()
    let missing = folder.appendingPathComponent("settings.json")
    for file in [
        try settingsFile(#"{ "hotkey": "option+s" }"#), try settingsFile("{}"), try settingsFile(" \n"), missing,
    ] {
        let settings = FudgeSettings.load(from: file)
        #expect(settings.extensionRepositories == raycastAlone, "\(file.path)")
        #expect(
            ExtensionRepository.storeAnswer(settings: settings)
                == .array([
                    entry([
                        "copyId": "raycast", "folder": "raycast/extensions",
                        "address": "https://github.com/raycast/extensions", "name": "raycast/extensions", "on": true,
                    ])
                ]))
    }
    #expect(FudgeSettings.load(from: try settingsFile("{}")) == FudgeSettings())
    #expect(FudgeSettings.load(from: try settingsFile(" \n")) == FudgeSettings())
    #expect(FudgeSettings.load(from: missing) == FudgeSettings())
    #expect(FudgeSettings().extensionRepositories == raycastAlone)
}

// MARK: - The one-time write (SPEC-176)

/// A support folder with `settings.json` holding `text` (none for nil) and `onboarding.json` when `onboarded`.
private func supportFolder(settings text: String?, onboarded: Bool) throws -> (settings: URL, onboarding: URL) {
    let folder = try Fixtures.temporaryDirectory()
    let settings = folder.appendingPathComponent("settings.json")
    let onboarding = folder.appendingPathComponent("onboarding.json")
    if let text { try Data(text.utf8).write(to: settings) }
    if onboarded { try Data(#"{ "answered": ["welcome"] }"#.utf8).write(to: onboarding) }
    return (settings, onboarding)
}

@Test func theOneTimeWriteSeedsOnlyANewInstall() throws {
    let seed = RepositoryButton.seed
    for text in [nil, "{}", " \n"] {
        let files = try supportFolder(settings: text, onboarded: false)
        try FudgeSettings.writeRepositoryListOnce(settings: files.settings, onboarding: files.onboarding)
        #expect(FudgeSettings.load(from: files.settings).extensionRepositories == seed, "\(text ?? "no file")")
        #expect(seed.map(\.label) == ["Raycast", "Fudge"])
    }
    for (text, onboarded) in [
        (nil, true), ("{}", true), (#"{ "hotkey": "option+s" }"#, true), (#"{ "hotkey": "option+s" }"#, false),
    ] as [(String?, Bool)] {
        let files = try supportFolder(settings: text, onboarded: onboarded)
        try FudgeSettings.writeRepositoryListOnce(settings: files.settings, onboarding: files.onboarding)
        let written = try object(files.settings)
        #expect(
            written["repositories"] as? [[String: String]] == [["address": "https://github.com/raycast/extensions"]],
            "Raycast's alone, with no name: \(text ?? "no file"), onboarded \(onboarded)")
        #expect(FudgeSettings.load(from: files.settings).extensionRepositories == raycastAlone)
    }
}

@Test func theOneTimeWriteMovesAnOldListAndLeavesAWrittenOneAlone() throws {
    let old = try supportFolder(
        settings: #"""
            { "theme": "dark", "raycastRepository": "off",
              "extensionRepositories": [{ "address": "https://github.com/someone/tools", "name": "Tools" }] }
            """#, onboarded: true)
    try FudgeSettings.writeRepositoryListOnce(settings: old.settings, onboarding: old.onboarding)
    let moved = try object(old.settings)
    #expect(moved["extensionRepositories"] == nil && moved["raycastRepository"] == nil, "the old keys go")
    #expect(moved["theme"] as? String == "dark")
    let entries = try #require(moved["repositories"] as? [[String: Any]])
    #expect(entries.count == 2)
    #expect(entries.first?["address"] as? String == "https://github.com/raycast/extensions")
    #expect(entries.first?["off"] as? Bool == true && entries.first?["name"] == nil, "off, with no name")
    #expect(entries.last?["address"] as? String == "https://github.com/someone/tools")
    #expect(entries.last?["name"] as? String == "Tools")

    // A file that has the list, an empty one included, is never written again.
    for text in [#"{ "repositories": [] }"#, #"{"repositories":[{"address":"https://github.com/someone/tools"}]}"#] {
        let files = try supportFolder(settings: text, onboarded: false)
        let date = try #require(
            try FileManager.default.attributesOfItem(atPath: files.settings.path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes(
            [.modificationDate: date.addingTimeInterval(-3600)], ofItemAtPath: files.settings.path)
        let before = try FileManager.default.attributesOfItem(atPath: files.settings.path)[.modificationDate] as? Date
        try FudgeSettings.writeRepositoryListOnce(settings: files.settings, onboarding: files.onboarding)
        #expect(try Data(contentsOf: files.settings) == Data(text.utf8), "byte for byte")
        #expect(
            try FileManager.default.attributesOfItem(atPath: files.settings.path)[.modificationDate] as? Date == before)
    }

    // An unreadable file is left as it is, for the next launch to try again.
    let broken = try supportFolder(settings: "{ not json", onboarded: false)
    #expect(throws: FudgeSettings.Unreadable.self) {
        try FudgeSettings.writeRepositoryListOnce(settings: broken.settings, onboarding: broken.onboarding)
    }
    #expect(try Data(contentsOf: broken.settings) == Data("{ not json".utf8))
}

// MARK: - The add buttons (SPEC-176)

@Test func theButtonTableNamesRaycastsAndFudgesRepositories() {
    #expect(
        RepositoryButton.all.map(\.address) == [
            "https://github.com/raycast/extensions", "https://github.com/fudgeapp/extensions",
        ])
    #expect(RepositoryButton.all.map(\.name) == ["Raycast", "Fudge"])
    #expect(RepositoryButton.all.map(\.title) == ["Add Raycast's Repository", "Add Fudge's Repository"])
}

@Test func aButtonIsHiddenByIdentityDisabledWithTheReasonOrEnabled() throws {
    // Hidden while a listed repository has its address's identity, however it's typed.
    let typed = try listed(["https://github.com/Raycast/Extensions.git"])
    #expect(RepositoryButton.raycast.state(in: typed) == .hidden)
    #expect(RepositoryButton.fudge.state(in: typed) == .enabled)
    #expect(RepositoryButton.fudge.state(in: try listed(["https://github.com/FudgeApp/Extensions/"])) == .hidden)

    // Disabled with the add window's sentence while the list is full, Raycast's counted.
    let full = try listed(["https://github.com/raycast/extensions"] + others(11))
    #expect(RepositoryButton.raycast.state(in: full) == .hidden)
    #expect(RepositoryButton.fudge.state(in: full) == .disabled("You can have up to 12 repositories in the list."))
    #expect(
        RepositoryButton.fudge.entry(beside: full)
            == .failure(RepositoryButton.Refused(reason: "You can have up to 12 repositories in the list.")))

    // Disabled while another repository has the button's name, ignoring case, as Add Repository refuses it.
    var tools = try listed(["https://github.com/someone/tools"])
    tools[0].label = "raycast"
    #expect(RepositoryButton.raycast.state(in: tools) == .disabled("Another repository is already called raycast."))
    #expect(
        RepositoryButton.raycast.entry(beside: tools)
            == .failure(RepositoryButton.Refused(reason: "Another repository is already called raycast.")))

    // Enabled otherwise, and a press gives the button's repository, on, with its name, beside the list.
    let eleven = try listed(others(11))
    #expect(RepositoryButton.raycast.state(in: eleven) == .enabled)
    let pressed = try RepositoryButton.raycast.entry(beside: eleven).get()
    #expect(pressed == ListedRepository(repository: .raycast, on: true, label: "Raycast"))
    #expect(pressed.repository.copyId == "raycast")
    let fudge = try RepositoryButton.fudge.entry(beside: []).get()
    #expect(fudge.label == "Fudge" && fudge.on && fudge.repository.address == "https://github.com/fudgeapp/extensions")
    #expect(fudge.repository.copyId == ExtensionRepository.copyId(of: "https://github.com/fudgeapp/extensions"))
    var settings = FudgeSettings()
    settings.addRepository(fudge)
    #expect(settings.extensionRepositories == raycastAlone + [fudge], "at the end of the list")
}

@Test func theSeedIsEveryButtonPressedInOrder() throws {
    let raycast = ListedRepository(repository: .raycast, label: "Raycast")
    let fudge = ListedRepository(
        repository: try ExtensionRepository.parse(
            address: "https://github.com/fudgeapp/extensions", existing: [.raycast]
        ).get(), label: "Fudge")
    #expect(RepositoryButton.seed == [raycast, fudge])
    #expect(RepositoryButton.seed.allSatisfy { $0.on })
    #expect(RepositoryButton.all.allSatisfy { $0.state(in: RepositoryButton.seed) == .hidden })
}

// MARK: - Removing (SPEC-176)

@Test func theRemoveSheetSaysHowToAddARepositoryWithAButtonBack() throws {
    let plain =
        "Extensions you installed from it stay installed, but get no more updates. You can still uninstall them in "
        + "the Extension Store. Its downloaded list is deleted."
    for address in ["https://github.com/raycast/extensions", "https://github.com/Raycast/Extensions.git"] {
        #expect(
            ExtensionRepositoryText.removeMessage(for: try ExtensionRepository.parse(address: address).get())
                == plain + " You can add it back with Add Raycast's Repository.", "\(address)")
    }
    #expect(
        ExtensionRepositoryText.removeMessage(
            for: try ExtensionRepository.parse(address: "https://github.com/FudgeApp/Extensions").get())
            == plain + " You can add it back with Add Fudge's Repository.")
    #expect(
        ExtensionRepositoryText.removeMessage(
            for: try ExtensionRepository.parse(address: "https://github.com/someone/tools").get()) == plain)
    #expect(ExtensionRepositoryText.removeTitle("Raycast") == "Remove Raycast?")
}

// MARK: - Raycast's official repository's label (SPEC-176)

@Test func raycastsInstallsAreLabelledByItsEntryLikeAnyOthers() throws {
    var settings = FudgeSettings()
    #expect(RepositoryNames(settings: settings).label(of: .raycast) == "raycast/extensions", "no name")
    settings.extensionRepositories = [ListedRepository(repository: .raycast, label: "Raycast")]
    #expect(RepositoryNames(settings: settings).label(of: .raycast) == "Raycast")
    settings.extensionRepositories = [
        ListedRepository(
            repository: try ExtensionRepository.parse(address: "https://github.com/Raycast/Extensions").get())
    ]
    #expect(RepositoryNames(settings: settings).label(of: .raycast) == "Raycast/Extensions", "as typed")
    settings.extensionRepositories = []
    #expect(RepositoryNames(settings: settings).label(of: .raycast) == "raycast/extensions", "removed: its folder")
    #expect(RepositoryNames(settings: settings).label(of: .bundled) == "Core")
}

@Test func raycastsAddressGivesRaycastsOwnEntryLikeAnyAddress() throws {
    for address in [
        "https://github.com/raycast/extensions", " https://github.com/Raycast/Extensions.git ",
        "https://github.com:443/raycast/extensions/",
    ] {
        let repository = try ExtensionRepository.parse(address: address).get()
        #expect(repository.copyId == "raycast" && repository.folder == "raycast/extensions")
        #expect(repository.identity == ExtensionRepository.raycastIdentity)
        #expect(repository.branch == nil && repository.address == ExtensionRepository.trimmed(address))
        // Counted as any is, and refused as any duplicate is.
        #expect(try ExtensionRepository.parse(address: address, existing: added(others(11))).get().copyId == "raycast")
        #expect(ExtensionRepository.parse(address: address, existing: try added(others(12))) == .failure(.tooMany))
        #expect(
            ExtensionRepository.parse(address: address, existing: [.raycast]) == .failure(.folder(.alreadyListed)))
    }
    #expect(
        try ExtensionRepository.parse(address: "https://github.com/Raycast/Extensions.git").get().name
            == "Raycast/Extensions", "named as typed")
    for branch in ["main", "a..b", " dev "] {
        #expect(
            ExtensionRepository.parse(address: "https://github.com/Raycast/Extensions", branch: branch)
                == .failure(.raycastBranch), "\(branch)")
        #expect(
            ExtensionRepository.parse(
                address: "https://github.com/Raycast/Extensions", branch: branch, existing: [.raycast])
                == .failure(.raycastBranch), "the branch step comes before the duplicate: \(branch)")
    }
    #expect(
        ExtensionRepository.parse(address: "https://github.com/raycast/extensions", branch: "  ").map(\.copyId)
            == .success("raycast"), "a blank branch is the default one")
    #expect(
        ExtensionRepository.Refusal.raycastBranch.description
            == "Raycast's official repository always follows its default branch.")
}

// MARK: - The Add Repository window (SPEC-160)

@Test func aNewDraftIsEmpty() {
    let draft = ExtensionRepositoryDraft()
    #expect(draft.address.isEmpty && draft.branch.isEmpty && draft.reason == nil)
    #expect(!draft.canAdd)
    var spaces = ExtensionRepositoryDraft()
    spaces.address = "  "
    #expect(!spaces.canAdd, "Add is off while the address is blank")
}

@Test func aRefusedAddressKeepsWhatWasTypedAndSaysWhy() {
    var draft = ExtensionRepositoryDraft()
    draft.address = "http://github.com/owner/repository"
    draft.branch = "main"
    #expect(draft.canAdd)
    let refused = draft.add(existing: [])
    #expect(refused == nil)
    #expect(draft.address == "http://github.com/owner/repository" && draft.branch == "main")
    #expect(draft.reason == "Use an https:// address, such as https://github.com/owner/repository.")
}

@Test func anAcceptedAddressGivesTheRepositoryWithItsBranch() throws {
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/owner/repository"
    draft.branch = "main"
    let accepted = draft.add(existing: [])
    let listed = try #require(accepted)
    let repository = listed.repository
    #expect(listed.label == nil && listed.on, "no name typed")
    #expect(repository.copyId == ExtensionRepository.copyId(of: "https://github.com/owner/repository"))
    #expect(repository.branch == "main" && repository.name == "owner/repository")
    #expect(draft.reason == nil)
    var settings = FudgeSettings()
    settings.addRepository(listed)
    #expect(settings.extensionRepositories == raycastAlone + [ListedRepository(repository: repository, on: true)])
}

@Test func theListPassedAtAddCountsNotAnEarlierOne() throws {
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/owner/repository"
    let early = draft.add(existing: [])
    #expect(early != nil)
    let atAdd = draft.add(existing: try listed(["https://github.com/Owner/Repository.git"]))
    #expect(atAdd == nil)
    #expect(draft.reason == "That repository is already in the list.")
}

@Test func twelveRepositoriesAreTheMostRaycastsCounted() throws {
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/owner/repository-12"
    let twelfth = draft.add(existing: try listed(["https://github.com/raycast/extensions"] + others(10)))
    #expect(twelfth != nil)
    draft.address = "https://github.com/owner/repository-13"
    let thirteenth = draft.add(existing: try listed(["https://github.com/raycast/extensions"] + others(11)))
    #expect(thirteenth == nil)
    #expect(draft.reason == "You can have up to 12 repositories in the list.")
}

@Test func aCorrectedAddressClearsTheReason() throws {
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://user@github.com/owner/repository"
    let refused = draft.add(existing: [])
    #expect(refused == nil)
    #expect(draft.reason == "Leave the user name and password out of the address.")
    draft.address = "https://github.com/owner/repository"
    let corrected = draft.add(existing: [])
    #expect(corrected != nil)
    #expect(draft.reason == nil)
    // A failed save shows its problem until the next Add, and Cancel starts over.
    draft.saveFailed("settings.json isn't valid JSON.")
    #expect(draft.reason == "settings.json isn't valid JSON." && draft.address == "https://github.com/owner/repository")
    #expect(draft.cancelled() == ExtensionRepositoryDraft())
}

@Test func raycastsAddressInTheWindowAddsItAtTheEndWithTheNameTyped() throws {
    var settings = FudgeSettings()
    settings.extensionRepositories = try listed(others(11))
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/Raycast/Extensions.git"
    draft.branch = "main"
    draft.label = "Upstream"
    let withBranch = draft.add(existing: settings.extensionRepositories)
    #expect(withBranch == nil)
    #expect(draft.reason == "Raycast's official repository always follows its default branch.")
    draft.branch = ""
    let accepted = draft.add(existing: settings.extensionRepositories)
    let raycast = try #require(accepted)
    #expect(raycast.repository.copyId == "raycast" && raycast.label == "Upstream" && draft.reason == nil)
    settings.addRepository(raycast)
    #expect(settings.extensionRepositories.count == 12 && settings.extensionRepositories.last == raycast, "at the end")
    guard case .array(let answer) = ExtensionRepository.storeAnswer(settings: settings) else {
        Issue.record("not an array")
        return
    }
    #expect(
        answer.count == 12
            && answer.last
                == entry([
                    "copyId": "raycast", "folder": "raycast/extensions",
                    "address": "https://github.com/Raycast/Extensions.git",
                    "name": "Raycast/Extensions", "label": "Upstream", "on": true,
                ])
    )
    // Once it's back, its address is refused as any duplicate is, here past the limit first.
    let again = draft.add(existing: settings.extensionRepositories)
    #expect(again == nil)
    #expect(draft.reason == "You can have up to 12 repositories in the list.")
    let beside = draft.add(existing: [raycast])
    #expect(beside == nil)
    #expect(draft.reason == "That repository is already in the list.")
}

@Test func onlyTheExtensionStoreMayAskForTheRepositories() {
    #expect(BundledCalls.mayCall(.storeRepositories, from: ExtensionStore.id))
    #expect(!BundledCalls.mayCall(.storeRepositories, from: ClipboardHistory.id))
    #expect(!BundledCalls.mayCall(.storeRepositories, from: nil))
    let lookAlike = ExtensionID(name: ExtensionStore.extensionName, repositoryFolder: "someone/tools")
    #expect(lookAlike != nil && !BundledCalls.mayCall(.storeRepositories, from: lookAlike))
}

// MARK: - Status files

private func status(_ text: String) throws -> ExtensionRepositoryStatus {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("status.json")
    try Data(text.utf8).write(to: file)
    return ExtensionRepositoryStatus.read(file)
}

@Test func aStatusFileShowsOnlyFudgesOwnSentences() throws {
    let at = #""checkedAt": "2026-11-22T10:00:00.123Z""#
    #expect(try status(#"{ \#(at), "extensions": 12 }"#) == .extensions(12))
    #expect(try status(#"{ \#(at), "extensions": 12 }"#).sentence(branch: nil) == "12 extensions")
    #expect(
        try status(#"{ "checkedAt": "2026-11-22T10:00:00Z", "extensions": 1 }"#).sentence(branch: nil) == "1 extension")
    #expect(try status(#"{ \#(at), "extensions": 0 }"#) == .extensions(0))
    #expect(try status(#"{ \#(at), "extensions": 5000 }"#) == .extensions(5000))
    let problems = try #require(try addressFixture()["problems"] as? [String: String])
    #expect(Set(problems.keys) == Set(ExtensionRepositoryStatus.Problem.allCases.map(\.rawValue)))
    for problem in ExtensionRepositoryStatus.Problem.allCases {
        let read = try status(#"{ \#(at), "branch": "elsewhere", "problem": "\#(problem.rawValue)" }"#)
        #expect(read == .problem(problem) && read.isProblem)
        let sentence = try #require(problems[problem.rawValue]).replacingOccurrences(of: "<branch>", with: "main")
        #expect(read.sentence(branch: "main") == sentence, "the branch from settings.json, never the file's")
    }
    for text in [
        #"{ \#(at), "problem": "Click here: https://example.org" }"#, #"{ \#(at), "problem": 3 }"#,
        #"{ \#(at), "extensions": 2.5 }"#, #"{ \#(at), "extensions": -1 }"#, #"{ \#(at), "extensions": 5001 }"#,
        #"{ \#(at), "extensions": "12" }"#, #"{ \#(at), "extensions": true }"#, #"{ \#(at) }"#,
        #"{ "checkedAt": "yesterday", "extensions": 3 }"#, #"{ "extensions": 3 }"#,
        #"{ "checkedAt": 5, "extensions": 3 }"#,
        #"[ { \#(at), "extensions": 3 } ]"#, "not json", "",
        #"{ \#(at), "extensions": 3, "padding": "\#(String(repeating: "x", count: 4096))" }"#,
    ] {
        #expect(try status(text) == .problem(.failed), "\(text.prefix(80))")
    }
    #expect(
        ExtensionRepositoryStatus.problem(.failed).sentence(branch: nil) == "Something went wrong with this repository."
    )
    let missing = try Fixtures.temporaryDirectory().appendingPathComponent("status.json")
    #expect(ExtensionRepositoryStatus.read(missing) == .notChecked)
    #expect(ExtensionRepositoryStatus.notChecked.sentence(branch: nil) == "Not checked yet")
    #expect(!ExtensionRepositoryStatus.notChecked.isProblem && !ExtensionRepositoryStatus.extensions(3).isProblem)
}

/// `ExtensionRepositoryStatus.read(file)` on a thread of its own, or nil when it hasn't answered within 10 s. A read still
/// waiting on a FIFO then gets a writer that closes at once, so it ends and the test run never hangs.
private func readWithoutWaiting(_ file: URL) async throws -> ExtensionRepositoryStatus? {
    if let status = try await OffThePool.run(within: .seconds(10), { ExtensionRepositoryStatus.read(file) }) {
        return status
    }
    let writer = open(file.path, O_RDWR | O_NONBLOCK)
    if writer >= 0 { close(writer) }
    return nil
}

/// Settings reads the status file on the main thread, and any extension in the host could put something else there:
/// only a regular file counts, and a FIFO is never waited on.
@Test func aStatusFileThatIsntARegularFileReadsAsFailedWithoutWaiting() async throws {
    let text = #"{ "checkedAt": "2026-11-22T10:00:00.123Z", "extensions": 3 }"#
    // An empty FIFO with no writer: opening it to read would wait for one.
    let empty = try Fixtures.temporaryDirectory().appendingPathComponent("status.json")
    try #require(mkfifo(empty.path, 0o600) == 0)
    #expect(try await readWithoutWaiting(empty) == .problem(.failed), "read at once, as failed")

    // A FIFO holding a status, its writer gone: still not a status file.
    let holding = try Fixtures.temporaryDirectory().appendingPathComponent("status.json")
    try #require(mkfifo(holding.path, 0o600) == 0)
    let reader = open(holding.path, O_RDONLY | O_NONBLOCK)
    try #require(reader >= 0)
    defer { close(reader) }
    let writer = open(holding.path, O_WRONLY | O_NONBLOCK)
    try #require(writer >= 0)
    let bytes = Array(text.utf8)
    let written = bytes.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
    close(writer)
    try #require(written == bytes.count)
    #expect(try await readWithoutWaiting(holding) == .problem(.failed))

    // A link to a status file, and a link to nothing.
    let target = try Fixtures.temporaryDirectory().appendingPathComponent("status.json")
    try Data(text.utf8).write(to: target)
    #expect(ExtensionRepositoryStatus.read(target) == .extensions(3))
    let link = try Fixtures.temporaryDirectory().appendingPathComponent("status.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(ExtensionRepositoryStatus.read(link) == .problem(.failed))
    let dangling = try Fixtures.temporaryDirectory().appendingPathComponent("status.json")
    try FileManager.default.createSymbolicLink(
        at: dangling, withDestinationURL: target.deletingLastPathComponent().appendingPathComponent("gone.json"))
    #expect(ExtensionRepositoryStatus.read(dangling) == .problem(.failed))
}
