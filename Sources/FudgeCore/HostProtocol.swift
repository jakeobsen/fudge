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
    case pop(session: String)
    case unload(session: String)
    case rpcResult(session: String, id: Int, result: JSONValue?, error: String?)
    /// The user picked a toast's primary or secondary action.
    case toastAction(session: String, toast: Int, action: String)

    enum Keys: String, CodingKey {
        case type, id, session, entry, mode, launchProps, preferences, environment, node, path, args, result, error
        case toast, action
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
    case rpc(session: String, id: Int, method: String, params: JSONValue)
    case error(session: String, message: String, stack: String?, fatal: Bool)
    case log(session: String, level: String, message: String)
    /// The worker's answer to an `event`, once its handler has returned or its promise has settled.
    case eventSettled(session: String)
    case exit(session: String, reason: String)
    /// A message type this version of the app doesn't know.
    case unknown(type: String)

    enum Keys: String, CodingKey {
        case type, id, session, view, depth, method, params, message, stack, fatal, level, reason
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
        case .render(let session, _, _), .rpc(let session, _, _, _), .error(let session, _, _, _),
            .log(let session, _, _), .eventSettled(let session), .exit(let session, _):
            session
        case .pong, .protocolError, .unknown:
            nil
        }
    }
}
