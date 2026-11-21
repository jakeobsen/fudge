import Foundation

/// An application a quicklink can open with: Open With's choices.
public struct QuicklinkApplication: Sendable, Equatable {
    public var name: String
    public var bundleId: String
    public var path: String

    public init(name: String, bundleId: String, path: String) {
        self.name = name
        self.bundleId = bundleId
        self.path = path
    }
}

/// What an extension's `Action.CreateQuicklink` asks for: its `quicklink` prop (Raycast's `Quicklink`). The icon is
/// accepted but not used.
public struct QuicklinkRequest: Sendable, Equatable {
    /// Raycast's `Quicklink.application`: a name or bundle id, or an `Application`.
    public enum Application: Sendable, Equatable {
        case text(String)
        case application(name: String?, path: String?, bundleId: String?)
    }

    public var link: String
    public var name: String?
    public var application: Application?

    public init(link: String, name: String? = nil, application: Application? = nil) {
        self.link = link
        self.name = name
        self.application = application
    }

    /// Reads the `quicklink` prop; nil without a `link`.
    public init?(json: JSONValue?) {
        guard case .object(let object) = json, case .string(let link) = object["link"] else { return nil }
        func text(_ value: JSONValue?) -> String? {
            if case .string(let text) = value, !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
            return nil
        }
        var application: Application?
        switch object["application"] {
        case .string(let text) where !text.trimmingCharacters(in: .whitespaces).isEmpty:
            application = .text(text)
        case .object(let app):
            application = .application(
                name: text(app["name"]), path: text(app["path"]), bundleId: text(app["bundleId"]))
        default:
            application = nil
        }
        self.init(link: link, name: text(object["name"]), application: application)
    }
}

/// A quicklink as the Create Quicklink form and the Settings page edit it, and the rules for saving it (SPEC-052 B).
public struct QuicklinkDraft: Sendable, Equatable {
    /// The quicklink being edited; nil for a new one.
    public var id: String?
    public var name: String
    public var link: String
    /// A bundle id; nil for the default app.
    public var application: String?
    /// The edited quicklink's, kept as it was.
    public var createdAt: String?

    public init(
        id: String? = nil, name: String = "", link: String = "", application: String? = nil, createdAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.link = link
        self.application = application
        self.createdAt = createdAt
    }

    /// The form filled in with a saved quicklink, to edit it.
    public init(editing quicklink: Quicklink) {
        self.init(
            id: quicklink.id, name: quicklink.name, link: quicklink.link, application: quicklink.application,
            createdAt: quicklink.createdAt)
    }

    /// The form filled in from an extension's `Action.CreateQuicklink`: its link, its name or else the command's
    /// title, and its application when one of `applications` matches it (by bundle id, path or name, ignoring case),
    /// else the default app.
    public init(request: QuicklinkRequest, commandTitle: String, applications: [QuicklinkApplication]) {
        self.init(
            name: request.name ?? commandTitle, link: request.link,
            application: request.application.flatMap { Self.match($0, in: applications)?.bundleId })
    }

    static func match(_ reference: QuicklinkRequest.Application, in applications: [QuicklinkApplication])
        -> QuicklinkApplication?
    {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        func named(_ name: String) -> QuicklinkApplication? {
            let bare = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
            return applications.first { same($0.name, bare) }
        }
        switch reference {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let path = (trimmed as NSString).expandingTildeInPath
            return applications.first { same($0.bundleId, trimmed) } ?? applications.first { $0.path == path }
                ?? named(trimmed)
        case .application(let name, let path, let bundleId):
            if let bundleId, let found = applications.first(where: { same($0.bundleId, bundleId) }) { return found }
            if let path, let found = applications.first(where: { $0.path == path }) { return found }
            return name.flatMap(named)
        }
    }

    /// What keeps it from being saved, by field. Empty when it can be.
    public struct Problems: Sendable, Equatable {
        public var name: String?
        public var link: String?

        public init(name: String? = nil, link: String? = nil) {
            self.name = name
            self.link = link
        }

        public var isEmpty: Bool { name == nil && link == nil }
    }

    /// The name has 1–64 characters, not all spaces, and no other quicklink in `existing` has it, ignoring case. The
    /// link isn't empty, its placeholders have no problem, and it's a URL with a scheme or a path (absolute, or
    /// starting with `~/`); a link that starts with a placeholder, like `{clipboard}`, may be either.
    public func problems(among existing: [Quicklink]) -> Problems {
        var problems = Problems()
        let name = trimmedName
        if name.isEmpty {
            problems.name = "Enter a name."
        } else if name.count > Quicklink.nameLimit {
            problems.name = "Use at most \(Quicklink.nameLimit) characters."
        } else if existing.contains(where: {
            $0.id != id && $0.name.trimmed.caseInsensitiveCompare(name) == .orderedSame
        }) {
            problems.name = "Another quicklink is called “\(name)”."
        }
        let link = trimmedLink
        let template = QuicklinkTemplate(link)
        if link.isEmpty {
            problems.link = "Enter a link."
        } else if let problem = template.problem {
            problems.link = problem
        } else if template.isPath {
            if !(link == "~" || link.hasPrefix("~/") || link.hasPrefix("/")) {
                problems.link = "Start a path with / or ~/."
            }
        } else if template.scheme == nil, !link.hasPrefix("{") {
            problems.link = "Start the link with a scheme, like https://, or a path, like ~/Documents."
        }
        return problems
    }

    var trimmedName: String { name.trimmed }
    var trimmedLink: String { link.trimmed }

    /// Saves it into `store`: in place of the quicklink with its `id`, keeping that entry's other keys, or as a new
    /// one at the end (also when the edited one is gone). Returns what was saved. Check `problems` first.
    @discardableResult
    public func save(into store: inout QuicklinkStore, now: Date = Date()) -> Quicklink {
        let quicklink = Quicklink(
            id: id ?? UUID().uuidString, name: trimmedName, link: trimmedLink, application: application,
            createdAt: createdAt ?? now.formatted(.iso8601))
        if !store.replace(quicklink) { store.add(quicklink) }
        return quicklink
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Fudge's own Create Quicklink form in the launcher (SPEC-052 B1): a Form view, built here as an extension's would
/// arrive, so the launcher draws it and takes its keys like any other. It never reaches the extension host: its
/// session is Fudge's (`session`), and the launcher answers its events itself.
public enum QuicklinkForm {
    /// The session of the form on screen.
    public static let session = "fudge:quicklink-form"

    /// Its nodes' ids, fixed so that what was typed stays across renders (`FieldValue`).
    public enum Node {
        public static let form = 1
        public static let name = 2
        public static let link = 3
        public static let application = 4
        public static let actions = 5
        public static let save = 6
        static let firstItem = 100
    }

    /// The fields' `id`s, which name their values.
    public enum Field {
        public static let name = "name"
        public static let link = "link"
        public static let application = "application"
    }

    public static let linkInfo = #"Use {argument name="…"} for a field, or {clipboard}, {date}, {uuid}."#

    public static func title(for draft: QuicklinkDraft) -> String {
        draft.id == nil ? "Create Quicklink" : "Edit Quicklink"
    }

    /// The Form: Name, Link and Open With ("Default", then `applications` by name), starting on `draft`, with each
    /// field's problem as its `error`, and one action, Save Quicklink. An application `draft` names that isn't in
    /// `applications` is still offered, by its bundle id, so editing doesn't lose it.
    public static func view(
        draft: QuicklinkDraft, problems: QuicklinkDraft.Problems = .init(), applications: [QuicklinkApplication]
    ) -> UINode {
        var apps = applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let bundleId = draft.application, !apps.contains(where: { $0.bundleId == bundleId }) {
            apps.insert(QuicklinkApplication(name: bundleId, bundleId: bundleId, path: ""), at: 0)
        }
        var items = [
            UINode(
                id: Node.firstItem, type: "Form.Dropdown.Item",
                props: ["value": .string(""), "title": .string("Default")])
        ]
        for (index, app) in apps.enumerated() {
            var props: [String: JSONValue] = ["value": .string(app.bundleId), "title": .string(app.name)]
            if !app.path.isEmpty { props["icon"] = .object(["fileIcon": .string(app.path)]) }
            items.append(UINode(id: Node.firstItem + 1 + index, type: "Form.Dropdown.Item", props: props))
        }
        func field(_ id: Int, _ type: String, _ props: [String: JSONValue], error: String?) -> UINode {
            var props = props
            if let error { props["error"] = .string(error) }
            return UINode(id: id, type: type, props: props)
        }
        let save = UINode(
            id: Node.save, type: "Action",
            props: ["title": .string("Save Quicklink"), "icon": .string("checkmark-16")])
        let actions = UINode(id: Node.actions, type: "ActionPanel", children: [save])
        return UINode(
            id: Node.form, type: "Form",
            props: [
                "navigationTitle": .string(title(for: draft)),
                "actions": actions.json,
            ],
            children: [
                field(
                    Node.name, "Form.TextField",
                    [
                        "id": .string(Field.name), "title": .string("Name"), "placeholder": .string("Quicklink name"),
                        "defaultValue": .string(draft.name),
                    ], error: problems.name),
                field(
                    Node.link, "Form.TextField",
                    [
                        "id": .string(Field.link), "title": .string("Link"),
                        "placeholder": .string("https://example.com/search?q={argument}"),
                        "info": .string(linkInfo), "defaultValue": .string(draft.link),
                    ], error: problems.link),
                UINode(
                    id: Node.application, type: "Form.Dropdown",
                    props: [
                        "id": .string(Field.application), "title": .string("Open With"),
                        "defaultValue": .string(draft.application ?? ""),
                    ],
                    children: items),
            ])
    }

    /// `draft` with what the form's fields hold, by field `id`. "Default" is no application.
    public static func draft(_ draft: QuicklinkDraft, with values: [String: JSONValue]) -> QuicklinkDraft {
        var draft = draft
        if case .string(let name) = values[Field.name] { draft.name = name }
        if case .string(let link) = values[Field.link] { draft.link = link }
        if case .string(let application) = values[Field.application] {
            draft.application = application.isEmpty ? nil : application
        }
        return draft
    }
}

extension UINode {
    /// The node as JSON, as one arrives inside a prop (`actions`); `init(json:)` reads it back.
    public var json: JSONValue {
        .object([
            "id": .number(Double(id)), "type": .string(type), "props": .object(props),
            "children": .array(children.map(\.json)),
        ])
    }
}
