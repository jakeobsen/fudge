import AppKit
import Carbon.HIToolbox
import FudgeCore
import IOKit.hid
import Observation

/// macOS's Input Monitoring permission, which a keyboard tap needs (SPEC-078 §5).
enum InputMonitoring {
    /// The status, read without a prompt (`IOHIDCheckAccess`).
    static var isAllowed: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    /// Whether macOS has never asked: then its own prompt, which puts Fudge in the list, comes first.
    static var neverAsked: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    /// Asks for macOS's prompt the first time, and opens the Input Monitoring pane after that, so the two never stack.
    static func request() {
        if neverAsked {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}

/// Input Monitoring's status for the Snippets page, read when it's shown and every second while it's on screen.
/// Snapshot runs get a fixed answer (`--input-monitoring allowed|missing`) and never ask the system.
@MainActor
@Observable
final class InputMonitoringStatus {
    private(set) var isAllowed: Bool
    @ObservationIgnored private let read: () -> Bool

    init(read: @escaping () -> Bool = { InputMonitoring.isAllowed }) {
        self.read = read
        isAllowed = read()
    }

    func refresh() {
        let now = read()
        if now != isAllowed { isAllowed = now }
    }
}

/// Expands snippets' keywords as they're typed (SPEC-078 §6): a listen-only keyboard tap hands key presses to
/// `SnippetExpander` (core), which keeps what's typed to itself and says only which snippet to expand. The tap runs
/// only while the setting is on, some snippet has a keyword and Input Monitoring is allowed; it's a listen-only tap,
/// so it can't swallow or change a key. Never in snapshot runs.
@MainActor
final class SnippetExpansion {
    private let paths: FudgePaths
    private var expander = SnippetExpander()
    private var snippets: [String: Snippet] = [:]
    private var isOn = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var permissionCheck: Timer?
    private var appSwitch: NSObjectProtocol?
    private var accessibilityNoticeShown = false

    /// Whether one of Fudge's own windows has the keyboard (the launcher, Settings, onboarding); set by the app delegate.
    var fudgeHasKeyboard: () -> Bool = { NSApp.isActive }
    var showHUD: (String) -> Void = { _ in }
    /// The clipboard's text for `{clipboard}` (`LauncherModel.templateClipboard`).
    var clipboard: () -> String? = { nil }

    init(paths: FudgePaths) {
        self.paths = paths
    }

    /// Reads the setting and the snippets again, and starts or stops the tap to match. Called at launch and after
    /// any change to either.
    func update() {
        isOn = FudgeSettings.load(from: paths.settingsFile).expandSnippets
        let loaded = SnippetStore.load(from: paths.snippetsFile).snippets
        snippets = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        expander.setSnippets(loaded)
        guard isOn else {
            stop(.switchedOff)
            return
        }
        if appSwitch == nil {
            appSwitch = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.expander.reset(.appSwitch) }
            }
        }
        if permissionCheck == nil {
            // Input Monitoring can be turned off in System Settings at any time; the tap goes with it.
            permissionCheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followPermission() }
            }
        }
        followPermission()
    }

    /// Starts the tap when it can run, and removes it when it can't: switched off, no keywords, or Input Monitoring
    /// not allowed (revoked included).
    private func followPermission() {
        let allowed = InputMonitoring.isAllowed
        if tap != nil, !allowed || !expander.hasKeywords {
            removeTap()
            expander.reset(allowed ? .snippetsChanged : .permissionRevoked)
        } else if tap == nil, isOn, allowed, expander.hasKeywords {
            installTap()
        }
    }

    private func stop(_ reason: SnippetExpander.Reset) {
        removeTap()
        permissionCheck?.invalidate()
        permissionCheck = nil
        if let appSwitch { NSWorkspace.shared.notificationCenter.removeObserver(appSwitch) }
        appSwitch = nil
        expander.reset(reason)
    }

    private func installTap() {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let received = SnippetExpansion.Received(type: type, event: event)
                    let expansion = Unmanaged<SnippetExpansion>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { expansion.handle(received) }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    /// What the tap passes on, read from the event where it arrives: nothing but key facts, and no text is kept.
    private enum Received: Sendable {
        case key(SnippetKeyEvent)
        case click
        case tapDisabled
        case other

        init(type: CGEventType, event: CGEvent) {
            switch type {
            case .keyDown:
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                event.keyboardGetUnicodeString(
                    maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
                let flags = event.flags
                self = .key(
                    SnippetKeyEvent(
                        keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                        characters: String(utf16CodeUnits: characters, count: length),
                        command: flags.contains(.maskCommand), control: flags.contains(.maskControl),
                        option: flags.contains(.maskAlternate),
                        sourceUserData: event.getIntegerValueField(.eventSourceUserData)))
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                self = .click
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                self = .tapDisabled
            default:
                self = .other
            }
        }
    }

    private func handle(_ received: Received) {
        switch received {
        case .key(let event):
            let output = expander.handle(
                event, secureInput: IsSecureEventInputEnabled(), fudgeInFront: fudgeHasKeyboard())
            if case .expand(let id) = output {
                // The one thing that leaves the expander, and the only line about it in the launcher's log.
                LauncherLog.note(output?.description ?? "")
                expand(id)
            }
        case .click:
            expander.reset(.click)
        case .tapDisabled:
            // macOS turns a tap off when it was slow to answer, or for secure input; it goes back on, starting over.
            expander.reset(.click)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .other:
            break
        }
    }

    /// Deletes the keyword just typed and pastes the snippet in its place, through `Paste`'s turn, which puts the
    /// clipboard back, then places `{cursor}`. Secure input is checked again first, and nothing is touched without
    /// Accessibility, which posting keys needs.
    private func expand(_ id: String) {
        guard !IsSecureEventInputEnabled(), !fudgeHasKeyboard(), let snippet = snippets[id],
            let keyword = snippet.keyword
        else { return }
        let template = SnippetTemplate(snippet.text)
        if template.problem != nil {
            showHUD("Can't expand \(snippet.name)")
            return
        }
        let filled = template.fill(context: .init(clipboard: template.usesClipboard ? clipboard() : nil))
        Task {
            do {
                try await SystemCalls.expandSnippet(
                    filled.text, keywordLength: keyword.count, leftArrows: filled.afterCursor ?? 0)
            } catch PasteError.accessibilityNeeded {
                if !accessibilityNoticeShown {
                    accessibilityNoticeShown = true
                    showHUD("Allow Fudge in Accessibility to expand snippets")
                }
            } catch {
                // No app to paste into: nothing was typed anywhere, so there's nothing to say.
            }
        }
    }
}
