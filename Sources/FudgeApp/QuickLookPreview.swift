import AppKit
import FudgeCore
import Quartz

/// Mirrors `QuickLookState` into macOS's Quick Look panel (SPEC-049). The app delegate is the panel's controller,
/// found through the responder chain, which it reaches whether or not Fudge is active; this object is the panel's
/// data source and delegate. The panel is ordered front without becoming key, so the keyboard stays with the
/// launcher.
@MainActor
final class QuickLookPreview: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate
{
    /// What the panel shows; nil while it's closed.
    private(set) var item: QuickLookItem?
    /// The user closed the panel with its own button.
    var closedByUser: () -> Void = {}
    /// A key the panel got because the user clicked it: ↑↓, Esc and the launcher's shortcuts go to the launcher.
    var forwardKey: (NSEvent) -> Bool = { _ in false }
    /// The launcher's level; the panel shows above it.
    var launcherLevel: NSWindow.Level = .floating
    /// Set while Fudge closes the panel itself, so that isn't taken for the user's close.
    private var closing = false
    /// The panel's key state from its own notifications, read when the launcher's resign settles (`PreviewKey`).
    private(set) var previewKey = PreviewKey()

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(panelBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(
            self, selector: #selector(panelResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
    }

    @objc private func panelBecameKey(_ notification: Notification) {
        if notification.object is QLPreviewPanel { previewKey.record(.becameKey) }
    }

    @objc private func panelResignedKey(_ notification: Notification) {
        if notification.object is QLPreviewPanel { previewKey.record(.resignedKey) }
    }

    /// Shows `item`, or closes the panel for nil.
    func show(_ item: QuickLookItem?) {
        self.item = item
        guard item != nil else { return close() }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.hidesOnDeactivate = false
        // Quick Look's own Spaces behaviour, allowed over a full-screen app, so ⌘Y there shows the preview on that
        // Space. Not the launcher's whole set (`.canJoinAllSpaces`, `.transient`, `.ignoresCycle`), which came in
        // with ⌘Y closing the launcher (FUD-104). Set each time: Quick Look may reset it as it closes.
        panel.collectionBehavior = Self.overFullScreen(panel.collectionBehavior)
        if panel.isVisible {
            panel.reloadData()
        } else {
            // Not `makeKeyAndOrderFront`: the launcher keeps the keyboard, and Fudge isn't activated.
            LauncherLog.note(
                "preview orderFront behavior=\(panel.collectionBehavior.rawValue): \(LauncherLog.keyboard)")
            panel.orderFront(nil)
        }
        // Quick Look sets its own level as it opens; it shows just above the launcher.
        panel.level = NSWindow.Level(rawValue: launcherLevel.rawValue + 1)
        LauncherLog.note(
            "preview shown key=\(panel.isKeyWindow) level=\(panel.level.rawValue) "
                + "behavior=\(panel.collectionBehavior.rawValue): \(LauncherLog.keyboard)")
        DispatchQueue.main.async {
            LauncherLog.note("preview a turn later key=\(panel.isKeyWindow): \(LauncherLog.keyboard)")
        }
    }

    private func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return }
        closing = true
        previewKey.record(.closed)
        LauncherLog.note("preview orderOut by Fudge: \(LauncherLog.keyboard)")
        panel.orderOut(nil)
        closing = false
    }

    /// Whether macOS's panel is on screen. The model checks it before each Quick Look decision, in case the user
    /// closed the panel with its own button and `windowWillClose` hasn't arrived.
    var isOnScreen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// `behavior`, allowed on a full-screen app's Space. A window is either a full-screen app's auxiliary or its own
    /// full-screen window, never both, so the latter goes.
    static func overFullScreen(_ behavior: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var allowed = behavior
        allowed.remove([.fullScreenPrimary, .fullScreenNone])
        allowed.insert(.fullScreenAuxiliary)
        return allowed
    }

    /// Whether the panel has the keyboard: the user clicked it, or Quick Look took it as the preview opened. Read
    /// once the launcher's resign has settled (`LauncherResign`).
    var isKey: Bool {
        guard item != nil, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else {
            return false
        }
        return panel.isVisible && panel.isKeyWindow
    }

    // MARK: - Control, from the app delegate

    var acceptsControl: Bool { item != nil }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        item == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        item.map(PreviewItem.init)
    }

    // MARK: - QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return forwardKey(event)
    }

    func windowWillClose(_ notification: Notification) {
        LauncherLog.note("preview willClose byFudge=\(closing) open=\(item != nil): \(LauncherLog.keyboard)")
        previewKey.record(.closed)
        guard !closing, item != nil else { return }
        item = nil
        closedByUser()
    }
}

/// One file for the panel, with the item's title.
private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL!
    let previewItemTitle: String!

    init(_ item: QuickLookItem) {
        previewItemURL = item.url
        previewItemTitle = item.title
    }
}
