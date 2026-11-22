import Foundation
import Testing

@testable import FudgeCore

private func installed(_ json: String) throws -> InstalledExtension {
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    return InstalledExtension.topLevel(
        manifest: manifest, directory: URL(fileURLWithPath: "/nonexistent/\(manifest.name)"))
}

private let inbox = """
    {"name": "inbox", "title": "Inbox", "commands": [
      {"name": "unread", "title": "Unread Count", "mode": "no-view"},
      {"name": "search", "title": "Search Mail", "subtitle": "Mail", "mode": "view"},
      {"name": "status", "title": "Status", "mode": "menu-bar"}
    ]}
    """

@Test func commandMetadataWritesReadsAndResets() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("nested/command-metadata.json")
    #expect(CommandMetadata.load(from: file) == CommandMetadata(), "a missing file is empty")

    var metadata = CommandMetadata()
    metadata.setSubtitle("3 unread", extension: "inbox", command: "unread")
    metadata.setSubtitle("", extension: "inbox", command: "search")
    try metadata.save(to: file)

    let read = CommandMetadata.load(from: file)
    #expect(read == metadata)
    #expect(read.subtitle(extension: "inbox", command: "unread") == "3 unread")
    #expect(read.subtitle(extension: "inbox", command: "search") == "", "an empty subtitle is a subtitle")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: String]]
    #expect(json == ["inbox/unread": ["subtitle": "3 unread"], "inbox/search": ["subtitle": ""]])

    var reset = read
    reset.setSubtitle(nil, extension: "inbox", command: "unread")
    try reset.save(to: file)
    #expect(CommandMetadata.load(from: file).subtitles == ["inbox/search": ""])
}

@Test func commandMetadataReadsTolerantly() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("command-metadata.json")
    try Data(#"{"a/b": {"subtitle": "kept"}, "a/c": {"subtitle": 3}, "a/d": "text", "a/e": {}}"#.utf8).write(to: file)
    #expect(CommandMetadata.load(from: file).subtitles == ["a/b": "kept"])
    try Data("not json".utf8).write(to: file)
    #expect(CommandMetadata.load(from: file) == CommandMetadata())
}

@Test func commandMetadataPrunesCommandsThatArentInstalled() {
    var metadata = CommandMetadata(subtitles: ["inbox/unread": "1", "inbox/gone": "2", "removed/x": "3"])
    let dropped = metadata.prune(keeping: ["inbox/unread", "inbox/search"])
    #expect(dropped)
    #expect(metadata.subtitles == ["inbox/unread": "1"])
    let droppedAgain = metadata.prune(keeping: ["inbox/unread"])
    #expect(!droppedAgain, "nothing left to drop")
}

@Test func commandMetadataKeepsKeysItDoesntKnow() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("command-metadata.json")
    try Data(#"{"a/b": {"subtitle": "x", "future": [1, "two"]}, "a/c": {"other": true}}"#.utf8).write(to: file)
    var metadata = CommandMetadata.load(from: file)
    #expect(metadata.subtitles == ["a/b": "x"])

    metadata.setSubtitle(nil, extension: "a", command: "b")
    metadata.setSubtitle("new", extension: "a", command: "c")
    try metadata.save(to: file)
    let written = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
    #expect(
        written == [
            "a/b": .object(["future": .array([.number(1), .string("two")])]),
            "a/c": .object(["other": .bool(true), "subtitle": .string("new")]),
        ], "a reset keeps the entry's other keys")

    let dropped = metadata.prune(keeping: ["a/c"])
    #expect(dropped)
    try metadata.save(to: file)
    let pruned = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
    #expect(Array(pruned.keys) == ["a/c"], "pruning drops the whole entry")
}

@Test func anEmptyListingPrunesNothing() {
    var metadata = CommandMetadata(subtitles: ["a/b": "x"])
    let dropped = metadata.prune(keeping: [])
    #expect(!dropped, "an extensions folder that couldn't be read doesn't wipe the file")
    #expect(metadata.subtitles == ["a/b": "x"])

    var store = MenuBarStore(active: ["a/menu"])
    let deactivated = store.prune(keeping: [])
    #expect(!deactivated, "nor deactivate every menu bar item")
    #expect(store.active == ["a/menu"])
}

@Test func commandMetadataReadsTheUpdateParams() throws {
    #expect(try CommandMetadata.subtitle(fromParams: .object(["subtitle": .string("x")])) == "x")
    #expect(try CommandMetadata.subtitle(fromParams: .object(["subtitle": .null])) == nil)
    #expect(try CommandMetadata.subtitle(fromParams: .object([:])) == nil, "no subtitle goes back to the manifest's")
    #expect(throws: CommandMetadata.InvalidMetadata("subtitle must be a string or null")) {
        try CommandMetadata.subtitle(fromParams: .object(["subtitle": .number(3)]))
    }
    #expect(throws: CommandMetadata.InvalidMetadata("metadata must be an object")) {
        try CommandMetadata.subtitle(fromParams: .null)
    }
    #expect(
        CommandMetadata.InvalidMetadata("metadata must be an object").description
            == "updateCommandMetadata: metadata must be an object")
}

@Test func rootItemsShowTheSetSubtitleThenTheManifestsThenTheExtensionTitle() throws {
    let inbox = try installed(inbox)
    let plain = RootItem.commands(of: inbox)
    #expect(plain.map(\.title) == ["Unread Count", "Search Mail", "Status"])
    #expect(plain.map(\.subtitle) == ["Inbox", "Mail", "Inbox"])
    #expect(plain.map(\.extensionTitle) == ["Inbox", "Inbox", "Inbox"])

    var metadata = CommandMetadata()
    metadata.setSubtitle("3 unread", extension: "inbox", command: "unread")
    metadata.setSubtitle("Gmail", extension: "inbox", command: "search")
    metadata.setSubtitle("elsewhere", extension: "other", command: "unread")
    metadata.setSubtitle("2 new", extension: "inbox", command: "status")
    #expect(RootItem.commands(of: inbox, metadata: metadata).map(\.subtitle) == ["3 unread", "Gmail", "2 new"])
}

@Test func rootSearchStillFindsACommandByItsExtensionTitleWhenItShowsAnotherSubtitle() throws {
    var metadata = CommandMetadata()
    metadata.setSubtitle("3 unread", extension: "inbox", command: "unread")
    let items = RootItem.commands(of: try installed(inbox), metadata: metadata)
    let found = RootSearch.rank(items, query: "inbox", history: LaunchHistory()).map(\.title)
    #expect(found == ["Search Mail", "Status", "Unread Count"])
    #expect(RootSearch.rank(items, query: "unread", history: LaunchHistory()).first?.title == "Unread Count")
}

@Test func commandMetadataNeverOverwritesAFileItCantRead() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("command-metadata.json")
    var metadata = CommandMetadata()
    metadata.setSubtitle("3 unread", extension: "inbox", command: "unread")
    for unreadable in ["not json", "[1, 2]", "\"text\"", "{\"a/b\": "] {
        try Data(unreadable.utf8).write(to: file)
        #expect(!CommandMetadata.isWritable(file), "\(unreadable)")
        #expect(throws: CommandMetadata.Unreadable()) { try metadata.save(to: file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == unreadable, "left as it is")
    }
    #expect(
        CommandMetadata.Unreadable().description
            == "Fudge can't read command-metadata.json, so it leaves the file as it is. Fix or remove it, then try again."
    )

    // A blank file, a missing one and a JSON object are written.
    try Data("  \n".utf8).write(to: file)
    try metadata.save(to: file)
    #expect(CommandMetadata.load(from: file).subtitles == ["inbox/unread": "3 unread"])
    try FileManager.default.removeItem(at: file)
    #expect(CommandMetadata.isWritable(file))
    try metadata.save(to: file)
    #expect(CommandMetadata.isWritable(file))
}
