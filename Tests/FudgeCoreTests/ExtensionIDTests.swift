import Foundation
import Testing

@testable import FudgeCore

/// The id rule, against `runtime/test/fixtures/extension-ids.json`, which the runtime's `isValidExtensionId` is
/// tested against too.
@Test func validatesIdsAsTheSharedFixtureSays() throws {
    let file = Fixtures.repository.appendingPathComponent("runtime/test/fixtures/extension-ids.json")
    let ids = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let valid = try #require(ids["valid"] as? [String])
    let invalid = try #require(ids["invalid"] as? [String])
    #expect(!valid.isEmpty && !invalid.isEmpty)
    for id in valid {
        #expect(ExtensionID.isValid(id), "\(id)")
        #expect(ExtensionID(stored: id)?.key == id, "\(id)")
    }
    for id in invalid {
        #expect(!ExtensionID.isValid(id), "\(id.debugDescription)")
        #expect(ExtensionID(stored: id) == nil, "\(id.debugDescription)")
    }
    #expect(valid.contains("fudgeapp+development+github") && invalid.contains("raycast+extensions+github"))
}

@Test func anInstallsIdIsTheBareNameInRaycastsFolderElseTheFolderAndNameJoinedWithPlus() {
    #expect(ExtensionID(name: "github", repositoryFolder: "raycast/extensions")?.key == "github")
    #expect(
        ExtensionID(name: "github", repositoryFolder: "fudgeapp/development")?.key == "fudgeapp+development+github")
    #expect(ExtensionID(name: "github", repositoryFolder: "someone/tools")?.key == "someone+tools+github")
    #expect(
        ExtensionID(name: "github", repositoryFolder: "git.example.org/team/extensions")?.key
            == "git.example.org+team+extensions+github")
    #expect(
        ExtensionID(name: "github", repositoryFolder: "git.example.org_8443/team/extensions")?.key
            == "git.example.org_8443+team+extensions+github")
    // A name that isn't one, and a folder that isn't one, give no id.
    #expect(ExtensionID(name: "Github", repositoryFolder: "someone/tools") == nil)
    #expect(ExtensionID(name: "x+github", repositoryFolder: "git.example.org/team") == nil)
    #expect(ExtensionID(name: "github", repositoryFolder: "Someone/tools") == nil)
    #expect(ExtensionID(name: "github", repositoryFolder: "development") == nil)
    #expect(ExtensionID(name: "github", repositoryFolder: "") == nil)
}

@Test func noQualifiedIdEqualsABundledName() throws {
    let bundled = [ExtensionStore.id, ClipboardHistory.id, FileSearch.id, BundledExtensions.emojiID]
    for id in bundled {
        #expect(ExtensionID.isValid(id.key))
        #expect(!id.key.contains(ExtensionID.separator))
        for folder in ["someone/tools", "fudgeapp/development", "git.example.org/team"] {
            let qualified = try #require(ExtensionID(name: id.key, repositoryFolder: folder))
            #expect(qualified != id && !bundled.contains(qualified))
        }
    }
}

@Test func anIdIsCodedAsItsStringAndCheckedWhenDecoded() throws {
    let id = try #require(ExtensionID(stored: "someone+tools+github"))
    let data = try JSONEncoder().encode([id])
    #expect(String(decoding: data, as: UTF8.self) == #"["someone+tools+github"]"#)
    #expect(try JSONDecoder().decode([ExtensionID].self, from: data) == [id])
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode([ExtensionID].self, from: Data(#"["Bad Key"]"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode([ExtensionID].self, from: Data(#"["raycast+extensions+github"]"#.utf8))
    }
}

/// Without `CodingKeyRepresentable`, Swift writes a dictionary keyed by a struct as an array, and today's files no
/// longer read.
@Test func aDictionaryKeyedByAnIdEncodesAsAJSONObjectAndDecodesFromOne() throws {
    let github = try #require(ExtensionID(stored: "github"))
    let added = try #require(ExtensionID(stored: "someone+tools+github"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode([github: true, added: false])
    #expect(String(decoding: data, as: UTF8.self) == #"{"github":true,"someone+tools+github":false}"#)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Bool])
    #expect(object == ["github": true, "someone+tools+github": false])
    #expect(try JSONDecoder().decode([ExtensionID: Bool].self, from: data) == [github: true, added: false])
    // One key the rule refuses fails the whole dictionary, which is why a store reads its keys as strings.
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode([ExtensionID: Bool].self, from: Data(#"{"github":true,"Bad Key":true}"#.utf8))
    }
    #expect(ExtensionID(codingKey: StringCodingKey("Bad Key")) == nil)
    #expect(ExtensionID(codingKey: StringCodingKey("github")) == github)
}
