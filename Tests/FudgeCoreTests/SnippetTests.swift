import Foundation
import Testing

@testable import FudgeCore

private func temporaryFile() throws -> URL {
    let folder = try Fixtures.temporaryDirectory()
    return folder.appendingPathComponent("snippets.json")
}

@Test func snippetsRoundTripKeepingWhatFudgeDoesntKnow() throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try #"""
    {"version": 3, "snippets": [
      {"id": "a", "name": "Address", "text": "1 Main St", "keyword": "/addr", "createdAt": "2026-11-21T10:00:00Z", "color": "red"},
      {"id": "b", "name": "", "text": "no name"},
      {"id": "c", "name": "Bad keyword", "text": "x", "keyword": "has space"}
    ]}
    """#.write(to: file, atomically: true, encoding: .utf8)
    var store = SnippetStore.load(from: file)
    #expect(store.snippets.map(\.id) == ["a", "c"], "an entry with no name isn't a snippet")
    #expect(store.snippet(id: "c")?.keyword == nil, "a keyword that isn't one is left off")
    var address = try #require(store.snippet(id: "a"))
    address.text = "2 Main St"
    let replaced = store.replace(address)
    #expect(replaced)
    store.add(Snippet(id: "d", name: "Sig", text: "Best, {cursor}"))
    let removed = store.remove(id: "c")
    #expect(removed)
    try store.save(to: file)

    let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(saved["version"] as? Int == 3, "the file's other keys stay")
    let entries = try #require(saved["snippets"] as? [[String: Any]])
    #expect(entries.map { $0["id"] as? String } == ["a", "b", "d"], "the invalid entry stays as it was")
    #expect(entries[0]["color"] as? String == "red" && entries[0]["text"] as? String == "2 Main St")
    #expect(SnippetStore.load(from: file).snippets.map(\.name) == ["Address", "Sig"])
}

@Test func anUnreadableSnippetsFileIsNeverOverwritten() throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(SnippetStore.isWritable(file), "a missing file is fine")
    for broken in ["[1, 2]", "{\"snippets\": {}}", "not json"] {
        try broken.write(to: file, atomically: true, encoding: .utf8)
        #expect(!SnippetStore.isWritable(file))
        #expect(SnippetStore.load(from: file).snippets.isEmpty)
        #expect(throws: SnippetStore.Unreadable()) { try SnippetStore([Snippet(name: "x", text: "y")]).save(to: file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)
    }
}

@Test func keywordsFollowTheirRules() {
    #expect(Snippet.isValidKeyword("/addr") && Snippet.isValidKeyword(String(repeating: "k", count: 32)))
    #expect(!Snippet.isValidKeyword("") && !Snippet.isValidKeyword("a b") && !Snippet.isValidKeyword("tab\t"))
    #expect(!Snippet.isValidKeyword(String(repeating: "k", count: 33)))
    // No keyword may contain another, ignoring case (the reviewer's MUST 1).
    #expect(Snippet.keywordsClash("dt", "dtx"), "a prefix")
    #expect(Snippet.keywordsClash("dt", "xdt"), "a suffix: typing xdt would match both")
    #expect(Snippet.keywordsClash("dt", "adtb"), "inside: dt would fire before adtb is typed")
    #expect(Snippet.keywordsClash("DT", "xdt"), "ignoring case")
    #expect(Snippet.keywordsClash("dt", "dt"))
    #expect(!Snippet.keywordsClash("dt", "td") && !Snippet.keywordsClash("/addr", "/sig"))
}
