import AppKit
import SwiftUI

/// The launcher window: a borderless floating panel that takes keyboard input
/// without activating fudge, so the app you were in stays frontmost (as with Spotlight).
final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 750, height: 475)

    var onEscape: () -> Void = {}
    /// Called when the panel loses focus, e.g. after a click elsewhere.
    var onResign: () -> Void = {}

    init(content: some View) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        // The size is the whole window, title bar area included.
        setFrame(NSRect(origin: .zero, size: Self.size), display: false)
    }

    /// Lets the panel sit off-screen; only snapshots use this.
    var allowsOffscreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// Set in snapshot mode: the panel never takes the keyboard, so a snapshot can't catch anyone's typing.
    var refusesKey = false

    override var canBecomeKey: Bool { !refusesKey }
    override var canBecomeMain: Bool { !refusesKey }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }

    override func resignKey() {
        super.resignKey()
        onResign()
    }

    /// Shows the panel on `screen` ("Show fudge on", `PanelScreen`), a little above the middle.
    func present(on screen: NSScreen?) {
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let origin = NSPoint(
                x: visible.midX - Self.size.width / 2,
                y: visible.minY + visible.height * 0.62 - Self.size.height / 2
            )
            setFrame(NSRect(origin: origin, size: Self.size), display: false)
        }
        makeKeyAndOrderFront(nil)
    }
}
