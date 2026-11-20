import AppKit
import FudgeCore

/// fudge runs as an accessory app: no Dock icon, one menu bar item, and a launcher panel
/// that a global hotkey shows and hides.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = FudgePaths.standard()
    private var statusItem: NSStatusItem?
    private var model: LauncherModel!
    private var panel: LauncherPanel!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = LauncherModel(paths: paths)
        panel = LauncherPanel(content: LauncherView(model: model))
        model.hide = { [weak self] in self?.hidePanel() }
        panel.onEscape = { [weak self] in self?.model.escape() }
        panel.onResign = { [weak self] in self?.hidePanel() }

        let settings = FudgeSettings.load(from: paths.settingsFile)
        let spec = settings.hotkey.flatMap(HotKeySpec.parse) ?? .default
        hotKey = HotKey(spec) { [weak self] in self?.togglePanel() }
        if hotKey == nil {
            FileHandle.standardError.write(Data("fudge: couldn't register the shortcut \(spec)\n".utf8))
        }
        installStatusItem(shortcut: hotKey == nil ? nil : spec)

        if let snapshot = Snapshot(arguments: CommandLine.arguments) {
            snapshot.take(of: panel, model: model)
        }
    }

    private func installStatusItem(shortcut: HotKeySpec?) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "fudge")

        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open fudge", action: #selector(showPanel), keyEquivalent: "")
        open.target = self
        if let shortcut { open.title = "Open fudge (\(shortcut))" }
        let reload = menu.addItem(
            withTitle: "Reload Extensions", action: #selector(reloadExtensions), keyEquivalent: "")
        reload.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "fudge \(FudgeVersion.current)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit fudge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    @objc private func showPanel() {
        panel.present()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    @objc private func reloadExtensions() {
        model.reload()
    }
}

/// `--snapshot <file.png> [--query <text>] [--activate]`: renders the panel, saves a picture of it and quits.
/// `--activate` presses ↵ after typing the query, then waits for the result.
/// For checking the layout without looking at the screen.
@MainActor
struct Snapshot {
    let file: URL
    let query: String?
    let activate: Bool

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        file = URL(fileURLWithPath: arguments[index + 1])
        if let queryIndex = arguments.firstIndex(of: "--query"), queryIndex + 1 < arguments.count {
            query = arguments[queryIndex + 1]
        } else {
            query = nil
        }
        activate = arguments.contains("--activate")
    }

    /// Renders the panel without showing it: transparent, off-screen and never key,
    /// so taking a snapshot can't catch the user's clicks or keystrokes.
    func take(of panel: LauncherPanel, model: LauncherModel) {
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.allowsOffscreen = true
        panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.orderFrontRegardless()
        if let query { model.searchText = query }
        if activate { model.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (activate ? 3 : 1)) {
            guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
            exit(0)
        }
    }
}
