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
    private var settingsWindow: SettingsWindowController!
    private let hud = HUDWindow()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = LauncherModel(paths: paths)
        panel = LauncherPanel(content: LauncherView(model: model))
        settingsWindow = SettingsWindowController(model: SettingsModel(paths: paths))
        model.hide = { [weak self] in self?.hidePanel() }
        model.openSettings = { [weak self] name in self?.settingsWindow.show(extension: name) }
        model.showHUD = { [weak self] title in self?.hud.show(title) }
        model.isVisible = { [weak self] in self?.panel.isVisible ?? false }
        model.confirm = { [weak self] request in await self?.confirm(request) ?? false }
        panel.onEscape = { [weak self] in self?.model.escape() }
        panel.onResign = { [weak self] in
            // An alert sheet takes the keyboard; that's not the user leaving.
            guard let self, self.panel.attachedSheet == nil else { return }
            self.hidePanel()
        }

        // ⌘K, ⌘↵ and the extensions' shortcuts, before the search field sees them.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let pressed = Self.shortcut(for: event) else { return event }
            let window = event.window
            let handled = MainActor.assumeIsolated {
                guard let self, window === self.panel else { return false }
                return self.model.handleKey(pressed)
            }
            return handled ? nil : event
        }

        let settings = FudgeSettings.load(from: paths.settingsFile)
        let spec = settings.hotkey.flatMap(HotKeySpec.parse) ?? .default
        hotKey = HotKey(spec) { [weak self] in self?.togglePanel() }
        if hotKey == nil {
            FileHandle.standardError.write(Data("fudge: couldn't register the shortcut \(spec)\n".utf8))
        }
        installStatusItem(shortcut: hotKey == nil ? nil : spec)

        if let snapshot = Snapshot(arguments: CommandLine.arguments) {
            if snapshot.settings {
                snapshot.take(of: settingsWindow)
            } else {
                snapshot.take(of: panel, model: model)
            }
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

    private nonisolated static func shortcut(for event: NSEvent) -> KeyShortcut? {
        guard let key = KeyShortcut.key(forKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else {
            return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<String> = []
        if flags.contains(.command) { modifiers.insert("cmd") }
        if flags.contains(.control) { modifiers.insert("ctrl") }
        if flags.contains(.option) { modifiers.insert("opt") }
        if flags.contains(.shift) { modifiers.insert("shift") }
        return KeyShortcut(key: key, modifiers: modifiers)
    }

    /// confirmAlert: a sheet on the panel when it's open, otherwise a standalone alert.
    private func confirm(_ request: LauncherModel.AlertRequest) async -> Bool {
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message ?? ""
        let primary = alert.addButton(withTitle: request.primary)
        primary.hasDestructiveAction = request.destructive
        alert.addButton(withTitle: request.dismiss)
        if panel.isVisible {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: panel) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func reloadExtensions() {
        model.reload()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }
}

/// `--snapshot <file.png> [--query <text>] [--activate]`: renders the panel, saves a picture of it and quits.
/// `--activate` presses ↵ after typing the query, then waits for the result; `--actions` then presses ⌘K.
/// `--snapshot <file.png> --settings [<extension>]` renders the Settings window instead.
/// For checking the layout without looking at the screen.
@MainActor
struct Snapshot {
    let file: URL
    let query: String?
    let activate: Bool
    let actions: Bool
    let settings: Bool
    let settingsExtension: String?

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        file = URL(fileURLWithPath: arguments[index + 1])
        if let queryIndex = arguments.firstIndex(of: "--query"), queryIndex + 1 < arguments.count {
            query = arguments[queryIndex + 1]
        } else {
            query = nil
        }
        activate = arguments.contains("--activate")
        actions = arguments.contains("--actions")
        if let settingsIndex = arguments.firstIndex(of: "--settings") {
            settings = true
            let next = settingsIndex + 1
            settingsExtension = next < arguments.count && !arguments[next].hasPrefix("--") ? arguments[next] : nil
        } else {
            settings = false
            settingsExtension = nil
        }
    }

    func take(of controller: SettingsWindowController) {
        controller.renderOffscreen(extension: settingsExtension)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let view = controller.contentView else { exit(1) }
            save(view)
        }
    }

    private func save(_ view: NSView) -> Never {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        exit(0)
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
        if actions {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { model.toggleActionPanel() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (actions ? 3.5 : activate ? 3 : 1)) {
            guard let view = panel.contentView else { exit(1) }
            save(view)
        }
    }
}
