import Foundation
import Testing

@testable import FudgeCore

/// `runtime/test/fixtures/repository-folders.json`, which the runtime's `repository-folder.ts` is tested against too.
private func folderFixture() throws -> [String: Any] {
    let file = Fixtures.repository.appendingPathComponent("runtime/test/fixtures/repository-folders.json")
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}

@Test func eachRefusalHasTheFixturesOneSentence() throws {
    let sentences = try #require(try folderFixture()["sentences"] as? [String: String])
    #expect(Set(sentences.keys) == Set(ExtensionRepositoryFolder.Refusal.allCases.map(\.rawValue)))
    for refusal in ExtensionRepositoryFolder.Refusal.allCases {
        #expect(refusal.description == sentences[refusal.rawValue], "\(refusal)")
    }
}

@Test func aRepositorysFolderIsTheFixturesOrRefusedWithItsReason() throws {
    let cases = try #require(try folderFixture()["folders"] as? [[String: Any]])
    #expect(cases.count > 50)
    for one in cases {
        let host = try #require(one["host"] as? String)
        let segments = try #require(one["segments"] as? [String])
        let port = one["port"] as? Int
        let result = ExtensionRepositoryFolder.folder(host: host, port: port, segments: segments)
        if let folder = one["folder"] as? String {
            #expect(result == .success(folder), "\(one)")
            #expect(ExtensionRepositoryFolder.isValid(folder), "\(folder)")
        } else {
            let refused = try #require(
                (one["refused"] as? String).flatMap(ExtensionRepositoryFolder.Refusal.init(rawValue:)), "\(one)")
            #expect(result == .failure(refused), "\(one)")
        }
    }
}

@Test func isValidAcceptsExactlyTheFoldersTheRuleGives() throws {
    let fixture = try folderFixture()
    let valid = try #require(fixture["valid"] as? [String])
    let invalid = try #require(fixture["invalid"] as? [String])
    #expect(valid.contains(ExtensionRepositoryFolder.raycast) && valid.contains(ExtensionRepositoryFolder.development))
    #expect(invalid.contains("development") && invalid.contains("../x"))
    for folder in valid { #expect(ExtensionRepositoryFolder.isValid(folder), "\(folder)") }
    for folder in invalid { #expect(!ExtensionRepositoryFolder.isValid(folder), "\(folder.debugDescription)") }
}

@Test func aFolderEqualToAnotherOrInsideOneOrHoldingOneIsRefused() throws {
    let cases = try #require(try folderFixture()["conflicts"] as? [[String: Any]])
    for one in cases {
        let folder = try #require(one["folder"] as? String)
        let existing = try #require(one["existing"] as? [String])
        let refused = (one["refused"] as? String).flatMap(ExtensionRepositoryFolder.Refusal.init(rawValue:))
        #expect(ExtensionRepositoryFolder.conflict(folder, with: existing) == refused, "\(one)")
    }
}
