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
    /// The launcher's Spaces and full-screen behaviour, which the panel takes, so ⌘Y over a full-screen app shows
    /// the preview on that Space.
    var launcherCollectionBehavior: NSWindow.CollectionBehavior = []
    /// Set while Fudge closes the panel itself, so that isn't taken for the user's close.
    private var closing = false

    /// Shows `item`, or closes the panel for nil.
    func show(_ item: QuickLookItem?) {
        self.item = item
        guard item != nil else { return close() }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.hidesOnDeactivate = false
        // Set each time: Quick Look may reset it as it closes.
        panel.collectionBehavior = launcherCollectionBehavior
        if panel.isVisible {
            panel.reloadData()
        } else {
            // Not `makeKeyAndOrderFront`: the launcher keeps the keyboard, and Fudge isn't activated.
            panel.orderFront(nil)
        }
        // Quick Look sets its own level as it opens; it shows just above the launcher.
        panel.level = NSWindow.Level(rawValue: launcherLevel.rawValue + 1)
    }

    private func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible
        else { return }
        closing = true
        panel.orderOut(nil)
        closing = false
    }

    /// Whether macOS's panel is on screen. The model checks it before each Quick Look decision, in case the user
    /// closed the panel with its own button and `windowWillClose` hasn't arrived.
    var isOnScreen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// Whether the panel just took the keyboard from the launcher: the user clicked it. Read while the launcher
    /// resigns key, when the click is still the current event.
    var tookKey: Bool {
        guard item != nil, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
            panel.isVisible
        else { return false }
        return panel.isKeyWindow || NSApp.currentEvent?.window === panel
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
