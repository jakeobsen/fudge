import AppKit
import FudgeCore
import Observation
import SwiftUI

/// Where onboarding is: the steps it shows (`Onboarding.pending` when it opened) and the one on screen. Each step's
/// answer is saved as the user leaves it, so closing the window keeps them, and the next launch shows the rest.
@MainActor
@Observable
final class OnboardingModel {
    let steps: [OnboardingStep]
    /// It was completed before: "Something new to decide" takes Welcome's place.
    let somethingNew: Bool
    private(set) var index = 0
    @ObservationIgnored private var onboarding: Onboarding
    @ObservationIgnored private let file: URL
    /// Leaving a step ends a hotkey recording, so fudge's hotkeys work again.
    @ObservationIgnored var leavingStep: () -> Void = {}
    /// Start Using fudge: closes the window and opens the launcher.
    @ObservationIgnored var finished: () -> Void = {}

    init(onboarding: Onboarding, file: URL) {
        self.onboarding = onboarding
        self.file = file
        steps = onboarding.pending
        somethingNew = onboarding.hasSomethingNew
    }

    var step: OnboardingStep { steps[index] }
    var hasBack: Bool { index > 0 }

    /// Answers the step on screen (Get Started, Continue, Not now) and moves on.
    func next() {
        leavingStep()
        answer(step)
        if index + 1 < steps.count { index += 1 }
    }

    func back() {
        leavingStep()
        if index > 0 { index -= 1 }
    }

    /// Start Using fudge: onboarding is complete.
    func finish() {
        answer(.done)
        finished()
    }

    /// Jumps to a step, for snapshots.
    func show(_ step: OnboardingStep) {
        if let found = steps.firstIndex(of: step) { index = found }
    }

    private func answer(_ step: OnboardingStep) {
        onboarding.answer(step)
        do {
            try onboarding.save(to: file)
        } catch {
            FileHandle.standardError.write(Data("fudge: couldn't save \(file.path): \(error)\n".utf8))
        }
    }
}

/// The onboarding window, which can refuse the keyboard like Settings, and closes on ⌘W and ⌘Q like Settings
/// (`WindowShortcut`), since an accessory app has no File menu. Closing it doesn't complete onboarding.
final class OnboardingNSWindow: NSWindow {
    var refusesKey = false
    /// Whether the hotkey step is recording, when ⌘Q and ⌘W belong to the recorder.
    var isRecording: () -> Bool = { false }

    override var canBecomeKey: Bool { !refusesKey && super.canBecomeKey }
    override var canBecomeMain: Bool { !refusesKey && super.canBecomeMain }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let pressed = AppDelegate.shortcut(for: event),
            WindowShortcut.closesWindow(pressed, recording: isRecording())
        {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class OnboardingWindowController {
    private let settings: SettingsModel
    private let file: URL
    private var window: NSWindow?
    /// Start Using fudge opens the launcher; set by the app delegate.
    var openLauncher: () -> Void = {}

    init(settings: SettingsModel, file: URL) {
        self.settings = settings
        self.file = file
    }

    /// Opens the window on `onboarding`'s pending steps, in front, on the screen with the mouse.
    func show(_ onboarding: Onboarding) {
        prepare(onboarding)
        guard let window else { return }
        Self.center(window, on: NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Since macOS 14 activation can be declined (at login, say); the window still comes to the front.
        window.orderFrontRegardless()
    }

    /// Show Onboarding Again: every step, from what's set now.
    func showAgain() {
        var onboarding = Onboarding.load(from: file)
        onboarding.restart()
        try? onboarding.save(to: file)
        show(onboarding)
    }

    /// Lays the window out off-screen and transparent, never key, on `step`; only snapshots use this.
    func renderOffscreen(_ onboarding: Onboarding, step: OnboardingStep?) -> NSView? {
        let model = prepare(onboarding)
        if let step { model.show(step) }
        guard let window else { return nil }
        (window as? OnboardingNSWindow)?.refusesKey = true
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        return window.contentView
    }

    @discardableResult
    private func prepare(_ onboarding: Onboarding) -> OnboardingModel {
        settings.reload()
        settings.refreshLoginItem()
        settings.accessibility.refresh()
        let model = OnboardingModel(onboarding: onboarding, file: file)
        model.leavingStep = { [settings] in settings.cancelRecording() }
        model.finished = { [weak self] in
            self?.window?.close()
            self?.openLauncher()
        }
        let view = NSHostingView(rootView: OnboardingView(model: model, settings: settings))
        if let window {
            window.contentView = view
            return model
        }
        let window = OnboardingNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up fudge"
        window.isReleasedWhenClosed = false
        window.isRecording = { [settings] in settings.recording != nil }
        window.contentView = view
        self.window = window
        let settings = settings
        // Closing it mid-recording gives fudge its hotkeys back, and its views go, so the Accessibility step stops
        // polling. The answers so far are saved already.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak window] _ in
            MainActor.assumeIsolated {
                settings.cancelRecording()
                window?.dropContentWhenClosed()
            }
        }
        // Coming back from System Settings shows what was changed there.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                settings.refreshLoginItem()
                settings.accessibility.refresh()
            }
        }
        return model
    }

    var contentView: NSView? { window?.contentView }

    private static func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }
}

struct OnboardingView: View {
    let model: OnboardingModel
    let settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.somethingNew, model.index == 0 {
                Text("Something new to decide")
                    .font(.headline).foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
            content
            Spacer(minLength: 16)
            HStack {
                Text("\(model.index + 1) of \(model.steps.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.hasBack {
                    Button("Back") { model.back() }
                }
                buttons
            }
        }
        .padding(32)
        .frame(width: 600, height: 460, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: Binding(get: { restore.sheet }, set: { restore.sheet = $0 })) { sheet in
            BackupSheet(controller: restore, sheet: sheet)
        }
    }

    /// Welcome's Restore from a Backup…: General's import flow. A backup never holds onboarding's own answers, so
    /// onboarding stays where it is after an import, with the imported settings in its steps.
    private var restore: BackupController { settings.onboardingBackup }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                title("Welcome to fudge")
                Text("fudge is a keyboard launcher for your Mac, and it runs Raycast's extensions.")
                Text("A few choices first. You can change any of them later in Settings.")
                    .foregroundStyle(.secondary)
            }
        case .hotkey:
            VStack(alignment: .leading, spacing: 14) {
                title("Launcher hotkey")
                Text("Press it anywhere to open fudge. Click the keys to record another shortcut.")
                Text(
                    "⌘Space is Spotlight's. To use it for fudge, turn off Spotlight's shortcut in System Settings → "
                        + "Keyboard → Keyboard Shortcuts first."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SettingsGroup {
                    LabeledContent("Launcher hotkey") { LauncherHotkeyControls(model: settings) }
                }
            }
        case .accessibility:
            VStack(alignment: .leading, spacing: 14) {
                title("Accessibility")
                AccessibilityControls(status: settings.accessibility)
            }
        case .openAtLogin:
            VStack(alignment: .leading, spacing: 14) {
                title("Open at Login")
                Text("Start fudge when you log in, so its hotkeys always work.")
                SettingsGroup { OpenAtLoginControls(model: settings) }
            }
        case .currency:
            VStack(alignment: .leading, spacing: 14) {
                title("Currency conversion")
                Text("The calculator can convert currencies, like 100 usd to eur.")
                SettingsGroup { CurrencyRatesToggle(model: settings) }
            }
        case .done:
            VStack(alignment: .leading, spacing: 14) {
                title("You're all set")
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    summary("Launcher hotkey") { Keycaps(spec: settings.launcherHotkey) }
                    summary("Accessibility") { Text(settings.accessibility.isTrusted ? "Allowed" : "Not now") }
                    summary("Open at Login") { Text(settings.loginItemState.isOn ? "On" : "Off") }
                    summary("Currency conversion") { Text(settings.currencyRates ? "On" : "Off") }
                }
                Text("Change any of these in Settings.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.step {
        case .welcome:
            Button("Restore from a Backup…") { restore.startImport() }
            Button("Get Started") { model.next() }.keyboardShortcut(.defaultAction)
        case .accessibility where !settings.accessibility.isTrusted:
            Button("Not Now") { model.next() }
        case .done:
            Button("Start Using fudge") { model.finish() }.keyboardShortcut(.defaultAction)
        default:
            Button("Continue") { model.next() }.keyboardShortcut(.defaultAction)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title).fontWeight(.semibold)
    }

    private func summary(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value()
        }
    }
}

/// General's controls laid out as General lays them out, in a grouped section, so a switch sits on the right as it
/// does in Settings.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form { Section { content() } }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            // The grouped style's own inset, so the section lines up with the text above it.
            .padding(.horizontal, -20)
            .padding(.top, -20)
    }
}
