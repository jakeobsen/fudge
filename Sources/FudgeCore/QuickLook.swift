import Foundation

/// A List or Grid item's `quickLook` (SPEC-049): the file macOS's Quick Look previews, and the title it shows.
public struct QuickLookItem: Sendable, Equatable {
    public var url: URL
    public var title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    /// Reads `{ path, name? }`. `path` is an absolute path, a `~/` path or a `file://` URL; the runtime sends a
    /// `URL` object as its `href` and a `Buffer` as text, so those arrive as strings too. Anything else (another
    /// scheme, a relative path, an empty string) is no Quick Look. The title is `name` when it's a non-empty
    /// string, else the file's name.
    public static func read(
        _ value: JSONValue?, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> QuickLookItem? {
        guard case .object(let object) = value, case .string(let path) = object["path"],
            let url = fileURL(path, home: home)
        else { return nil }
        let title: String =
            if case .string(let name) = object["name"], !name.isEmpty { name } else { url.lastPathComponent }
        return QuickLookItem(url: url, title: title)
    }

    static func fileURL(_ path: String, home: URL) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        if path == "~" { return home.standardizedFileURL }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        guard path.lowercased().hasPrefix("file://"), let url = URL(string: path), url.isFileURL,
            (url.host ?? "").isEmpty || url.host == "localhost", url.path.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }
}

/// What the Quick Look preview shows (SPEC-049). The app mirrors it into macOS's preview panel.
public struct QuickLookState: Sendable, Equatable {
    /// The item being previewed; nil while it's closed.
    public private(set) var shown: QuickLookItem?
    /// The view it was opened in. Another view closes it.
    private var view: String?

    public init() {}

    public var isOpen: Bool { shown != nil }

    /// What a toggle did.
    public enum Toggled: Sendable, Equatable {
        case opened
        case closed
        /// The selected item has no `quickLook`.
        case nothingToPreview
        /// The selected item's file doesn't exist; its name.
        case missing(String)
    }

    /// `Action.ToggleQuickLook`: closes the preview if it's open, else opens it on the selected item's file, in
    /// `view` (an id for the view on screen, nil outside a command).
    public mutating func toggle(
        selected: QuickLookItem?, in view: String?, exists: (URL) -> Bool
    ) -> Toggled {
        if shown != nil {
            close()
            return .closed
        }
        guard let selected else { return .nothingToPreview }
        guard exists(selected.url) else { return .missing(selected.url.lastPathComponent) }
        shown = selected
        self.view = view
        return .opened
    }

    /// The screen changed. While open, the preview follows the selected item in the same view. Another view (a
    /// push, a pop, a new command, root search), an item without `quickLook`, or one whose file doesn't exist
    /// closes it.
    public mutating func follow(selected: QuickLookItem?, in view: String?, exists: (URL) -> Bool) {
        guard shown != nil else { return }
        guard view == self.view, let selected else { return close() }
        if selected == shown { return }
        guard exists(selected.url) else { return close() }
        shown = selected
    }

    /// Esc, the launcher hiding, or the user closing the preview with its own button.
    public mutating func close() {
        shown = nil
        view = nil
    }

    /// Checks the state against the preview panel itself, before any decision (a toggle, Esc, the selection moving).
    /// The panel's own close button tells the app through `windowWillClose`, which may not have arrived yet: if the
    /// state says open while the panel isn't on screen, the user closed it, and the state closes too. Returns
    /// whether it did, so the app can let go of the item it shows.
    @discardableResult
    public mutating func reconcile(panelVisible: Bool) -> Bool {
        guard shown != nil, !panelVisible else { return false }
        close()
        return true
    }
}

/// Where an arrow key goes when the Quick Look preview has the keyboard, because the user clicked it: where the
/// launcher would have sent it. A date picker's calendar takes arrows before this, through `handleKey`.
public enum PreviewArrow: Sendable, Equatable {
    /// The action panel's list, for ↑↓.
    case actionPanel
    /// The search bar dropdown's panel, for ↑↓.
    case dropdown
    /// The List's or Grid's selection: ↑↓ always, ←→ in a Grid when `GridNavigation.arrowMovesSelection` says so.
    case selection
    /// Nothing: ←→ while a panel is open belong to its search field.
    case none

    public static func target(_ move: GridNavigation.Move, actionPanelOpen: Bool, dropdownOpen: Bool) -> PreviewArrow {
        let vertical = move == .up || move == .down
        if actionPanelOpen { return vertical ? .actionPanel : .none }
        if dropdownOpen { return vertical ? .dropdown : .none }
        return .selection
    }
}

/// What the launcher does when it stops being the key window (`LauncherPanel.resignKey`). It hides, as when the
/// user clicks elsewhere, unless the keyboard went somewhere that's still part of it.
///
/// It's decided once the key change has settled, a main-queue turn after the resign, on what holds the keyboard
/// then (`Settled`). While the launcher resigns, AppKit hasn't made the new key window key yet, and the current event
/// says nothing about where the keyboard went: ⌘Y opening the preview is a key press in the launcher (FUD-104).
public enum LauncherResign: Sendable, Equatable {
    /// A sheet on the launcher (a `confirm`, a FilePicker's open panel) took the keyboard, or the launcher has it
    /// again.
    case stay
    /// Fudge's own Quick Look preview took it: the user clicked it, or Quick Look took it as the preview opened. The
    /// launcher stays, and takes the keyboard back, so ↑↓, Esc and ⌘Y keep working.
    case takeKeyBack
    case hide

    /// What holds the keyboard once the key change has settled.
    public struct Settled: Sendable, Equatable {
        public var sheetAttached: Bool
        public var launcherIsKey: Bool
        /// Whether Fudge's preview shows something, and whether it's the key window.
        public var previewOpen: Bool
        public var previewIsKey: Bool

        public init(sheetAttached: Bool, launcherIsKey: Bool, previewOpen: Bool, previewIsKey: Bool) {
            self.sheetAttached = sheetAttached
            self.launcherIsKey = launcherIsKey
            self.previewOpen = previewOpen
            self.previewIsKey = previewIsKey
        }
    }

    public static func decide(_ settled: Settled) -> LauncherResign {
        if settled.sheetAttached || settled.launcherIsKey { return .stay }
        if settled.previewOpen, settled.previewIsKey { return .takeKeyBack }
        return .hide
    }
}
