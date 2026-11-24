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
            address: address, branch: one["branch"] as? String, existing: try added(one["existing"] as? [String] ?? []),
            raycastListed: one["raycastListed"] as? Bool ?? true)
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

@Test func repositoriesAreReadAndWrittenWithOffOnlyWhenTrue() throws {
    let file = try settingsFile(#"{ "theme": "dark" }"#)
    var settings = FudgeSettings.load(from: file)
    #expect(settings.extensionRepositories.isEmpty && settings.raycastRepository)
    try settings.save(to: file)
    #expect(try object(file)["extensionRepositories"] == nil && object(file)["raycastRepository"] == nil)

    let tools = try ExtensionRepository.parse(address: " https://github.com/Someone/Tools ", branch: "main").get()
    let team = try ExtensionRepository.parse(address: "https://git.example.org/team/extensions", existing: [tools])
        .get()
    settings.extensionRepositories = [
        ListedRepository(repository: tools), ListedRepository(repository: team, on: false),
    ]
    settings.raycastRepository = false
    try settings.save(to: file)
    let written = try object(file)
    #expect(written["theme"] as? String == "dark", "a key Fudge doesn't know is kept")
    #expect(written["raycastRepository"] as? String == "off")
    let entries = try #require(written["extensionRepositories"] as? [[String: Any]])
    #expect(entries.count == 2)
    #expect(entries[0]["address"] as? String == "https://github.com/Someone/Tools", "as typed, without the spaces")
    #expect(entries[0]["branch"] as? String == "main" && entries[0]["off"] == nil)
    #expect(entries[1]["branch"] == nil && entries[1]["off"] as? Bool == true)
    #expect(Set(entries[1].keys) == ["address", "off"])
    #expect(FudgeSettings.load(from: file) == settings)

    settings.extensionRepositories = []
    settings.raycastRepository = true
    try settings.save(to: file)
    #expect(try object(file)["extensionRepositories"] == nil && object(file)["raycastRepository"] == nil)
}

@Test func readingSkipsEntriesSettingsWouldRefuse() throws {
    let file = try settingsFile(
        #"""
        { "raycastRepository": 0, "extensionRepositories": [
            { "address": "https://github.com/someone/tools", "off": 1 },
            { "address": "https://github.com/Someone/Tools.git" },
            { "address": "https://github.com/raycast/extensions" },
            { "address": "http://git.example.org/team/extensions" },
            { "address": "https://git.example.org/team/extensions", "branch": "a..b" },
            { "address": "https://git.example.org/team/extensions", "branch": 7 },
            { "address": 5 }, "https://git.example.org/other/extensions",
            { "address": "https://git.example.org/team/extensions", "branch": " dev ", "off": false }
        ] }
        """#)
    let settings = FudgeSettings.load(from: file)
    #expect(settings.raycastRepository, "only a JSON false turns Raycast's off")
    #expect(
        settings.extensionRepositories.map(\.repository.address) == [
            "https://github.com/someone/tools", "https://git.example.org/team/extensions",
        ])
    #expect(settings.extensionRepositories.map(\.on) == [true, true], "only a JSON true turns one off")
    #expect(settings.extensionRepositories.last?.repository.branch == "dev")

    // An eleventh is skipped as Settings would refuse it.
    let eleven = (0...10).map { #"{ "address": "https://git.example.org/team-\#($0)/extensions" }"# }
    let full = try settingsFile(#"{ "extensionRepositories": [\#(eleven.joined(separator: ","))] }"#)
    #expect(FudgeSettings.load(from: full).extensionRepositories.count == 10)
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

@Test func theStoreIsAnsweredWithRaycastsFirstThenTheAddedOnes() throws {
    let file = try settingsFile(
        #"""
        { "raycastRepository": false, "extensionRepositories": [
            { "address": "https://github.com/Someone/Tools", "branch": "main" },
            { "address": "https://github.com/Raycast/Extensions.git" },
            { "address": "https://git.example.org/team/extensions", "off": true }
        ] }
        """#)
    #expect(
        ExtensionRepository.storeAnswer(settings: FudgeSettings.load(from: file))
            == .array([
                entry([
                    "copyId": "raycast", "folder": "raycast/extensions",
                    "address": "https://github.com/raycast/extensions", "name": "raycast/extensions", "on": false,
                ]),
                entry([
                    "copyId": ExtensionRepository.copyId(of: "https://github.com/someone/tools"),
                    "folder": "someone/tools", "address": "https://github.com/Someone/Tools", "branch": "main",
                    "name": "Someone/Tools", "on": true,
                ]),
                entry([
                    "copyId": ExtensionRepository.copyId(of: "https://git.example.org/team/extensions"),
                    "folder": "git.example.org/team/extensions", "address": "https://git.example.org/team/extensions",
                    "name": "git.example.org/team/extensions", "on": false,
                ]),
            ]), "Raycast's own address added by hand is left out")
    #expect(
        ExtensionRepository.storeAnswer(settings: FudgeSettings())
            == .array([
                entry([
                    "copyId": "raycast", "folder": "raycast/extensions",
                    "address": "https://github.com/raycast/extensions", "name": "raycast/extensions", "on": true,
                ])
            ]))
}

// MARK: - Raycast's official repository like any other (SPEC-160)

/// Ten added repositories, as `settings.json` would hold them.
private func tenAdded() throws -> [ExtensionRepository] {
    try added((1...10).map { "https://github.com/owner/repository-\($0)" })
}

@Test func raycastsRepositoryIsListedFirstAndOnInAFreshFile() throws {
    let file = try settingsFile("{}")
    let settings = FudgeSettings.load(from: file)
    #expect(settings.raycastRepositoryState == .on && settings.raycastRepositoryListed)
    #expect(!settings.showsAddRaycastRepository)
    guard case .array(let answer) = ExtensionRepository.storeAnswer(settings: settings),
        case .object(let first) = try #require(answer.first)
    else {
        Issue.record("not an array of objects")
        return
    }
    #expect(first["copyId"] == .string("raycast"))
    #expect(first["name"] == .string("raycast/extensions"))
    #expect(first["address"] == .string("https://github.com/raycast/extensions"))
    #expect(first["on"] == .bool(true))
    #expect(ExtensionRepositoryText.raycastName == "raycast/extensions")
    #expect(ExtensionRepositoryText.raycastAddress == "https://github.com/raycast/extensions")
    #expect(ExtensionRepository.raycastAddress == "https://github.com/raycast/extensions.git", "the clone address")
}

@Test func removingRaycastsRepositoryTakesItOutOfTheAnswerAndRestoringPutsItFirst() throws {
    let file = try settingsFile(#"{ "theme": "dark" }"#)
    var settings = FudgeSettings.load(from: file)
    let tools = try ExtensionRepository.parse(address: "https://github.com/someone/tools").get()
    settings.extensionRepositories = [ListedRepository(repository: tools)]
    settings.removeRaycastRepository()
    try settings.save(to: file)
    #expect(try object(file)["raycastRepository"] as? String == "removed")
    let removed = FudgeSettings.load(from: file)
    #expect(removed.raycastRepositoryState == .removed && !removed.raycastRepositoryListed)
    #expect(removed.showsAddRaycastRepository)
    #expect(
        ExtensionRepository.storeAnswer(settings: removed)
            == .array([
                entry([
                    "copyId": tools.copyId, "folder": "someone/tools", "address": "https://github.com/someone/tools",
                    "name": "someone/tools", "on": true,
                ])
            ]), "no Raycast entry at all")

    var restored = removed
    restored.restoreRaycastRepository()
    try restored.save(to: file)
    #expect(try object(file)["raycastRepository"] == nil, "the key leaves settings.json")
    #expect(try object(file)["theme"] as? String == "dark")
    let back = FudgeSettings.load(from: file)
    #expect(back.raycastRepositoryState == .on && !back.showsAddRaycastRepository)
    guard case .array(let answer) = ExtensionRepository.storeAnswer(settings: back) else {
        Issue.record("not an array")
        return
    }
    #expect(answer.count == 2)
    guard case .object(let first) = try #require(answer.first) else { return }
    #expect(first["copyId"] == .string("raycast") && first["on"] == .bool(true), "first and on")

    // Switched off, it stays in the list, and Add Raycast's Repository doesn't show.
    var off = back
    off.raycastRepository = false
    #expect(off.raycastRepositoryState == .off && off.raycastRepositoryListed && !off.showsAddRaycastRepository)
}

@Test func raycastRepositoryReadsTodaysFalseAsOffAndAnythingUnknownAsOn() throws {
    let cases: [(String, RaycastRepositoryState)] = [
        (#"{ "raycastRepository": false }"#, .off),
        (#"{ "raycastRepository": "off" }"#, .off),
        (#"{ "raycastRepository": "removed" }"#, .removed),
        (#"{ "raycastRepository": "on" }"#, .on),
        (#"{ "raycastRepository": "Removed" }"#, .on),
        (#"{ "raycastRepository": true }"#, .on),
        (#"{ "raycastRepository": 0 }"#, .on),
        (#"{ "raycastRepository": ["removed"] }"#, .on),
        (#"{ }"#, .on),
    ]
    for (text, state) in cases {
        #expect(FudgeSettings.load(from: try settingsFile(text)).raycastRepositoryState == state, "\(text)")
    }
    // Written only when not on, and the old false comes back as "off".
    let file = try settingsFile(#"{ "raycastRepository": false }"#)
    try FudgeSettings.load(from: file).save(to: file)
    #expect(try object(file)["raycastRepository"] as? String == "off")
    #expect(Backup.consentKeys.contains("raycastRepository"), "an import never takes it")

    // A saved list is parsed as Settings always parses it: Raycast's address written into it by hand is skipped, even
    // while Raycast's is removed, so it never becomes a second Raycast entry.
    let handEdited = try settingsFile(
        #"""
        { "raycastRepository": "removed", "extensionRepositories": [
            { "address": "https://github.com/Raycast/Extensions.git" },
            { "address": "https://github.com/someone/tools" }
        ] }
        """#)
    let settings = FudgeSettings.load(from: handEdited)
    #expect(settings.raycastRepositoryState == .removed)
    #expect(settings.extensionRepositories.map(\.repository.address) == ["https://github.com/someone/tools"])
}

@Test func raycastsAddressGivesRaycastsOwnEntryOnlyWhileItIsRemoved() throws {
    for address in [
        "https://github.com/raycast/extensions", " https://github.com/Raycast/Extensions.git ",
        "https://github.com:443/raycast/extensions/",
    ] {
        #expect(
            ExtensionRepository.parse(address: address) == .failure(.folder(.alreadyListed)),
            "listed: \(address)")
        let repository = try ExtensionRepository.parse(address: address, raycastListed: false).get()
        #expect(repository.copyId == "raycast" && repository.folder == "raycast/extensions")
        #expect(repository.name == "raycast/extensions" && repository.identity == ExtensionRepository.raycastIdentity)
        #expect(repository.branch == nil && repository.address == ExtensionRepository.trimmed(address))
        // However many are added: Raycast's isn't counted.
        #expect(
            try ExtensionRepository.parse(address: address, existing: tenAdded(), raycastListed: false).get().copyId
                == "raycast")
    }
    for branch in ["main", "a..b", " dev "] {
        #expect(
            ExtensionRepository.parse(
                address: "https://github.com/Raycast/Extensions", branch: branch, raycastListed: false)
                == .failure(.raycastBranch), "\(branch)")
    }
    #expect(
        ExtensionRepository.parse(address: "https://github.com/raycast/extensions", branch: "  ", raycastListed: false)
            .map(\.copyId) == .success("raycast"), "a blank branch is the default one")
    #expect(
        ExtensionRepository.Refusal.raycastBranch.description
            == "Raycast's official repository always follows its default branch.")
    // Any other address is parsed as always, whether Raycast's is listed or not.
    #expect(
        ExtensionRepository.parse(address: "https://github.com/someone/tools", raycastListed: false)
            == ExtensionRepository.parse(address: "https://github.com/someone/tools"))
    #expect(
        ExtensionRepository.parse(
            address: "https://github.com/owner/repository-11", existing: try tenAdded(),
            raycastListed: false) == .failure(.tooMany))
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
    let refused = draft.add(existing: [], raycastListed: true)
    #expect(refused == nil)
    #expect(draft.address == "http://github.com/owner/repository" && draft.branch == "main")
    #expect(draft.reason == "Use an https:// address, such as https://github.com/owner/repository.")
}

@Test func anAcceptedAddressGivesTheRepositoryWithItsBranch() throws {
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/owner/repository"
    draft.branch = "main"
    let accepted = draft.add(existing: [], raycastListed: true)
    let listed = try #require(accepted)
    let repository = listed.repository
    #expect(listed.label == nil && listed.on, "no name typed")
    #expect(repository.copyId == ExtensionRepository.copyId(of: "https://github.com/owner/repository"))
    #expect(repository.branch == "main" && repository.name == "owner/repository")
    #expect(draft.reason == nil)
    var settings = FudgeSettings()
    settings.addRepository(listed)
    #expect(settings.extensionRepositories == [ListedRepository(repository: repository, on: true)], "saved on")
}

@Test func theListPassedAtAddCountsNotAnEarlierOne() throws {
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/owner/repository"
    let early = draft.add(existing: [], raycastListed: true)
    #expect(early != nil)
    let now = try added(["https://github.com/Owner/Repository.git"])
    let atAdd = draft.add(existing: now.map { ListedRepository(repository: $0) }, raycastListed: true)
    #expect(atAdd == nil)
    #expect(draft.reason == "That repository is already in the list.")
}

@Test func tenAddedRepositoriesAreTheMost() throws {
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/owner/repository-11"
    let eleventh = draft.add(existing: try tenAdded().map { ListedRepository(repository: $0) }, raycastListed: true)
    #expect(eleventh == nil)
    #expect(draft.reason == "You can add up to 10 repositories.")
}

@Test func aCorrectedAddressClearsTheReason() throws {
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://user@github.com/owner/repository"
    let refused = draft.add(existing: [], raycastListed: true)
    #expect(refused == nil)
    #expect(draft.reason == "Leave the user name and password out of the address.")
    draft.address = "https://github.com/owner/repository"
    let corrected = draft.add(existing: [], raycastListed: true)
    #expect(corrected != nil)
    #expect(draft.reason == nil)
    // A failed save shows its problem until the next Add, and Cancel starts over.
    draft.saveFailed("settings.json isn't valid JSON.")
    #expect(draft.reason == "settings.json isn't valid JSON." && draft.address == "https://github.com/owner/repository")
    #expect(draft.cancelled() == ExtensionRepositoryDraft())
}

@Test func raycastsAddressInTheWindowPutsRaycastsRepositoryBack() throws {
    var settings = FudgeSettings()
    settings.extensionRepositories = try tenAdded().map { ListedRepository(repository: $0) }
    settings.removeRaycastRepository()
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/Raycast/Extensions.git"
    draft.branch = "main"
    let withBranch = draft.add(
        existing: settings.extensionRepositories, raycastListed: settings.raycastRepositoryListed)
    #expect(withBranch == nil)
    #expect(draft.reason == "Raycast's official repository always follows its default branch.")
    draft.branch = ""
    let back = draft.add(
        existing: settings.extensionRepositories, raycastListed: settings.raycastRepositoryListed)
    let raycast = try #require(back)
    #expect(raycast.repository.copyId == "raycast" && draft.reason == nil, "even with 10 added")
    settings.addRepository(raycast)
    #expect(settings.raycastRepositoryState == .on && settings.extensionRepositories.count == 10, "never a second copy")
    guard case .array(let answer) = ExtensionRepository.storeAnswer(settings: settings),
        case .object(let first) = try #require(answer.first)
    else {
        Issue.record("not an array of objects")
        return
    }
    #expect(answer.count == 11 && first["copyId"] == .string("raycast"), "first")
    // Once it's back, its address is refused again.
    let again = draft.add(existing: settings.extensionRepositories, raycastListed: settings.raycastRepositoryListed)
    #expect(again == nil)
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
