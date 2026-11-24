import Foundation
import Testing

@testable import FudgeCore

/// Repository names (SPEC-174 B): typed in the Add Repository window, kept in `settings.json`, shown as the label.
private func settingsFile(_ text: String) throws -> URL {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(text.utf8).write(to: file)
    return file
}

private func object(_ file: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}

private func listed(_ address: String, label: String? = nil, existing: [ListedRepository] = []) throws
    -> ListedRepository
{
    ListedRepository(
        repository: try ExtensionRepository.parse(address: address, existing: existing.map(\.repository)).get(),
        label: label)
}

/// The Add window with `address` and `name` typed, pressed: the reason, or the name it accepted.
private func add(
    _ name: String, address: String = "https://github.com/owner/repository", existing: [ListedRepository] = []
) -> (accepted: ListedRepository?, reason: String?) {
    var draft = ExtensionRepositoryDraft()
    draft.address = address
    draft.label = name
    let accepted = draft.add(existing: existing)
    #expect(draft.label == name, "what was typed stays")
    return (accepted, draft.reason)
}

/// Each refused character, inside a name: a zero-width space (Cf), a bidi override (Cf), a line separator (Zl), a
/// paragraph separator (Zp), a no-break space and an em space (spaces other than U+0020), a tab and a bell (Cc).
private let refusedCharacters = ["\u{200B}", "\u{202E}", "\u{2028}", "\u{2029}", "\u{00A0}", "\u{2003}", "\t", "\u{7}"]

@Test func theAddWindowsNameIsCheckedAfterTheAddressInOrder() throws {
    let jakeobsen = try listed("https://github.com/jakeobsen/raycast", label: "jakeobsen")
    let sentences: [(String, String)] = [
        ("a/b", "A name can't have a slash in it."),
        ("a/\u{200B}" + String(repeating: "x", count: 41), "A name can't have a slash in it."),
        ("x\u{200B}" + String(repeating: "x", count: 41), "That name has characters Fudge can't use."),
        (String(repeating: "x", count: 41), "Use a name of up to 40 characters."),
        (" DEVELOPMENT ", "Fudge uses that name for your development builds."),
        ("core", "Fudge uses that name for its own extensions."),
        ("JakeObsen", "Another repository is already called jakeobsen."),
    ]
    for (name, sentence) in sentences {
        let (accepted, reason) = add(name, existing: [jakeobsen])
        #expect(accepted == nil && reason == sentence, "\(name.debugDescription)")
    }
    for character in refusedCharacters {
        let (accepted, reason) = add("jake\(character)obsen")
        #expect(
            accepted == nil && reason == "That name has characters Fudge can't use.", "\(character.debugDescription)")
    }
    // The address's own refusals come first.
    #expect(
        add("a/b", address: "http://github.com/owner/repository").reason
            == ExtensionRepository.Refusal.https.description)
    #expect(
        add("a/b", address: "https://github.com/jakeobsen/raycast", existing: [jakeobsen]).reason
            == "That repository is already in the list.")

    let trimmed = add("  my tools\n", existing: [jakeobsen])
    #expect(trimmed.reason == nil && trimmed.accepted?.label == "my tools", "trimmed, a space inside kept")
    let forty = String(repeating: "é", count: 40)
    #expect(add(forty).accepted?.label == forty, "40 characters, however many bytes")
    #expect(add(" \u{00A0}jakeobsen\u{2028} ").accepted?.label == "jakeobsen", "only inside is refused")
    let none = add("   ")
    #expect(none.reason == nil && none.accepted != nil && none.accepted?.label == nil, "empty is no name")

    // Raycast's own entry takes the name typed with it, as any repository does.
    let raycast = add("mine", address: "https://github.com/raycast/extensions")
    #expect(raycast.reason == nil && raycast.accepted?.repository.copyId == "raycast")
    #expect(raycast.accepted?.label == "mine")
    let plain = add("", address: "https://github.com/raycast/extensions")
    #expect(plain.accepted?.repository.copyId == "raycast" && plain.accepted?.label == nil)
}

@Test func aNameIsWrittenOnlyWhenThereIsOneAndReadBack() throws {
    let file = try settingsFile(#"{ "theme": "dark" }"#)
    var settings = FudgeSettings.load(from: file)
    let jakeobsen = try listed("https://github.com/JakeObsen/Raycast", label: "jakeobsen")
    let tools = try listed("https://github.com/someone/tools", existing: [jakeobsen])
    settings.addRepository(jakeobsen)
    settings.addRepository(tools)
    try settings.save(to: file)
    let entries = try #require(try object(file)["repositories"] as? [[String: Any]])
    #expect(entries.count == 3)
    #expect(Set(entries[0].keys) == ["address"], "Raycast's, with no name")
    #expect(entries[1]["name"] as? String == "jakeobsen")
    #expect(Set(entries[2].keys) == ["address"], "no name, no key")
    let read = FudgeSettings.load(from: file)
    #expect(read == settings)
    #expect(read.extensionRepositories.map(\.label) == [nil, "jakeobsen", nil])
    #expect(ExtensionRepositoryText.rowName(read.extensionRepositories[0]) == "raycast/extensions")
    #expect(ExtensionRepositoryText.rowName(read.extensionRepositories[1]) == "jakeobsen")
    #expect(ExtensionRepositoryText.rowName(read.extensionRepositories[2]) == "someone/tools")
    guard case .array(let answer) = ExtensionRepository.storeAnswer(settings: read),
        case .object(let named) = answer[1], case .object(let unnamed) = answer[2]
    else {
        Issue.record("not Raycast's and two added entries")
        return
    }
    #expect(named["label"] == .string("jakeobsen") && named["name"] == .string("JakeObsen/Raycast"))
    #expect(unnamed["label"] == nil)
}

/// `settings.json`'s repositories, read from `entries`.
private func read(_ entries: [[String: Any]]) throws -> [ListedRepository] {
    let data = try JSONSerialization.data(withJSONObject: ["repositories": entries])
    return FudgeSettings.load(from: try settingsFile(String(decoding: data, as: UTF8.self))).extensionRepositories
}

@Test func readingDropsANameTheRuleRefusesOrAnEarlierOneHas() throws {
    let three = try read([
        ["address": "https://github.com/first/tools", "name": " jakeobsen "],
        ["address": "https://github.com/second/tools", "name": "JAKEOBSEN"],
        ["address": "https://github.com/third/tools", "name": 7],
    ])
    #expect(three.count == 3, "every entry stays, with or without its name")
    #expect(three[0].label == "jakeobsen", "trimmed")
    #expect(three[1].label == nil, "a later duplicate is no name; the earlier one keeps it")
    #expect(three[2].label == nil, "not text")
    let refused =
        ["a/b", String(repeating: "x", count: 41), "Core", "CORE", "development", "Development"]
        + refusedCharacters.map { "jake\($0)obsen" }
    for name in refused {
        let one = try read([["address": "https://github.com/someone/tools", "name": name]])
        #expect(one.count == 1 && one[0].label == nil, "\(name.debugDescription)")
    }
    for name in ["raycast", "Raycast", "Fudge"] {
        let one = try read([["address": "https://github.com/someone/tools", "name": name]])
        #expect(one.count == 1 && one[0].label == name, "kept: \(name)")
    }
}

@Test func raycastAndFudgeAreNamesLikeAnyOther() throws {
    for name in ["raycast", "Raycast", "Fudge", "fudge"] {
        let (accepted, reason) = add(name)
        #expect(reason == nil && accepted?.label == name, "accepted with nothing listed: \(name)")
        #expect(RepositoryNames.check(name) == .success(name))
    }
    for name in ["Raycast", "Fudge"] {
        let named = try listed("https://github.com/someone/tools", label: name)
        let (accepted, reason) = add(name.uppercased(), existing: [named])
        #expect(accepted == nil && reason == "Another repository is already called \(name).", "taken: \(name)")
    }
    #expect(RepositoryNames.check("cOrE") == .failure(.core))
    #expect(RepositoryNames.core == "Core")
}

/// SPEC-174 B5: naming a repository means removing it and adding it back, which keeps its extensions' ids and
/// everything kept by them.
@Test func removingARepositoryAndAddingItBackWithANameKeepsItsExtensions() throws {
    let file = try settingsFile(
        #"""
        {
          "repositories": [{ "address": "https://github.com/Someone/Tools", "branch": "main" }],
          "commands": { "someone+tools+github/search": { "alias": "gh", "hotkey": "option+g", "enabled": false } },
          "extensions": { "someone+tools+github": { "enabled": false } }
        }
        """#)
    let before = try object(file)
    let first = try #require(FudgeSettings.load(from: file).extensionRepositories.first?.repository)
    let id = try #require(ExtensionID(name: "github", repositoryFolder: first.folder))

    // Settings' remove: read, take it out, save.
    var removed = FudgeSettings.load(from: file)
    removed.extensionRepositories.removeAll { $0.repository.copyId == first.copyId }
    try removed.save(to: file)
    // Settings' add: read, check what was typed against the list as it is now, save.
    var adding = FudgeSettings.load(from: file)
    var draft = ExtensionRepositoryDraft()
    draft.address = "https://github.com/someone/tools.git"
    draft.label = "tools"
    let added = draft.add(existing: adding.extensionRepositories)
    let accepted = try #require(added)
    adding.addRepository(accepted)
    try adding.save(to: file)

    let after = try object(file)
    let back = try #require(FudgeSettings.load(from: file).extensionRepositories.first)
    #expect(back.label == "tools" && back.repository.branch == nil, "named; its branch is typed again")
    #expect(back.repository.folder == first.folder && back.repository.copyId == first.copyId)
    #expect(ExtensionID(name: "github", repositoryFolder: back.repository.folder) == id, "the same ids")
    #expect(NSDictionary(dictionary: try #require(after["commands"] as? [String: Any])).isEqual(before["commands"]))
    #expect(NSDictionary(dictionary: try #require(after["extensions"] as? [String: Any])).isEqual(before["extensions"]))
}
