import Foundation

/// What a command shows when signing in stopped it on purpose (SPEC-095): sign-in is off, the user cancelled or let it
/// time out, or the provider or the relay refused. It's a notice, drawn like an empty view, with no stack trace and
/// nothing that looks like a crash, since the extension didn't fail.
///
/// The kind travels as a field, never read from a message's text: the app's refusal names it (`SignInRefusal.notice`,
/// sent as `rpcResult`'s `notice`), the worker marks the rejection with it and finds the mark again however the
/// extension wrapped the error (`runtime/src/notice.ts`), and the error report carries it back (`HostMessage.error`'s
/// `notice`).
public struct SignInNotice: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case off = "signInOff"
        case cancelled = "signInCancelled"
        case timedOut = "signInTimedOut"
        case refused = "signInRefused"
    }

    public var kind: Kind
    public var title: String
    public var message: String
    /// ↵ runs the first; ⌘K lists them.
    public var actions: [ActionSection]
    /// The title of the command the notice stands in for, which the bottom bar shows, as the command's own screen did.
    public var commandTitle: String?

    /// What the bottom bar says under the notice (`LauncherFooter`).
    public var footerTitle: String { LauncherFooter.title(standingInFor: commandTitle) }

    /// ⌘⌥, opens Settings on the Sign-in page.
    public static let signInSettingsShortcut = KeyShortcut(key: ",", modifiers: ["cmd", "opt"])

    /// The notice for an error the worker reported with `notice`, or nil when that isn't a kind this version knows
    /// (the failure then shows as any other). `message` is the refusal's own: a refused sign-in shows it, since it's
    /// the provider's or the relay's reason. `commandID` is `<extension>/<command>`, which Try Again runs again.
    public init?(
        notice: String?, message: String, extension id: ExtensionID, extensionTitle: String, commandID: String?,
        commandTitle: String? = nil
    ) {
        guard let notice, let kind = Kind(rawValue: notice) else { return nil }
        self.kind = kind
        self.commandTitle = commandTitle
        let name = extensionTitle.isEmpty ? id.key : extensionTitle
        let settings = ("Open Extension Settings", RootAction.configureExtension(id))
        let retry: [(String, KeyShortcut?, RootAction)] =
            commandID.map { [("Try Again", RootActions.enter, .retryCommand($0))] } ?? []
        switch kind {
        case .off:
            title = "Sign-in is off"
            self.message = Self.offText(extensionTitle: name)
            actions = RootActions.section([
                (settings.0, RootActions.enter, settings.1),
                ("Open Sign-in Settings", Self.signInSettingsShortcut, .openSignInSettings),
            ])
            return
        case .cancelled:
            title = "Sign-in was cancelled"
            self.message = "\(name) needs to sign in to work."
        case .timedOut:
            title = "Sign-in timed out"
            self.message = "\(name) needs to sign in to work. The browser didn't come back within 5 minutes."
        case .refused:
            title = "Not signed in"
            self.message = message
        }
        let opensSettings = retry.isEmpty ? RootActions.enter : RootActions.configureExtensionShortcut
        actions = RootActions.section(retry + [(settings.0, opensSettings, settings.1)])
    }

    /// The text while sign-in is off: what the extension needs, and the two ways to give it. Without a title it's
    /// about "this extension", as the refusal's own message is (`SignInRefusal.off`), which extensions may show in a
    /// toast of their own.
    public static func offText(extensionTitle: String?) -> String {
        guard let extensionTitle else {
            return "This extension needs to sign in with OAuth to work. Turn on sign-in in Fudge's settings, or, if it "
                + "takes a token, set it in its settings."
        }
        return
            "\(extensionTitle) needs to sign in with OAuth to work. Turn on sign-in in Fudge's settings, or, if this "
            + "extension takes a token, set it in its settings."
    }

    /// What a background or menu-bar command shows in the HUD instead: the title and the text's first sentence,
    /// never a trace.
    public var hud: String {
        let first = message.range(of: ". ").map { String(message[..<$0.lowerBound]) + "." } ?? message
        return first.isEmpty ? title : "\(title). \(first)"
    }
}

/// What the launcher's bottom bar says beside Fudge's icon on a screen that isn't a command's own: the title of the
/// command a failure or notice stands in for (FUD-135), else "Fudge".
public enum LauncherFooter {
    public static let fudge = "Fudge"

    public static func title(standingInFor commandTitle: String?) -> String {
        guard let commandTitle, !commandTitle.isEmpty else { return fudge }
        return commandTitle
    }
}
