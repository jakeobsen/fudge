import AppKit
import FudgeCore

/// Answers the extension API calls that need the system: clipboard, opening, the Trash, Finder, applications and the
/// selection.
@MainActor
enum SystemCalls {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// A call's error as a sentence for a toast: Fudge's own message, else the system's localized description, never
    /// an `NSError` dump.
    static func message(of error: Error) -> String {
        if let failure = error as? Failure { return failure.description }
        return (error as NSError).localizedDescription
    }

    static let methods: Set<String> = [
        "clipboard.copy", "clipboard.clear", "clipboard.read", "open", "trash", "showInFinder",
        "applications.list", "applications.default", "applications.frontmost", "selection.text",
        "selection.finderItems",
    ]

    /// Offers the Accessibility pane when macOS's prompt didn't help. The app delegate sets it up with the panel;
    /// snapshot runs have none.
    static var accessibilitySettingsOffer: AccessibilitySettingsOffer?
    private static let accessibility = SystemAccessibility()
    /// Shared by reading the selection and pasting, so macOS's Accessibility prompt shows at most once per run, and
    /// fudge's own offer too.
    private static let gate = AccessibilityGate(
        access: accessibility, offerSettings: { accessibilitySettingsOffer?.offer(origin: $0) })
    private static let keys = SystemCopyKey()
    private static let pasteboard = SystemPasteboard()
    private static let selectedText = SelectedText(
        accessibility: accessibility, keys: keys, pasteboard: pasteboard,
        ownPid: ProcessInfo.processInfo.processIdentifier, gate: gate)
    private static let paster = Paste(
        gate: gate, keys: keys, pasteboard: pasteboard, ownPid: ProcessInfo.processInfo.processIdentifier)
    private static let automation = SystemAutomationPermission()
    private static let finder = FinderEvents()

    /// Runs `method` for a call from `origin`, which decides whether reading the selection may ask for macOS's
    /// Accessibility prompt or Fudge's offer. Unknown methods throw.
    static func handle(_ method: String, _ params: JSONValue, origin: CallOrigin) async throws -> JSONValue {
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
        case "selection.text":
            return .string(try await selectedText.read(from: frontmost(), origin: origin))
        case "selection.finderItems":
            let paths = try await FinderSelection.read(
                from: frontmost(), permission: automation, source: finder, origin: origin)
            return .array(paths.map { .object(["path": .string($0)]) })
        default:
            throw Failure(description: "\(method) isn't available in Fudge yet")
        }
    }

    /// `Clipboard.paste` (`clipboard.paste`): the content as `Clipboard.copy` takes it, pasted into the frontmost app.
    /// `hideWindow` hides fudge's panel and returns once it's really gone; the model supplies it.
    static func paste(_ json: JSONValue, origin: CallOrigin, hideWindow: () async -> Void) async throws {
        let params = Params(json)
        let content = PasteboardContents.forPaste(
            text: params.string("text"), html: params.string("html"), file: params.string("file"))
        try await paster.paste(
            content, closeMainWindow: params.values["closeMainWindow"] != .bool(false), origin: origin,
            hideWindow: hideWindow, frontmost: frontmost)
    }

    private static func frontmost() -> FrontmostApplication? {
        NSWorkspace.shared.frontmostApplication.map {
            FrontmostApplication(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
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
