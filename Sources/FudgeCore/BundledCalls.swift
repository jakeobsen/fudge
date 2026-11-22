import Foundation

/// The app's calls that only one bundled extension may make (FUD-183), answered by comparing the calling session's
/// whole id with that extension's. An extension of the same name from another repository, or a development build of
/// one, has another id, so it's refused like any other extension.
public enum BundledCalls {
    public enum Call: CaseIterable, Sendable {
        /// `fudge.log`: the Extension Store's failures, for `Fudge.log`.
        case fudgeLog
        /// `commandLineTools.*`: the Extension Store's questions about extensions with a part written in Swift.
        case commandLineTools
        /// `store.*`: the Extension Store's install notifications.
        case storeNotifications
        /// `store.repositories`: the Extension Store's list of repositories (FUD-182).
        case storeRepositories
        /// `clipboardHistory.*`: Clipboard History's list and its changes.
        case clipboardHistory
        /// `files.search`: Search Files' Spotlight queries.
        case filesSearch

        /// The one extension that may make the call.
        public var caller: ExtensionID {
            switch self {
            case .fudgeLog, .commandLineTools, .storeNotifications, .storeRepositories: ExtensionStore.id
            case .clipboardHistory: ClipboardHistory.id
            case .filesSearch: FileSearch.id
            }
        }
    }

    /// Whether a session of the extension `caller` (nil when the session's extension isn't known) may make `call`.
    public static func mayCall(_ call: Call, from caller: ExtensionID?) -> Bool {
        caller == call.caller
    }
}
