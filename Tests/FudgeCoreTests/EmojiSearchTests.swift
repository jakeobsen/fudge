import Foundation
import Testing

@testable import FudgeCore

/// Search Emoji & Symbols leaves the search to Fudge's own filtering, the title and the keywords (`ListContent`). This
/// runs it on the extension's generated data, a Grid section per Unicode group, as the command renders it.
struct EmojiSearchTests {
    private struct Data: Decodable {
        struct Entry: Decodable {
            let emoji: String
            let name: String
            let keywords: [String]
            let group: Int
        }
        let groups: [String]
        let emoji: [Entry]
    }

    private static func grid() throws -> UINode {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime/emoji-extension/src/emoji.generated.json")
        let data = try JSONDecoder().decode(Data.self, from: Foundation.Data(contentsOf: file))
        var next = 2
        let sections: [[String: Any]] = data.groups.enumerated().map { index, group in
            let items: [[String: Any]] = data.emoji.filter { $0.group == index }.map { entry in
                next += 1
                return [
                    "id": next, "type": "Grid.Item",
                    "props": ["title": entry.name, "keywords": entry.keywords, "content": entry.emoji],
                    "children": [],
                ]
            }
            next += 1
            return ["id": next, "type": "Grid.Section", "props": ["title": group], "children": items]
        }
        let view: [String: Any] = ["id": 1, "type": "Grid", "props": ["columns": 8], "children": sections]
        return try JSONDecoder().decode(UINode.self, from: JSONSerialization.data(withJSONObject: view))
    }

    /// The search, the emoji it must find, and whether it's in the first row of 8. Many names start with "heart", so
    /// red heart comes later for that one.
    @Test(arguments: [
        ("thumbs", "thumbs up", true), ("+1", "thumbs up", true), ("grin", "grinning face", true),
        ("heart", "red heart", false),
    ])
    func aNameOrKeywordFindsTheEmoji(search: String, name: String, firstRow: Bool) throws {
        let results = ListContent(try Self.grid(), searchText: search).items.map(\.title)
        #expect(results.contains(name), "\(search)")
        if firstRow {
            #expect(results.firstIndex(of: name).map { $0 < 8 } == true, "\(name) is in the first row for \(search)")
        }
    }
}
