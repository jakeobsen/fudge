import AppKit
import FudgeCore

/// Answers the extension API calls that need the system: clipboard, opening, the Trash, Finder, applications, the
/// selection and windows.
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
        "selection.finderItems", "windows.desktops", "windows.active", "windows.onActiveDesktop", "windows.setBounds",
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

    /// Whether Fudge may post key events for one of its own commands, which the user started: the same gate as
    /// reading the selection and pasting, so the prompt and the offer still show at most once per run.
    static func mayPostKeysForUser() -> Bool {
        gate.isTrusted(origin: .userInitiated)
    }
    private static let pasteboard = SystemPasteboard()
    /// Shared by pasting and reading the selection's ⌘C fallback, so neither snapshots the pasteboard while the
    /// other's content is on it. Clipboard history asks them which changes were Fudge's own.
    static let pasteboardTurns = PasteboardTurns()
    private static let selectedText = SelectedText(
        accessibility: accessibility, keys: keys, pasteboard: pasteboard,
        ownPid: ProcessInfo.processInfo.processIdentifier, turns: pasteboardTurns, gate: gate)
    private static let paster = Paste(
        gate: gate, keys: keys, pasteboard: pasteboard, ownPid: ProcessInfo.processInfo.processIdentifier,
        turns: pasteboardTurns)
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
            // An offset above 0 is clipboard history's, answered by `LauncherModel` before it gets here.
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
        case "windows.desktops", "windows.active", "windows.onActiveDesktop", "windows.setBounds":
            return try await windows(method, params.values, origin: origin)
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

    /// Pastes a snippet's filled-in text into the frontmost app as `Clipboard.paste` does, in its turn, then puts the
    /// caret where its `{cursor}` was with `leftArrows` ← presses. Run from Search Snippets, by the user.
    static func pasteSnippet(_ text: String, leftArrows: Int, hideWindow: () async -> Void) async throws {
        try await paster.paste(
            PasteboardContents.forPaste(text: text, html: nil, file: nil), closeMainWindow: true,
            origin: .userInitiated, leftArrows: leftArrows, hideWindow: hideWindow, frontmost: frontmost)
    }

    /// Pastes `contents` into the frontmost app as `clipboard.paste` does: clipboard history's Paste.
    static func paste(
        _ contents: PasteboardContents, origin: CallOrigin, hideWindow: () async -> Void
    ) async throws {
        try await paster.paste(
            contents, closeMainWindow: true, origin: origin, hideWindow: hideWindow, frontmost: frontmost)
    }

    /// Puts `contents` on the clipboard: clipboard history's Copy.
    static func write(_ contents: PasteboardContents) {
        pasteboard.replace(with: contents)
    }

    /// `WindowManagement` (`windows.*`). It needs Accessibility permission, checked as Paste checks it, and runs off
    /// the main thread, since the Accessibility API waits on other apps.
    private static func windows(_ method: String, _ params: [String: JSONValue], origin: CallOrigin) async throws
        -> JSONValue
    {
        guard gate.isTrusted(origin: origin) else { throw WindowManagementError.accessibilityNeeded }
        let manager = WindowManager(system: SystemWindows.current(), ownPid: ProcessInfo.processInfo.processIdentifier)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        switch method {
                        case "windows.desktops": return .array(manager.desktops())
                        case "windows.active": return try manager.activeWindow()
                        case "windows.onActiveDesktop": return .array(manager.windowsOnActiveDesktop())
                        default:
                            try manager.setBounds(.object(params))
                            return .null
                        }
                    })
            }
        }
    }

    /// One of Fudge's own window commands (SPEC-066): Accessibility is checked as for a user-initiated call, and the
    /// command runs off the main thread like `windows.*`. Commands run one at a time, in order, on one queue that
    /// also holds Restore's memory, so a quick Left Half then Restore sees the frame Left Half kept. Returns what the
    /// HUD says, if anything.
    static func windowCommand(_ command: WindowCommand) async -> String? {
        guard gate.isTrusted(origin: .userInitiated) else {
            return "Fudge needs Accessibility permission to manage windows."
        }
        let manager = WindowManager(system: SystemWindows.current(), ownPid: ProcessInfo.processInfo.processIdentifier)
        let result = await withCheckedContinuation { continuation in
            windowCommandQueue.async {
                continuation.resume(returning: manager.run(command, frames: &windowFrames.frames))
            }
        }
        if case .message(let text) = result { return text }
        return nil
    }

    /// Switch Windows' Accessibility check, as for a call the user started: macOS's prompt at the first refusal in a
    /// run, and Fudge's offer at the next, shared with Paste and the window commands.
    static func mayReadWindows() -> Bool {
        gate.isTrusted(origin: .userInitiated)
    }

    /// The frames Restore goes back to, touched only on `windowCommandQueue`.
    private final class WindowFramesBox: @unchecked Sendable {
        var frames = WindowFrames()
    }

    nonisolated private static let windowFrames = WindowFramesBox()
    private static let windowCommandQueue = DispatchQueue(label: "fudge.window-commands", qos: .userInitiated)

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
