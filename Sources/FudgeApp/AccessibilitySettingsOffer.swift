import AppKit
import FudgeCore

/// fudge's own offer to open System Settings → Privacy & Security → Accessibility, for when macOS's prompt didn't help
/// (FUD-47). `AccessibilityGate` decides when, once per run; this shows the alert. It's a sheet on the panel while
/// the panel is up, otherwise a standalone alert with fudge activated, as `alert.confirm` does.
@MainActor
final class AccessibilitySettingsOffer {
    private let panel: NSPanel
    private let restoreKeyboard: () -> Void

    init(panel: NSPanel, restoreKeyboard: @escaping () -> Void) {
        self.panel = panel
        self.restoreKeyboard = restoreKeyboard
    }

    /// Shows the alert on a later turn of the main actor, so the refused call is answered first and never waits on
    /// the user.
    func offer(origin: CallOrigin) {
        Task { self.present(origin: origin) }
    }

    private func present(origin: CallOrigin) {
        let alert = NSAlert()
        alert.messageText = AccessibilitySettingsAlert.title
        alert.informativeText = AccessibilitySettingsAlert.text
        alert.addButton(withTitle: AccessibilitySettingsAlert.openButton)
        // NSAlert gives Esc only to a button titled Cancel.
        alert.addButton(withTitle: AccessibilitySettingsAlert.dismissButton).keyEquivalent = "\u{1b}"
        if panel.isVisible {
            alert.beginSheetModal(for: panel) { [weak self] response in
                // The sheet had the keyboard; give it back to the screen's field.
                self?.restoreKeyboard()
                Self.answer(response)
            }
            return
        }
        // A modal behind another app would block fudge until found; this follows a refused paste or selection.
        NSApp.activateFromUserAction(origin: origin)
        Self.answer(alert.runModal())
    }

    private static func answer(_ response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(AccessibilitySettingsAlert.paneURL)
    }
}
