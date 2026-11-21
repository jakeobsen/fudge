import Foundation
import Testing

@testable import FudgeCore

private let saved = [
    Snippet(id: "a", name: "Address", text: "1 Main St", keyword: "/addr"),
    Snippet(id: "b", name: "Signature", text: "Best, me", keyword: "sig"),
]

@Test func aSnippetDraftSaysWhatsWrongFieldByField() {
    #expect(SnippetDraft().problems(among: saved) == .init(name: "Enter a name.", text: "Enter the snippet."))
    #expect(
        SnippetDraft(name: "  address ", text: "x").problems(among: saved).name
            == "Another snippet is called “address”.")
    #expect(SnippetDraft(name: String(repeating: "n", count: 65), text: "x").problems(among: saved).name != nil)
    #expect(SnippetDraft(name: "N", text: String(repeating: "t", count: 100_001)).problems(among: saved).text != nil)
    #expect(
        SnippetDraft(name: "N", text: "{argument}").problems(among: saved).text
            == "Fudge doesn't support “{argument}” in a snippet.")
    #expect(
        SnippetDraft(name: "N", text: "x", keyword: "two words").problems(among: saved).keyword
            == "Use 1–32 characters, with no spaces.")
    #expect(
        SnippetDraft(name: "N", text: "x", keyword: "/ADDR").problems(among: saved).keyword
            == "“Address” already has this keyword.")
    #expect(
        SnippetDraft(name: "N", text: "x", keyword: "xsig").problems(among: saved).keyword
            == "It overlaps “sig”, the keyword of “Signature”: one can't contain the other.")
    #expect(SnippetDraft(name: "N", text: "x", keyword: "si").problems(among: saved).keyword != nil, "inside another")
    #expect(SnippetDraft(name: "N", text: "x", keyword: "/new").problems(among: saved).isEmpty)
    // Editing a snippet doesn't clash with itself.
    #expect(SnippetDraft(editing: saved[0]).problems(among: saved).isEmpty)
}

@Test func savingTrimsTheNameAndKeywordButKeepsTheText() {
    var store = SnippetStore(saved)
    let now = Date(timeIntervalSince1970: 1_795_255_200)
    let added = SnippetDraft(name: " Thanks ", text: "Thanks, {cursor}\n", keyword: " ty ").save(into: &store, now: now)
    #expect(added.name == "Thanks" && added.keyword == "ty" && added.text == "Thanks, {cursor}\n")
    #expect(added.createdAt == "2026-11-21T10:00:00Z")
    var edited = SnippetDraft(editing: saved[1])
    edited.keyword = ""
    let changed = edited.save(into: &store, now: now)
    #expect(changed.id == "b" && changed.keyword == nil && store.snippets.count == 3)
}

@Test func createSnippetsRequestFillsTheForm() throws {
    let request = try #require(
        SnippetRequest(json: .object(["text": .string("Hi {cursor}"), "keyword": .string(";hi")])))
    #expect(
        SnippetDraft(request: request, commandTitle: "Greetings")
            == SnippetDraft(name: "Greetings", text: "Hi {cursor}", keyword: ";hi"))
    #expect(SnippetRequest(json: .object(["name": .string("No text")])) == nil)
}

@Test func theSnippetFormHasNameTextAndKeyword() {
    let view = SnippetForm.view(
        draft: SnippetDraft(name: "Sig", text: "Best", keyword: "sig"), problems: .init(keyword: "Taken"))
    #expect(view.type == "Form" && view.props["navigationTitle"] == .string("Create Snippet"))
    #expect(view.children.map(\.type) == ["Form.TextField", "Form.TextArea", "Form.TextField"])
    #expect(view.children.map(\.id) == [SnippetForm.Node.name, SnippetForm.Node.text, SnippetForm.Node.keyword])
    #expect(view.children[1].props["defaultValue"] == .string("Best"))
    #expect(view.children[2].props["error"] == .string("Taken"))
    let filled = SnippetForm.draft(
        SnippetDraft(id: "x"), with: ["name": .string("N"), "text": .string("T"), "keyword": .string("k")])
    #expect(filled == SnippetDraft(id: "x", name: "N", text: "T", keyword: "k"))
    #expect(SnippetForm.title(for: filled) == "Edit Snippet")
}

@Test func anActionCreateSnippetNodeRunsTheAppsForm() {
    func node(_ props: [String: JSONValue]) -> UINode {
        UINode(id: 7, type: "Action", props: props.merging(["title": .string("Create Snippet")]) { a, _ in a })
    }
    let snippet = JSONValue.object(["text": .string("Hi {cursor}"), "name": .string("Hi"), "keyword": .string(";hi")])
    #expect(
        ActionPanelReader.entry(node(["fudgeBuiltIn": .string("createSnippet"), "snippet": snippet]))?.target
            == .createSnippet(SnippetRequest(text: "Hi {cursor}", name: "Hi", keyword: ";hi")))
    #expect(
        ActionPanelReader.entry(node(["fudgeBuiltIn": .string("createSnippet")]))?.target == .node(7),
        "without a snippet it's the extension's own action")
    #expect(
        ActionPanelReader.entry(
            node(["fudgeBuiltIn": .string("createSnippet"), "snippet": .object(["name": .string("x")])]))?.target
            == .node(7))
}
