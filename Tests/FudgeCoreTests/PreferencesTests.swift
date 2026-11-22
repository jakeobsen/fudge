import Foundation
import Testing

@testable import FudgeCore

private func manifest(_ json: String) throws -> ExtensionManifest {
    try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
}

private let scratch = """
    {
      "name": "scratch",
      "commands": [
        { "name": "folders", "title": "Folders",
          "preferences": [{ "name": "sort", "type": "dropdown", "data": [
            { "title": "Newest", "value": "newest" }, { "title": "Name", "value": "name" }] }] }
      ],
      "preferences": [
        { "name": "openInEditor", "type": "checkbox", "default": true },
        { "name": "quiet", "type": "checkbox" },
        { "name": "staleDays", "type": "textfield", "default": "7" },
        { "name": "scratchRoot", "type": "directory" },
        { "name": "editorApp", "type": "appPicker", "default": "/Applications/Code.app" },
        { "name": "token", "type": "password", "required": true }
      ]
    }
    """

private let fakeApplications: @Sendable (String) -> JSONValue? = { reference in
    reference.hasSuffix("Missing.app") ? nil : .object(["name": .string("App"), "path": .string(reference)])
}

@Test func usesStoredValuesThenDefaultsThenTypeDefaults() throws {
    let manifest = try manifest(scratch)
    let stored = StoredPreferences(
        extensionValues: ["staleDays": .string("14"), "token": .string("secret")],
        commandValues: ["folders": ["sort": .string("name")]]
    )
    let resolved = PreferenceResolver.resolve(
        manifest,
        command: manifest.commands[0],
        stored: stored,
        application: fakeApplications
    )
    #expect(
        resolved.values == [
            "openInEditor": .bool(true),
            "quiet": .bool(false),
            "staleDays": .string("14"),
            "editorApp": .object(["name": .string("App"), "path": .string("/Applications/Code.app")]),
            "token": .string("secret"),
            "sort": .string("name"),
        ]
    )
    #expect(resolved.missing.isEmpty)
}

@Test func reportsRequiredPreferencesWithoutAValue() throws {
    let manifest = try manifest(scratch)
    let resolved = PreferenceResolver.resolve(
        manifest,
        command: manifest.commands[0],
        stored: StoredPreferences(),
        application: fakeApplications
    )
    #expect(resolved.missing.map(\.name) == ["token"])
    #expect(resolved.values["scratchRoot"] == nil, "optional preferences without a value are left out")
    #expect(resolved.values["sort"] == .string("newest"), "a dropdown falls back to its first option")
}

@Test func anAppPickerThatCantBeFoundIsLeftOut() throws {
    let manifest = try manifest(
        #"{ "name": "x", "commands": [{ "name": "c", "title": "C" }], "preferences": [{ "name": "app", "type": "appPicker", "default": "/Applications/Missing.app" }] }"#
    )
    let resolved = PreferenceResolver.resolve(
        manifest,
        command: manifest.commands[0],
        stored: StoredPreferences(),
        application: fakeApplications
    )
    #expect(resolved.values["app"] == nil)
}

@Test func storesPreferencesPerExtension() throws {
    let store = PreferenceStore(directory: try Fixtures.temporaryDirectory().appendingPathComponent("preferences"))
    let scratch = ExtensionID(stored: "scratch")!
    #expect(store.load(scratch) == StoredPreferences())
    let preferences = StoredPreferences(
        extensionValues: ["staleDays": .string("3")],
        commandValues: ["folders": ["sort": .string("name")]]
    )
    try store.save(preferences, for: scratch)
    #expect(store.load(scratch) == preferences)
    #expect(store.load(ExtensionID(stored: "other")!) == StoredPreferences())
}

@Test func resolvesApplicationsByPathWithTheirBundleIdentifier() throws {
    let folder = try Fixtures.temporaryDirectory()
    let app = folder.appendingPathComponent("Fake Editor.app")
    try FileManager.default.createDirectory(
        at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "io.example.fake-editor", "CFBundleName": "Fake Editor"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))

    #expect(
        ApplicationResolver.resolve(app.path)
            == .object([
                "name": .string("Fake Editor"), "path": .string(app.path),
                "bundleId": .string("io.example.fake-editor"),
            ])
    )
    #expect(ApplicationResolver.resolve("/nonexistent/Nothing.app") == nil)
}
