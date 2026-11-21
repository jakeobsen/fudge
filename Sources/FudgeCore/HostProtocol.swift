import Foundation

/// A node of an extension's UI, as the extension host sends it (see runtime/src/renderer/serialize.ts).
public struct UINode: Sendable, Equatable, Identifiable, Decodable {
    public var id: Int
    public var type: String
    public var props: [String: JSONValue]
    public var children: [UINode]

    public init(id: Int, type: String, props: [String: JSONValue] = [:], children: [UINode] = []) {
        self.id = id
        self.type = type
        self.props = props
        self.children = children
    }

    /// Reads a node that arrived inside a prop (`actions`, `detail`, `metadata`, …).
    public init?(json: JSONValue) {
        guard case .object(let object) = json,
            case .number(let id) = object["id"],
            case .string(let type) = object["type"]
        else { return nil }
        var props: [String: JSONValue] = [:]
        if case .object(let values) = object["props"] { props = values }
        var children: [UINode] = []
        if case .array(let values) = object["children"] { children = values.compactMap(UINode.init(json:)) }
        self.init(id: Int(id), type: type, props: props, children: children)
    }

    public func node(_ prop: String) -> UINode? {
        props[prop].flatMap(UINode.init(json:))
    }

    public func string(_ prop: String) -> String? {
        if case .string(let value) = props[prop] { return value }
        return nil
    }

    public func bool(_ prop: String) -> Bool? {
        if case .bool(let value) = props[prop] { return value }
        return nil
    }

    /// True when the prop is a function the app can call back.
    public func hasCallback(_ prop: String) -> Bool {
        if case .object(let marker) = props[prop], case .array = marker["$fn"] { return true }
        return false
    }

    /// Depth-first search through children and nodes held in props.
    public func first(where matches: (UINode) -> Bool) -> UINode? {
        if matches(self) { return self }
        for value in props.values {
            if let node = UINode(json: value), let found = node.first(where: matches) { return found }
        }
        for child in children {
            if let found = child.first(where: matches) { return found }
        }
        return nil
    }
}

/// What a command receives as props when it's launched.
public struct LaunchProps: Sendable, Equatable, Encodable {
    public var arguments: [String: String]
    public var launchType: String
    public var fallbackText: String?
    /// `launchCommand`'s `context`, carried untouched: the worker turns its `$date` and `$buffer` markers back into
    /// Dates and Buffers.
    public var launchContext: JSONValue?

    public init(
        arguments: [String: String] = [:],
        launchType: String = "userInitiated",
        fallbackText: String? = nil,
        launchContext: JSONValue? = nil
    ) {
        self.arguments = arguments
        self.launchType = launchType
        self.fallbackText = fallbackText
        self.launchContext = launchContext
    }
}

/// Facts about a launch that the runtime needs for `environment`, LocalStorage and Cache.
public struct LaunchEnvironment: Sendable, Equatable, Encodable {
    public var extensionName: String
    public var commandName: String
    public var commandMode: String
    public var assetsPath: String
    public var supportPath: String
    public var cachePath: String
    public var localStoragePath: String
    public var ownerOrAuthorName: String
    /// "light" or "dark".
    public var appearance: String
    public var isDevelopment: Bool

    /// The environment for `command` of `installed`, with fudge's folders for it (created if missing).
    public static func make(
        for installed: InstalledExtension,
        command: ExtensionManifest.Command,
        paths: FudgePaths,
        appearance: String
    ) -> LaunchEnvironment {
        let name = installed.manifest.name
        let support = paths.supportDirectory(forExtension: name)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return LaunchEnvironment(
            extensionName: name,
            commandName: command.name,
            commandMode: command.mode,
            assetsPath: installed.assetsDirectory.path,
            supportPath: support.path,
            cachePath: paths.cacheDirectory(forExtension: name).path,
            localStoragePath: paths.localStorageFile(forExtension: name).path,
            ownerOrAuthorName: installed.manifest.ownerOrAuthorName,
            appearance: appearance,
            isDevelopment: false
        )
    }
}

/// Messages from the app to the extension host.
public enum AppMessage: Sendable, Equatable, Encodable {
    case ping(id: Int)
    case launch(
        session: String,
        entry: String,
        mode: String,
        launchProps: LaunchProps,
        preferences: [String: JSONValue] = [:],
        environment: LaunchEnvironment? = nil
    )
    case event(session: String, node: Int, path: [String], args: [JSONValue])
    /// Asks for these List or Grid items' `actions` and `detail`, which renders send only for some (`ItemSlots`).
    case slots(session: String, nodes: [Int])
    case pop(session: String)
    case unload(session: String)
    case rpcResult(session: String, id: Int, result: JSONValue?, error: String?)
    /// The user picked a toast's primary or secondary action.
    case toastAction(session: String, toast: Int, action: String)

    enum Keys: String, CodingKey {
        case type, id, session, entry, mode, launchProps, preferences, environment, node, path, args, result, error
        case toast, action, nodes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .ping(let id):
            try container.encode("ping", forKey: .type)
            try container.encode(id, forKey: .id)
        case .launch(let session, let entry, let mode, let launchProps, let preferences, let environment):
            try container.encode("launch", forKey: .type)
            try container.encode(session, forKey: .session)
            try container.encode(entry, forKey: .entry)
            try container.encode(mode, forKey: .mode)
            try container.encode(launchProps, forKey: .launchProps)
            try container.encode(preferences, forKey: .preferences)
            try container.encodeIfPresent(environment, forKey: .environment)
        case .event(let session, let node, let path, let args):
            try container.encode("event", forKey: .type)
            try container.encode(session, forKey: .session)
            try container.encode(node, forKey: .node)
            try container.encode(path, forKey: .path)
            try container.encode(args, forKey: .args)
        case .slots(let session, let nodes):
            try container.encode("slots", forKey: .type)
            try container.encode(session, forKey: .session)
            try container.encode(nodes, forKey: .nodes)
        case .pop(let session):
            try container.encode("pop", forKey: .type)
            try container.encode(session, forKey: .session)
        case .unload(let session):
            try container.encode("unload", forKey: .type)
            try container.encode(session, forKey: .session)
        case .rpcResult(let session, let id, let result, let error):
            try container.encode("rpcResult", forKey: .type)
            try container.encode(session, forKey: .session)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(result, forKey: .result)
            try container.encodeIfPresent(error, forKey: .error)
        case .toastAction(let session, let toast, let action):
            try container.encode("toastAction", forKey: .type)
            try container.encode(session, forKey: .session)
            try container.encode(toast, forKey: .toast)
            try container.encode(action, forKey: .action)
        }
    }
}

/// Messages from the extension host to the app.
public enum HostMessage: Sendable, Equatable, Decodable {
    case pong(id: Int)
    case protocolError(message: String)
    case render(session: String, view: UINode?, depth: Int)
    /// The answer to `AppMessage.slots`, for the items still mounted.
    case slots(session: String, items: [ItemSlots])
    case rpc(session: String, id: Int, method: String, params: JSONValue)
    case error(session: String, message: String, stack: String?, fatal: Bool)
    case log(session: String, level: String, message: String)
    /// The worker's answer to an `event`, once its handler has returned or its promise has settled.
    case eventSettled(session: String)
    case exit(session: String, reason: String)
    /// A message type this version of the app doesn't know.
    case unknown(type: String)

    enum Keys: String, CodingKey {
        case type, id, session, view, depth, method, params, message, stack, fatal, level, reason, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pong":
            self = .pong(id: try container.decode(Int.self, forKey: .id))
        case "protocolError":
            self = .protocolError(message: try container.decode(String.self, forKey: .message))
        case "render":
            self = .render(
                session: try container.decode(String.self, forKey: .session),
                view: try container.decodeIfPresent(UINode.self, forKey: .view),
                depth: try container.decode(Int.self, forKey: .depth)
            )
        case "slots":
            let items = try container.decode([JSONValue].self, forKey: .items)
            self = .slots(
                session: try container.decode(String.self, forKey: .session),
                items: items.compactMap(ItemSlots.init(json:)))
        case "rpc":
            self = .rpc(
                session: try container.decode(String.self, forKey: .session),
                id: try container.decode(Int.self, forKey: .id),
                method: try container.decode(String.self, forKey: .method),
                params: try container.decodeIfPresent(JSONValue.self, forKey: .params) ?? .null
            )
        case "error":
            self = .error(
                session: try container.decode(String.self, forKey: .session),
                message: try container.decode(String.self, forKey: .message),
                stack: try container.decodeIfPresent(String.self, forKey: .stack),
                fatal: try container.decode(Bool.self, forKey: .fatal)
            )
        case "log":
            self = .log(
                session: try container.decode(String.self, forKey: .session),
                level: try container.decode(String.self, forKey: .level),
                message: try container.decode(String.self, forKey: .message)
            )
        case "eventSettled":
            self = .eventSettled(session: try container.decode(String.self, forKey: .session))
        case "exit":
            self = .exit(
                session: try container.decode(String.self, forKey: .session),
                reason: try container.decode(String.self, forKey: .reason)
            )
        default:
            self = .unknown(type: type)
        }
    }

    /// The session the message is about, if any.
    public var session: String? {
        switch self {
        case .render(let session, _, _), .slots(let session, _), .rpc(let session, _, _, _),
            .error(let session, _, _, _), .log(let session, _, _), .eventSettled(let session), .exit(let session, _):
            session
        case .pong, .protocolError, .unknown:
            nil
        }
    }
}

extension HostMessage {
    /// Reads one line from the host. Through `JSONValue.parse`, about ten times faster than `JSONDecoder`, which
    /// took 750 ms for a 1,000-row list; a line that path can't read goes through `JSONDecoder`.
    public init(line: Data) throws {
        if let json = try? JSONValue.parse(line), let message = HostMessage(json: json) {
            self = message
        } else {
            self = try JSONDecoder().decode(HostMessage.self, from: line)
        }
    }

    /// The message a parsed line holds, read as `init(from:)` reads it; nil where that would throw.
    init?(json: JSONValue) {
        guard case .object(let object) = json, case .string(let type) = object["type"] else { return nil }
        func string(_ key: String) -> String? { if case .string(let value) = object[key] { value } else { nil } }
        func int(_ key: String) -> Int? {
            if case .number(let value) = object[key] { Int(exactly: value) } else { nil }
        }
        /// nil when the key holds something else; .some(nil) when it's missing or null.
        func optionalString(_ key: String) -> String?? {
            switch object[key] {
            case nil, .null: .some(nil)
            case .string(let value): .some(value)
            default: nil
            }
        }
        switch type {
        case "pong":
            guard let id = int("id") else { return nil }
            self = .pong(id: id)
        case "protocolError":
            guard let message = string("message") else { return nil }
            self = .protocolError(message: message)
        case "render":
            guard let session = string("session"), let depth = int("depth") else { return nil }
            var view: UINode?
            if let json = object["view"], json != .null {
                guard let node = UINode(json: json) else { return nil }
                view = node
            }
            self = .render(session: session, view: view, depth: depth)
        case "slots":
            guard let session = string("session"), case .array(let items) = object["items"] else { return nil }
            self = .slots(session: session, items: items.compactMap(ItemSlots.init(json:)))
        case "rpc":
            guard let session = string("session"), let id = int("id"), let method = string("method") else { return nil }
            self = .rpc(session: session, id: id, method: method, params: object["params"] ?? .null)
        case "error":
            guard let session = string("session"), let message = string("message"), let stack = optionalString("stack"),
                case .bool(let fatal) = object["fatal"]
            else { return nil }
            self = .error(session: session, message: message, stack: stack, fatal: fatal)
        case "log":
            guard let session = string("session"), let level = string("level"), let message = string("message") else {
                return nil
            }
            self = .log(session: session, level: level, message: message)
        case "eventSettled":
            guard let session = string("session") else { return nil }
            self = .eventSettled(session: session)
        case "exit":
            guard let session = string("session"), let reason = string("reason") else { return nil }
            self = .exit(session: session, reason: reason)
        default:
            self = .unknown(type: type)
        }
    }
}

/// A List or Grid item's `actions` and `detail`. A render sends them only for the first item and the items the app
/// last asked for (`AppMessage.slots`); the others hold `{ "$deferred": true }` instead (`ListContent.Item.deferred`).
public struct ItemSlots: Sendable, Equatable {
    /// The item's node id.
    public var id: Int
    public var actions: UINode?
    public var detail: UINode?

    public init(id: Int, actions: UINode? = nil, detail: UINode? = nil) {
        self.id = id
        self.actions = actions
        self.detail = detail
    }

    /// `{ "id": 4, "slots": { "actions": node, "detail": node } }`, as the host sends it.
    init?(json: JSONValue) {
        guard case .object(let object) = json, case .number(let id) = object["id"], let id = Int(exactly: id) else {
            return nil
        }
        var slots: [String: JSONValue] = [:]
        if case .object(let values) = object["slots"] { slots = values }
        self.init(
            id: id, actions: slots["actions"].flatMap(UINode.init(json:)),
            detail: slots["detail"].flatMap(UINode.init(json:)))
    }
}
