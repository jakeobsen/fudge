import Foundation
import Testing

@testable import FudgeCore

@Test func eachBuiltInGroupIsTodaysKey() {
    #expect(BuiltInGroup.apps.rawValue == BuiltInCommandGroup.apps.name)
    #expect(BuiltInGroup.calendar.rawValue == BuiltInCommandGroup.calendar.name)
    #expect(BuiltInGroup.system.rawValue == BuiltInCommandGroup.system.name)
    #expect(BuiltInGroup.tools.rawValue == BuiltInCommandGroup.tools.name)
    #expect(BuiltInGroup.windowManagement.rawValue == BuiltInCommandGroup.windowManagement.name)
    #expect(BuiltInGroup.quicklinks.rawValue == QuicklinkCommands.groupName)
    #expect(
        Set(BuiltInGroup.allCases.map(\.rawValue))
            == Set(BuiltInCommandGroup.all.map(\.name) + [QuicklinkCommands.groupName]))
    for group in BuiltInGroup.allCases { #expect(BuiltInCommandGroup.isValidName(group.rawValue), "\(group)") }
}

@Test func anOwnerIsReadBackFromItsKey() throws {
    for group in BuiltInGroup.allCases {
        #expect(CommandOwner(stored: group.rawValue) == .group(group), "\(group)")
        #expect(CommandOwner.group(group).key == group.rawValue)
    }
    #expect(CommandOwner(stored: ":system") == .group(.system))
    for key in ["github", "someone+tools+github", "fudgeapp+development+github", "fudge-extension-store"] {
        let id = try #require(ExtensionID(stored: key))
        #expect(CommandOwner(stored: key) == .extension(id), "\(key)")
        #expect(CommandOwner.extension(id).key == key)
    }
    for key in [":general", ":nope", ":", "Bad Key", "raycast+extensions+github", "", "github/search"] {
        #expect(CommandOwner(stored: key) == nil, "\(key.debugDescription)")
    }
}

@Test func aDictionaryKeyedByAnOwnerEncodesAsAJSONObject() throws {
    let github = CommandOwner.extension(try #require(ExtensionID(stored: "github")))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode([CommandOwner.group(.system): ["enabled": false], github: ["enabled": true]])
    #expect(String(decoding: data, as: UTF8.self) == #"{":system":{"enabled":false},"github":{"enabled":true}}"#)
    #expect(
        try JSONDecoder().decode([CommandOwner: [String: Bool]].self, from: data)
            == [.group(.system): ["enabled": false], github: ["enabled": true]])
    #expect(
        try JSONDecoder().decode([CommandOwner].self, from: Data(#"[":tools","github"]"#.utf8)) == [
            .group(.tools), github,
        ])
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode([CommandOwner].self, from: Data(#"[":nope"]"#.utf8))
    }
}
