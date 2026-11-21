import Foundation

/// Fudge's own Search Snippets view (SPEC-078 §3): a List built here as an extension's would arrive, so the launcher
/// draws it, filters it and takes its keys like any other. As with `SnippetForm`, it never reaches the extension
/// host: its session is Fudge's (`session`), and the launcher answers its actions itself.
public enum SnippetList {
    public static let session = "fudge:snippets"
    public static let title = "Search Snippets"

    /// What one of its actions does.
    public enum Target: Sendable, Equatable {
        /// ↵: pastes the snippet into the app the user was in.
        case paste(id: String)
        /// ⌘↵: copies it.
        case copy(id: String)
        /// ⌘E: opens it in the form.
        case edit(id: String)
        /// ⌃X: deletes it, after asking.
        case delete(id: String)
        /// ⌘N, and the empty view's action: opens the form for a new one.
        case create
    }

    public static let pasteShortcut = KeyShortcut(key: "return", modifiers: [])
    public static let editShortcut = KeyShortcut(key: "e", modifiers: ["cmd"])
    public static let deleteShortcut = KeyShortcut(key: "x", modifiers: ["ctrl"])
    public static let createShortcut = KeyShortcut(key: "n", modifiers: ["cmd"])

    /// Its nodes' ids. Each snippet's nodes are a block of `stride` from `firstItem`, in the order shown.
    enum Node {
        static let list = 1
        static let empty = 2
        static let emptyActions = 3
        static let emptyCreate = 4
        static let firstItem = 100
        static let stride = 20
        // Offsets inside a snippet's block.
        static let item = 0
        static let detail = 1
        static let metadata = 2
        static let keyword = 3
        static let actions = 5
        static let useSection = 6
        static let paste = 7
        static let copy = 8
        static let manageSection = 9
        static let edit = 10
        static let delete = 11
        static let create = 12
    }

    /// The snippets in the order the view shows them: by name, ignoring case.
    public static func sorted(_ snippets: [Snippet]) -> [Snippet] {
        snippets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The List: one item per snippet, as `sorted` orders them, with the detail pane showing its text, what that
    /// pastes as when it has placeholders (filled with `context`), and its keyword. Raycast's own filtering applies:
    /// the name, the keyword and the start of the text match. With no snippets, the empty view offers Create Snippet.
    public static func view(snippets: [Snippet], context: QuicklinkTemplate.Context) -> UINode {
        var children = sorted(snippets).enumerated().map { index, snippet in
            item(snippet, base: Node.firstItem + index * Node.stride, context: context)
        }
        let create = action(Node.emptyCreate, "Create Snippet", icon: "plus-16", shortcut: createShortcut)
        children.append(
            UINode(
                id: Node.empty, type: "List.EmptyView",
                props: [
                    "title": .string("No Snippets"),
                    "description": .string("Save text you use often, then paste it from here."),
                    "icon": .string("text-cursor-16"),
                    "actions": UINode(id: Node.emptyActions, type: "ActionPanel", children: [create]).json,
                ]))
        return UINode(
            id: Node.list, type: "List",
            props: [
                "navigationTitle": .string(title), "searchBarPlaceholder": .string("Search snippets"),
                "isShowingDetail": .bool(!snippets.isEmpty),
            ],
            children: children)
    }

    /// What the action `node` does, in the view built from `snippets`; nil for any other node.
    public static func target(of node: Int, in snippets: [Snippet]) -> Target? {
        if node == Node.emptyCreate { return .create }
        guard node >= Node.firstItem else { return nil }
        let index = (node - Node.firstItem) / Node.stride
        let ordered = sorted(snippets)
        guard index < ordered.count else { return nil }
        let id = ordered[index].id
        switch (node - Node.firstItem) % Node.stride {
        case Node.paste: return .paste(id: id)
        case Node.copy: return .copy(id: id)
        case Node.edit: return .edit(id: id)
        case Node.delete: return .delete(id: id)
        case Node.create: return .create
        default: return nil
        }
    }

    /// How many characters of the text search looks at: enough for its start, without fuzzy-matching 100,000.
    static let searchedTextLength = 200

    private static func item(_ snippet: Snippet, base: Int, context: QuicklinkTemplate.Context) -> UINode {
        var keywords = [String(snippet.text.prefix(searchedTextLength))]
        if let keyword = snippet.keyword { keywords.insert(keyword, at: 0) }
        let actions = UINode(
            id: base + Node.actions, type: "ActionPanel",
            children: [
                UINode(
                    id: base + Node.useSection, type: "ActionPanel.Section",
                    children: [
                        action(base + Node.paste, "Paste Snippet", icon: "copy-clipboard-16", shortcut: nil),
                        action(base + Node.copy, "Copy to Clipboard", icon: "copy-clipboard-16", shortcut: nil),
                    ]),
                UINode(
                    id: base + Node.manageSection, type: "ActionPanel.Section",
                    children: [
                        action(base + Node.edit, "Edit Snippet…", icon: "pencil-16", shortcut: editShortcut),
                        action(
                            base + Node.delete, "Delete Snippet…", icon: "trash-16", shortcut: deleteShortcut,
                            destructive: true),
                        action(base + Node.create, "Create Snippet", icon: "plus-16", shortcut: createShortcut),
                    ]),
            ])
        var labels: [UINode] = []
        if let keyword = snippet.keyword {
            labels.append(
                UINode(
                    id: base + Node.keyword, type: "Metadata.Label",
                    props: ["title": .string("Keyword"), "text": .string(keyword)]))
        }
        var detailProps: [String: JSONValue] = ["markdown": .string(markdown(for: snippet, context: context))]
        if !labels.isEmpty {
            detailProps["metadata"] =
                UINode(id: base + Node.metadata, type: "Metadata", children: labels).json
        }
        return UINode(
            id: base + Node.item, type: "List.Item",
            props: [
                "id": .string(snippet.id), "title": .string(snippet.name), "icon": .string("text-cursor-16"),
                "keywords": .array(keywords.map(JSONValue.string)), "actions": actions.json,
                "detail": UINode(id: base + Node.detail, type: "List.Item.Detail", props: detailProps).json,
            ])
    }

    private static func action(
        _ id: Int, _ title: String, icon: String, shortcut: KeyShortcut?, destructive: Bool = false
    ) -> UINode {
        var props: [String: JSONValue] = ["title": .string(title), "icon": .string(icon)]
        if let shortcut {
            props["shortcut"] = .object([
                "key": .string(shortcut.key), "modifiers": .array(shortcut.modifiers.sorted().map(JSONValue.string)),
            ])
        }
        if destructive { props["style"] = .string("destructive") }
        return UINode(id: id, type: "Action", props: props)
    }

    /// The detail's markdown: the text as it's saved, in a code block so nothing in it is read as markdown, and,
    /// when it has placeholders, what it pastes as now.
    static func markdown(for snippet: Snippet, context: QuicklinkTemplate.Context) -> String {
        let template = SnippetTemplate(snippet.text)
        var markdown = codeBlock(snippet.text)
        let hasPlaceholders = template.segments.contains { if case .placeholder = $0 { true } else { false } }
        if hasPlaceholders, template.problem == nil {
            markdown += "\n\nPastes as:\n\n" + codeBlock(template.fill(context: context).text)
        }
        return markdown
    }

    /// `text` as a fenced code block, its fence longer than any run of backticks inside it, so no line closes it.
    static func codeBlock(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text)\n\(fence)"
    }
}
