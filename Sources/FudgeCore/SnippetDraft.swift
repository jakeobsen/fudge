import Foundation

/// What an extension's `Action.CreateSnippet` asks for: its `snippet` prop, Raycast's `Snippet` (`text`, and
/// optionally `name` and `keyword`).
public struct SnippetRequest: Sendable, Equatable {
    public var text: String
    public var name: String?
    public var keyword: String?

    public init(text: String, name: String? = nil, keyword: String? = nil) {
        self.text = text
        self.name = name
        self.keyword = keyword
    }

    /// The prop as the host sends it; nil without a `text`.
    public init?(json: JSONValue) {
        guard case .object(let object) = json, case .string(let text) = object["text"] else { return nil }
        var name: String?
        if case .string(let value) = object["name"], !value.isEmpty { name = value }
        var keyword: String?
        if case .string(let value) = object["keyword"], !value.isEmpty { keyword = value }
        self.init(text: text, name: name, keyword: keyword)
    }
}

/// What the Create Snippet form holds: a new snippet, or one being edited (`id` set).
public struct SnippetDraft: Sendable, Equatable {
    public var id: String?
    public var name: String
    public var text: String
    /// Empty for none.
    public var keyword: String
    public var createdAt: String?

    public init(id: String? = nil, name: String = "", text: String = "", keyword: String = "", createdAt: String? = nil)
    {
        self.id = id
        self.name = name
        self.text = text
        self.keyword = keyword
        self.createdAt = createdAt
    }

    public init(editing snippet: Snippet) {
        self.init(
            id: snippet.id, name: snippet.name, text: snippet.text, keyword: snippet.keyword ?? "",
            createdAt: snippet.createdAt)
    }

    /// The form an extension's `Action.CreateSnippet` opens: its text, its name or else the command's title, and its
    /// keyword.
    public init(request: SnippetRequest, commandTitle: String) {
        self.init(name: request.name ?? commandTitle, text: request.text, keyword: request.keyword ?? "")
    }

    public struct Problems: Sendable, Equatable {
        public var name: String?
        public var text: String?
        public var keyword: String?

        public init(name: String? = nil, text: String? = nil, keyword: String? = nil) {
            self.name = name
            self.text = text
            self.keyword = keyword
        }

        public var isEmpty: Bool { name == nil && text == nil && keyword == nil }
    }

    /// What's wrong with it, field by field, among the snippets already saved (the edited one left out):
    ///
    /// - a name of 1–64 characters that no other snippet has, ignoring case and spaces around it;
    /// - some text, at most 100,000 characters, with no placeholder problem (`SnippetTemplate`);
    /// - an optional keyword of 1–32 characters with no whitespace, that neither contains another snippet's keyword
    ///   nor is contained in one, ignoring case (`Snippet.keywordsClash`).
    public func problems(among existing: [Snippet]) -> Problems {
        var problems = Problems()
        let others = existing.filter { $0.id != id }
        let name = trimmedName
        if name.isEmpty {
            problems.name = "Enter a name."
        } else if name.count > Snippet.nameLimit {
            problems.name = "Use at most \(Snippet.nameLimit) characters."
        } else if others.contains(where: { $0.name.trimmed.caseInsensitiveCompare(name) == .orderedSame }) {
            problems.name = "Another snippet is called “\(name)”."
        }
        if text.trimmed.isEmpty {
            problems.text = "Enter the snippet."
        } else if text.count > Snippet.textLimit {
            problems.text = "Use at most 100,000 characters."
        } else if let problem = SnippetTemplate(text).problem {
            problems.text = problem
        }
        let keyword = trimmedKeyword
        if !keyword.isEmpty {
            if !Snippet.isValidKeyword(keyword) {
                problems.keyword = "Use 1–\(Snippet.keywordLimit) characters, with no spaces."
            } else if let other = others.first(where: { $0.keyword.map { Snippet.keywordsClash($0, keyword) } == true }
            ),
                let theirs = other.keyword
            {
                problems.keyword =
                    theirs.caseInsensitiveCompare(keyword) == .orderedSame
                    ? "“\(other.name)” already has this keyword."
                    : "It overlaps “\(theirs)”, the keyword of “\(other.name)”: one can't contain the other."
            }
        }
        return problems
    }

    var trimmedName: String { name.trimmed }
    var trimmedKeyword: String { keyword.trimmed }

    /// Saves it: a new snippet, or over the edited one by `id`. The name and keyword are trimmed; the text is kept
    /// exactly as typed, since a snippet may end with a space or a new line on purpose.
    @discardableResult
    public func save(into store: inout SnippetStore, now: Date = Date()) -> Snippet {
        let snippet = Snippet(
            id: id ?? UUID().uuidString, name: trimmedName, text: text,
            keyword: trimmedKeyword.isEmpty ? nil : trimmedKeyword, createdAt: createdAt ?? now.formatted(.iso8601))
        if !store.replace(snippet) { store.add(snippet) }
        return snippet
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The Create Snippet form, built here and shown by the app like an extension's Form, as `QuicklinkForm` is: its
/// fields are uncontrolled with fixed node ids, and nothing of it reaches the host.
public enum SnippetForm {
    public static let session = "fudge:snippet-form"

    public enum Node {
        public static let form = 1
        public static let name = 2
        public static let text = 3
        public static let keyword = 4
        public static let actions = 5
        public static let save = 6
    }

    public enum Field {
        public static let name = "name"
        public static let text = "text"
        public static let keyword = "keyword"
    }

    public static let textInfo =
        "Use {clipboard}, {date}, {time}, {day} or {uuid}, and {cursor} for where the cursor ends up."

    public static func title(for draft: SnippetDraft) -> String {
        draft.id == nil ? "Create Snippet" : "Edit Snippet"
    }

    /// The Form: Name, Snippet (several lines) and Keyword, starting on `draft`, with each field's problem as its
    /// `error`, and one action, Save Snippet.
    public static func view(draft: SnippetDraft, problems: SnippetDraft.Problems = .init()) -> UINode {
        func field(_ id: Int, _ type: String, _ props: [String: JSONValue], error: String?) -> UINode {
            var props = props
            if let error { props["error"] = .string(error) }
            return UINode(id: id, type: type, props: props)
        }
        let save = UINode(
            id: Node.save, type: "Action", props: ["title": .string("Save Snippet"), "icon": .string("checkmark-16")])
        let actions = UINode(id: Node.actions, type: "ActionPanel", children: [save])
        return UINode(
            id: Node.form, type: "Form",
            props: ["navigationTitle": .string(title(for: draft)), "actions": actions.json],
            children: [
                field(
                    Node.name, "Form.TextField",
                    [
                        "id": .string(Field.name), "title": .string("Name"), "placeholder": .string("Snippet name"),
                        "defaultValue": .string(draft.name),
                    ], error: problems.name),
                field(
                    Node.text, "Form.TextArea",
                    [
                        "id": .string(Field.text), "title": .string("Snippet"), "info": .string(textInfo),
                        "defaultValue": .string(draft.text),
                    ], error: problems.text),
                field(
                    Node.keyword, "Form.TextField",
                    [
                        "id": .string(Field.keyword), "title": .string("Keyword"),
                        "placeholder": .string("Optional, like /addr"), "defaultValue": .string(draft.keyword),
                    ], error: problems.keyword),
            ])
    }

    /// `draft` with what the form's fields hold, by field `id`.
    public static func draft(_ draft: SnippetDraft, with values: [String: JSONValue]) -> SnippetDraft {
        var draft = draft
        if case .string(let name) = values[Field.name] { draft.name = name }
        if case .string(let text) = values[Field.text] { draft.text = text }
        if case .string(let keyword) = values[Field.keyword] { draft.keyword = keyword }
        return draft
    }
}
