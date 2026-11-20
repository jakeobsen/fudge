import AppKit
import FudgeCore

/// Answers the extension API calls that need the system: clipboard, opening, the Trash, Finder and applications.
@MainActor
enum SystemCalls {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static let methods: Set<String> = [
        "clipboard.copy", "clipboard.clear", "clipboard.read", "open", "trash", "showInFinder",
        "applications.list", "applications.default", "applications.frontmost",
    ]

    /// Runs `method`. Unknown methods throw.
    static func handle(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let params = Params(params)
        switch method {
        case "clipboard.copy":
            copy(params)
            return .null
        case "clipboard.clear":
            NSPasteboard.general.clearContents()
            return .null
        case "clipboard.read":
            // fudge has no clipboard history yet, so only the current item (offset 0) exists.
            guard (params.number("offset") ?? 0) == 0 else { return .null }
            return read()
        case "open":
            try await open(try params.required("target"), with: params.string("application"))
            return .null
        case "trash":
            try SystemFiles.trash(params.strings("paths"))
            return .null
        case "showInFinder":
            showInFinder(try params.required("path"))
            return .null
        case "applications.list":
            if let path = params.string("path") { return .array(SystemFiles.applications(forOpening: path)) }
            return .array(
                ApplicationIndex.scan().compactMap { item in
                    if case .application(let url) = item.kind { return ApplicationResolver.application(at: url) }
                    return nil
                }
            )
        case "applications.default":
            let path = try params.required("path")
            guard let app = SystemFiles.defaultApplication(forOpening: path) else {
                throw Failure(description: "No application opens \(path)")
            }
            return app
        case "applications.frontmost":
            guard let url = NSWorkspace.shared.frontmostApplication?.bundleURL else {
                throw Failure(description: "No application is frontmost")
            }
            return ApplicationResolver.application(at: url)
        default:
            throw Failure(description: "\(method) isn't available in fudge yet")
        }
    }

    private static func copy(_ params: Params) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let file = params.string("file") {
            item.setString(URL(fileURLWithPath: file).absoluteString, forType: .fileURL)
            item.setString(file, forType: .string)
        }
        if let html = params.string("html") { item.setString(html, forType: .html) }
        if let text = params.string("text") { item.setString(text, forType: .string) }
        // The conventions clipboard managers honour (nspasteboard.org).
        if params.bool("concealed") {
            item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        if params.bool("transient") {
            item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        pasteboard.writeObjects([item])
    }

    /// Opens a Finder window with the file or folder at `path` (`~` expanded) selected.
    static func showInFinder(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func read() -> JSONValue {
        let pasteboard = NSPasteboard.general
        var content: [String: JSONValue] = ["text": .string(pasteboard.string(forType: .string) ?? "")]
        if let html = pasteboard.string(forType: .html) { content["html"] = .string(html) }
        if let file = pasteboard.string(forType: .fileURL).flatMap(URL.init(string:)), file.isFileURL {
            content["file"] = .string(file.path)
        }
        return .object(content)
    }

    private static func open(_ target: String, with application: String?) async throws {
        let url = SystemFiles.url(for: target)
        let configuration = NSWorkspace.OpenConfiguration()
        guard let application else {
            try await NSWorkspace.shared.open(url, configuration: configuration)
            return
        }
        guard case .object(let app) = ApplicationResolver.resolve(application), case .string(let path) = app["path"]
        else {
            throw Failure(description: "Can't find the application \(application)")
        }
        try await NSWorkspace.shared.open(
            [url], withApplicationAt: URL(fileURLWithPath: path), configuration: configuration)
    }

    /// Typed access to an rpc call's parameters.
    struct Params {
        let values: [String: JSONValue]

        init(_ json: JSONValue) {
            if case .object(let values) = json { self.values = values } else { values = [:] }
        }

        func string(_ key: String) -> String? {
            if case .string(let value) = values[key] { return value }
            return nil
        }

        func required(_ key: String) throws -> String {
            guard let value = string(key) else { throw Failure(description: "missing `\(key)`") }
            return value
        }

        func number(_ key: String) -> Double? {
            if case .number(let value) = values[key] { return value }
            return nil
        }

        func bool(_ key: String) -> Bool {
            if case .bool(let value) = values[key] { return value }
            return false
        }

        func strings(_ key: String) -> [String] {
            guard case .array(let items) = values[key] else { return [] }
            return items.compactMap { if case .string(let value) = $0 { value } else { nil } }
        }
    }
}
