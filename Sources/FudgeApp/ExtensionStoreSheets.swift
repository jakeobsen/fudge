import FudgeCore

extension ExtensionStore {
    /// The consent sheet shown before the store is turned on.
    static var consentRequest: LauncherModel.AlertRequest {
        LauncherModel.AlertRequest(
            title: Consent.title, message: Consent.message, primary: Consent.confirm, dismiss: Consent.cancel,
            destructive: false,
            footnote: .init(text: Consent.note, linkText: Consent.issueLinkText, url: Consent.issuesURL))
    }

    /// The sheet shown before the store is turned off.
    static var turnOffRequest: LauncherModel.AlertRequest {
        LauncherModel.AlertRequest(
            title: TurnOff.title, message: TurnOff.message, primary: TurnOff.confirm, dismiss: TurnOff.cancel,
            destructive: false)
    }
}
