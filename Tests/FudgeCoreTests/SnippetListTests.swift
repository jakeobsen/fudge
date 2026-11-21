import Foundation
import Testing

@testable import FudgeCore

private let context = QuicklinkTemplate.Context(
    clipboard: "copied", now: Date(timeIntervalSince1970: 1_795_255_200), locale: Locale(identifier: "en_US"),
    timeZone: TimeZone(identifier: "UTC")!, calendar: Calendar(identifier: .gregorian), makeUUID: { "U-1" })

private let snippets = [
    Snippet(id: "s", name: "signature", text: "Best,\nme", keyword: "sig"),
    Snippet(id: "a", name: "Address", text: "1 Main St"),
    Snippet(id: "t", name: "Today", text: "It's {day}, {cursor}"),
]

@Test func searchSnippetsListsThemByNameWithTheirDetail() throws {
    let view = SnippetList.view(snippets: snippets, context: context)
    var list = ListContent(view, searchText: "")
    #expect(list.isShowingDetail)
    #expect(list.items.map(\.title) == ["Address", "signature", "Today"])
    #expect(list.items.map(\.itemId) == ["a", "s", "t"], "the selection follows a snippet across renders")
    let signature = try #require(list.items.first { $0.itemId == "s" })
    #expect(signature.detail?.string("markdown") == "```\nBest,\nme\n```")
    #expect(
        MetadataEntry.entries(of: signature.detail?.node("metadata")) == [
            .label(title: "Keyword", text: "sig", color: nil, icon: nil)
        ])
    let today = try #require(list.items.first { $0.itemId == "t" })
    #expect(
        today.detail?.string("markdown") == "```\nIt's {day}, {cursor}\n```\n\nPastes as:\n\n```\nIt's Saturday, \n```")
    // The name, the keyword and the start of the text match.
    list.search("sig")
    #expect(list.items.map(\.itemId) == ["s"])
    list.search("main st")
    #expect(list.items.map(\.itemId) == ["a"])
}

@Test func itsActionsArePasteCopyEditDeleteAndCreate() throws {
    let view = SnippetList.view(snippets: snippets, context: context)
    let list = ListContent(view, searchText: "")
    let address = try #require(list.items.first)
    let sections = ActionPanelReader.sections(of: address.actions)
    let entries = sections.flatMap(\.entries)
    #expect(
        entries.map(\.title) == [
            "Paste Snippet", "Copy to Clipboard", "Edit Snippet…", "Delete Snippet…", "Create Snippet",
        ])
    #expect(
        entries.map(\.shortcut) == [
            nil, nil, SnippetList.editShortcut, SnippetList.deleteShortcut, SnippetList.createShortcut,
        ])
    #expect(entries[3].destructive)
    let targets = entries.map { entry -> SnippetList.Target? in
        guard case .node(let node) = entry.target else { return nil }
        return SnippetList.target(of: node, in: snippets)
    }
    #expect(targets == [.paste(id: "a"), .copy(id: "a"), .edit(id: "a"), .delete(id: "a"), .create])
    #expect(SnippetList.target(of: address.id, in: snippets) == nil, "the item itself runs nothing")
    #expect(SnippetList.target(of: 100 + 20 * 3 + 7, in: snippets) == nil, "past the last snippet")
}

@Test func withNoSnippetsItOffersToCreateOne() throws {
    let list = ListContent(SnippetList.view(snippets: [], context: context), searchText: "")
    #expect(list.items.isEmpty && !list.isShowingDetail)
    let empty = try #require(list.emptyView)
    #expect(empty.title == "No Snippets")
    let create = try #require(ActionPanelReader.sections(of: empty.actions).first?.entries.first)
    #expect(create.target == .node(4))
    #expect(SnippetList.target(of: 4, in: []) == .create)
}

@Test func theDetailsCodeBlockCantBeClosedByTheText() {
    #expect(SnippetList.codeBlock("a ``` b") == "````\na ``` b\n````")
    let markdown = SnippetList.codeBlock("```\nnot the end\n```")
    let blocks = Markdown.blocks(markdown)
    #expect(blocks == [.code(language: nil, text: "```\nnot the end\n```")])
}
