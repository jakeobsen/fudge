import Foundation
import Testing

@testable import FudgeCore

private func decode(_ json: String) throws -> ExtensionManifest {
    try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
}

@Test func decodesCommandsPreferencesAndArguments() throws {
    let manifest = try ExtensionManifest.load(from: Fixtures.greeter.appendingPathComponent("package.json"))
    #expect(manifest.name == "greeter")
    #expect(manifest.title == "Greeter")
    #expect(manifest.icon == "icon.png")
    #expect(manifest.commands.map(\.name) == ["greet", "quiet"])
    #expect(manifest.commands.map(\.mode) == ["view", "no-view"])
    #expect(manifest.commands[0].keywords == ["hello"])
    #expect(manifest.commands[1].arguments.map(\.name) == ["who"])
    #expect(manifest.preferences.map(\.type) == ["checkbox", "dropdown"])
    #expect(manifest.preferences[0].default == .bool(true))
    #expect(manifest.preferences[1].data?.map(\.value) == ["warm", "cool"])
    #expect(!manifest.hasDependencies)
}

@Test func fillsInDefaultsForOptionalFields() throws {
    let manifest = try decode(#"{ "name": "x", "commands": [{ "name": "c", "title": "C" }] }"#)
    #expect(manifest.title == "x")
    #expect(manifest.preferences.isEmpty)
    #expect(manifest.commands[0].mode == "view")
    #expect(manifest.commands[0].keywords.isEmpty)
    #expect(manifest.commands[0].arguments.isEmpty)
}

@Test func notesWhetherTheExtensionHasDependencies() throws {
    #expect(try decode(#"{ "name": "x", "dependencies": { "@raycast/api": "^1" } }"#).hasDependencies)
    #expect(try decode(#"{ "name": "x", "devDependencies": { "typescript": "^5" } }"#).hasDependencies)
    #expect(try !decode(#"{ "name": "x", "dependencies": {} }"#).hasDependencies)
}

@Test func reportsAnUnreadableOrInvalidManifest() {
    let missing = URL(fileURLWithPath: "/nonexistent/package.json")
    #expect(throws: ManifestError.unreadable(missing.path)) { try ExtensionManifest.load(from: missing) }
    #expect(throws: (any Error).self) { try decode(#"{ "title": "no name" }"#) }
}

/// The Extension Store's `catalog.ts` is tested against the same file, so the two rules can't drift apart.
@Test func validatesNamesAsTheSharedFixtureSays() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("runtime/test/fixtures/extension-names.json")
    let names = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
    let valid = try #require(names["valid"] as? [String])
    let invalid = try #require(names["invalid"] as? [String])
    #expect(!valid.isEmpty && !invalid.isEmpty)
    for name in valid { #expect(ExtensionManifest.isValidName(name), "\(name)") }
    for name in invalid { #expect(!ExtensionManifest.isValidName(name), "\(name)") }
}
