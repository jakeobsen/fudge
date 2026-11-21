import FudgeCore

/// The sheets and labels of Clipboard History's Settings page (SPEC-077 §1).
enum ClipboardHistorySheets {
    static let switchTitle = "Keep Clipboard History"
    static let switchHelp = "Search and paste what you copied, from Clipboard History."
    static let keepFor = "Keep For"
    static let ignoreApps = "Ignore Apps"
    static let ignoreAppsHelp = "Copies made in these apps aren't kept."

    static func keepForTitle(_ days: Int) -> String {
        switch days {
        case 1: "1 Day"
        case 90: "3 Months"
        default: "\(days) Days"
        }
    }

    /// Before turning it on.
    static var consent: LauncherModel.AlertRequest {
        LauncherModel.AlertRequest(
            title: "Turn on clipboard history?",
            message: ClipboardHistory.consentMessage,
            primary: "Turn On", dismiss: "Cancel", destructive: false)
    }

    /// After turning it off: keep what's there, or delete it.
    static var turnedOff: LauncherModel.AlertRequest {
        LauncherModel.AlertRequest(
            title: "Keep the clipboard history?",
            message: "Fudge has stopped keeping what you copy. You can keep what it has, or delete it.",
            primary: "Keep History", dismiss: "Delete History", destructive: false)
    }

    /// **Clear History…**
    static var clear: LauncherModel.AlertRequest {
        LauncherModel.AlertRequest(
            title: "Clear the clipboard history?", message: "Every copy is deleted, pinned ones too.",
            primary: "Clear History", dismiss: "Cancel", destructive: true)
    }
}
