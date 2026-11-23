import Foundation
import Testing

@testable import FudgeCore

private func notice(
    _ kind: String?, message: String = "", title: String = "GitHub", command: String? = "github/search-repositories"
) -> SignInNotice? {
    SignInNotice(notice: kind, message: message, extension: github, extensionTitle: title, commandID: command)
}

private let github = ExtensionID(stored: "github")!

private let enter = KeyShortcut(key: "return", modifiers: [])

@Test func signInOffIsANoticeWithTheExtensionsSettingsAndSignIns() throws {
    let off = try #require(notice("signInOff", message: SignInRefusal.off.message))
    #expect(off.kind == .off)
    #expect(off.title == "Sign-in is off")
    #expect(
        off.message
            == "GitHub needs to sign in with OAuth to work. Turn on sign-in in Fudge's settings, or, if this extension "
            + "takes a token, set it in its settings.")
    let entries = off.actions.flatMap(\.entries)
    #expect(entries.map(\.title) == ["Open Extension Settings", "Open Sign-in Settings"])
    #expect(entries.map(\.target) == [.root(.configureExtension(github)), .root(.openSignInSettings)])
    #expect(entries.map(\.shortcut) == [enter, KeyShortcut(key: ",", modifiers: ["cmd", "opt"])])
    #expect(off.hud == "Sign-in is off. GitHub needs to sign in with OAuth to work.")
}

@Test func aCancelledOrTimedOutSignInOffersToTryAgain() throws {
    for (kind, title) in [("signInCancelled", "Sign-in was cancelled"), ("signInTimedOut", "Sign-in timed out")] {
        let stopped = try #require(notice(kind, message: "Sign-in was cancelled."))
        #expect(stopped.title == title)
        #expect(stopped.message.hasPrefix("GitHub needs to sign in to work."))
        let entries = stopped.actions.flatMap(\.entries)
        #expect(entries.map(\.title) == ["Try Again", "Open Extension Settings"])
        #expect(
            entries.map(\.target) == [
                .root(.retryCommand("github/search-repositories")), .root(.configureExtension(github)),
            ])
        #expect(entries.map(\.shortcut) == [enter, RootActions.configureExtensionShortcut])
        #expect(stopped.hud == "\(title). GitHub needs to sign in to work.")
    }
    // Without a command to run again (a menu-bar command's HUD), the settings are what ↵ does.
    let entries = try #require(notice("signInCancelled", command: nil)).actions.flatMap(\.entries)
    #expect(entries.map(\.title) == ["Open Extension Settings"])
    #expect(entries.first?.shortcut == enter)
}

@Test func aRefusedSignInShowsTheProvidersReasonWithoutATrace() throws {
    let reason = SignInRefusal.refused(provider: "GitHub", error: "access_denied", description: "The user denied it")
    let refused = try #require(notice(reason.notice?.rawValue, message: reason.message))
    #expect(refused.title == "Not signed in")
    #expect(refused.message == "GitHub didn't sign you in: The user denied it")
    #expect(refused.hud == "Not signed in. GitHub didn't sign you in: The user denied it")
    #expect(refused.actions.flatMap(\.entries).map(\.title) == ["Try Again", "Open Extension Settings"])
}

@Test func anyOtherErrorStaysAFailure() {
    #expect(notice(nil) == nil, "no notice: the failure view, with its details")
    #expect(notice("somethingNewer") == nil, "a kind this version doesn't know: the failure view too")
    #expect(notice("signInOff ") == nil, "never matched loosely")
}

@Test func aNoticeNamesTheExtensionByItsTitleElseItsName() throws {
    #expect(try #require(notice("signInOff", title: "")).message.hasPrefix("github needs to sign in"))
    #expect(try #require(notice("signInOff", title: "GitHub")).message.hasPrefix("GitHub needs to sign in"))
}

@Test func onlyRefusalsOnPurposeCarryANotice() {
    #expect(SignInRefusal.off.notice == .off)
    #expect(SignInRefusal.cancelled.notice == .cancelled)
    #expect(SignInRefusal.timedOut.notice == .timedOut)
    #expect(SignInRefusal.refused(provider: "GitHub", error: "e", description: nil).notice == .refused)
    for failure in [
        SignInRefusal.unknownProvider("X"), .background, .busy, .notPrepared, .browser,
    ] {
        #expect(failure.notice == nil, "\(failure)")
    }
}

/// The runtime's tests read the same file, so the worker's own refusal (`signInOffMessage`, when the fetch rewrite
/// refuses while sign-in is off) and the notice kinds can't drift from the app's.
@Test func theRefusalAndTheKindsMatchTheRuntimesFixture() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("runtime/test/fixtures/sign-in-notice.json")
    struct Pinned: Decodable {
        var signInOffMessage: String
        var kinds: [String]
    }
    let pinned = try JSONDecoder().decode(Pinned.self, from: Data(contentsOf: fixture))
    #expect(SignInRefusal.off.message == pinned.signInOffMessage)
    #expect(SignInRefusal.off.message.hasPrefix("Sign-in is off. This extension needs to sign in with OAuth"))
    #expect(SignInNotice.Kind.allCases.map(\.rawValue) == pinned.kinds)
}

// MARK: - The footer names the command (FUD-135 §1)

@Test func aNoticeInACommandsPlaceKeepsItsTitleInTheFooter() throws {
    let acme = try #require(ExtensionID(stored: "acme"))
    let notice = try #require(
        SignInNotice(
            notice: "signInOff", message: "x", extension: acme, extensionTitle: "Acme",
            commandID: "acme/issues", commandTitle: "Acme Issues"))
    #expect(notice.footerTitle == "Acme Issues")
    // One that belongs to no command, like the Extension Store's "off" notice, keeps "Fudge".
    let unnamed = try #require(
        SignInNotice(notice: "signInOff", message: "x", extension: acme, extensionTitle: "Acme", commandID: nil))
    #expect(unnamed.footerTitle == "Fudge")
    #expect(LauncherFooter.title(standingInFor: nil) == LauncherFooter.fudge)
    #expect(LauncherFooter.title(standingInFor: "") == "Fudge")
}
