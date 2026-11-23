import Foundation
import Testing

@testable import FudgeCore

// SPEC-132 Part 1 (FUD-165): sign-in for extensions with their own OAuth app, straight to their service and back
// through Raycast's return address. Nothing here names a particular extension (D-83).

private let state = "eyJpZCI6IkFBQUFBQUFBQUFBQUFBQUFBQUFBQUEifQ"

// MARK: - Raycast's hosts: one definition

@Test func raycastsHostsAreItsDomainAndEveryHostUnderIt() {
    #expect(OAuthProviders.raycastDomains == ["raycast.com"])
    for host in [
        "raycast.com", "www.raycast.com", "RAYCAST.com", "www.Raycast.COM.", "raycast.com..",
        "github.oauth.raycast.com",
        "notion.oauth-proxy.raycast.com", "apple-music-oauth.raycast.com",
    ] {
        #expect(OAuthProviders.isRaycastDomainHost(host), "\(host)")
    }
    for host in ["raycast.com.evil.test", "notraycast.com", "evilraycast.com", "raycast.co", "", "example.com"] {
        #expect(!OAuthProviders.isRaycastDomainHost(host), "\(host)")
    }
    // The worker gets the same list, so `oauth.prepare` and the fetch rewrite can't drift apart.
    #expect(OAuthProviders.raycastDomainsEnvironmentKey == "FUDGE_RAYCAST_DOMAINS")
    #expect(OAuthProviders.raycastDomainsEnvironmentValue == #"["raycast.com"]"#)
}

@Test func theTablesOwnAuthorizeHostsAreReadFromTheTable() {
    #expect(OAuthProviders.ownAuthorizeHosts == ["accounts.google.com", "auth.atlassian.com", "zoom.us"])
    for provider in OAuthProviders.all {
        let host = URL(string: provider.authorizeURL)!.host!
        #expect(OAuthProviders.isOwnAuthorizeHost(host) != OAuthProviders.isRaycastDomainHost(host), "\(host)")
    }
    #expect(OAuthProviders.isOwnAuthorizeHost("Accounts.Google.com."))
    #expect(!OAuthProviders.isOwnAuthorizeHost("google.com"))
}

// MARK: - `oauth.prepare`'s route (§2)

private func route(
    _ endpoint: String, method: String = "web", server: SignInServer = .fudge, on: Bool = true
) -> Result<PreparedSignIn.Route, SignInRefusal> {
    PreparedSignIn.route(
        for: endpoint, providerName: "Example", redirectMethod: method, server: server, ownAppSignIn: on)
}

@Test func theTablesEndpointsStayOnTheRelayPath() {
    for provider in OAuthProviders.all {
        for on in [true, false] {
            let routed = route(provider.authorizeURL, on: on)
            #expect(
                routed.value
                    == .relay(provider, authorizeURL: "https://fudge-oauth.rackofpain.net/\(provider.id)/authorize"),
                "\(provider.authorizeURL)")
        }
        // The server's Off still refuses the relay path, whatever the new switch says.
        #expect(route(provider.authorizeURL, server: .off).failure == .off)
    }
}

@Test func raycastsHostsAndTheTablesOwnHostsAreRefusedAsBefore() {
    var refused = [
        "https://www.raycast.com/oauth/authorize", "https://raycast.com/oauth/authorize",
        "https://WWW.Raycast.COM./oauth/authorize", "https://x.oauth.raycast.com/authorize",
        "https://github.oauth.raycast.com/authorize/", "https://x.oauth-proxy.raycast.com/authorize",
        "https://apple-music-oauth.raycast.com/authorize", "https://accounts.google.com/o/oauth2/auth",
        "https://ACCOUNTS.GOOGLE.COM./o/oauth2/v2/auth?x=1",
    ]
    // Step 2a: every table entry's own authorize host, from the table, with any URL there but the table's own.
    refused += OAuthProviders.ownAuthorizeHosts.map { "https://\($0)/another/authorize" }
    for endpoint in refused {
        #expect(route(endpoint).failure == .unknownProvider("Example"), "\(endpoint)")
        #expect(route(endpoint, server: .off).failure == .off, "\(endpoint): what it was before, with the server off")
    }
}

@Test func anyOtherHTTPSEndpointTakesTheDirectPathWithRaycastsRedirectForItsMethod() {
    let endpoint = "https://auth.example.com/oauth/authorize?audience=x"
    #expect(
        route(endpoint, method: "web").value
            == .direct(.web, authorizeURL: endpoint, redirectURI: "https://raycast.com/redirect?packageName=Extension"))
    #expect(
        route(endpoint, method: "app").value
            == .direct(.app, authorizeURL: endpoint, redirectURI: "raycast://oauth?package_name=Extension"))
    #expect(
        route(endpoint, method: "appURI").value
            == .direct(.appURI, authorizeURL: endpoint, redirectURI: "com.raycast:/oauth?package_name=Extension"))
    // The server's Off leaves the direct path alone: the two switches are independent.
    #expect(route(endpoint, server: .off).value != nil)
    // The method names are Raycast's `OAuth.RedirectMethod` values.
    #expect(OAuthRedirectMethod.allCases.map(\.rawValue) == ["web", "app", "appURI"])
}

@Test func otherMethodsAndEndpointsThatArentHTTPSAreRefused() {
    let endpoint = "https://auth.example.com/authorize"
    for method in ["clientIdMetadataDocument", "Web", "somethingNew", ""] {
        #expect(route(endpoint, method: method).failure == .unknownProvider("Example"), "\(method)")
    }
    for other in [
        "http://auth.example.com/authorize", "https://user@auth.example.com/authorize",
        "https://user:secret@auth.example.com/authorize", "https:///authorize", "auth.example.com/authorize",
        "not a url", "", "javascript:alert(1)",
    ] {
        #expect(route(other).failure == .unknownProvider("Example"), "\(other)")
    }
}

@Test func whileTheSwitchIsOffADirectSignInIsRefusedWithOff() {
    #expect(route("https://auth.example.com/authorize", on: false).failure == .off, "the existing `off` refusal")
    #expect(route("https://auth.example.com/authorize", server: .off, on: false).failure == .off)
}

// MARK: - The URL ↵ opens on the direct path (§4)

@Test func theDirectPathOpensAnyHTTPSURLWithThisRequestsState() {
    let request = PreparedSignIn(
        path: .direct(.web), authorizeURL: "https://auth.example.com/authorize",
        redirectURI: OAuthRedirectMethod.web.raycastRedirectURI)
    #expect(request.provider == nil && request.directMethod == .web)
    // Another host and path, since some extensions build the URL themselves.
    let built = "https://login.example.org/o/auth?client_id=x&state=\(state)&redirect_uri=x"
    #expect(request.state(ofAuthorizeURL: built) == state)
    #expect(request.state(ofAuthorizeURL: built, given: state) == state)
    #expect(request.state(ofAuthorizeURL: built, given: "another") == nil, "the state the extension sends must match")
    for refused in [
        "https://login.example.org/o/auth?client_id=x", "https://login.example.org/o/auth?state=",
        "http://login.example.org/o/auth?state=\(state)", "https://u:p@login.example.org/o/auth?state=\(state)",
        "https://www.raycast.com/oauth/authorize?state=\(state)", "https://zoom.us/oauth/authorize?state=\(state)",
        "https://accounts.google.com/o/oauth2/v2/auth?state=\(state)", "raycast://oauth?state=\(state)",
    ] {
        #expect(request.state(ofAuthorizeURL: refused) == nil, "\(refused)")
    }
}

// MARK: - Raycast's return link (§3.2)

@Test func bothReturnLinkShapesEndTheWaitWithThisSignInsState() {
    #expect(
        RaycastReturn.read(link: "raycast://oauth?package_name=Extension&state=\(state)&code=c1", state: state)
            == .code("c1"))
    #expect(
        RaycastReturn.read(link: "com.raycast:/oauth?package_name=Extension&code=c2&state=\(state)", state: state)
            == .code("c2"))
    #expect(RaycastReturn.read(link: "RAYCAST://OAuth?state=\(state)&code=c3", state: state) == .code("c3"))
    #expect(RaycastReturn.read(link: "COM.Raycast:/oauth?state=\(state)&code=c4", state: state) == .code("c4"))
    #expect(
        RaycastReturn.read(
            link: "raycast://oauth?state=\(state)&error=access_denied&error_description=No", state: state)
            == .error("access_denied", description: "No"))
    // `package_name` and `iss` are ignored; the first of each is read.
    #expect(RaycastReturn.read(link: "raycast://oauth?iss=x&state=\(state)&code=a&code=b", state: state) == .code("a"))
}

@Test func otherLinksAndOtherStatesAreIgnored() {
    #expect(RaycastReturn.read(link: "raycast://extensions/raycast/github", state: state) == .notFound)
    #expect(RaycastReturn.read(link: "raycast://oauth/x?state=\(state)&code=c", state: state) == .notFound)
    #expect(RaycastReturn.read(link: "com.raycast://oauth?state=\(state)&code=c", state: state) == .notFound)
    #expect(RaycastReturn.read(link: "https://raycast.com/redirect?state=\(state)&code=c", state: state) == .notFound)
    #expect(RaycastReturn.read(link: "raycast://oauth?state=another&code=c", state: state) == .invalid)
    #expect(RaycastReturn.read(link: "raycast://oauth?state=\(state)", state: state) == .invalid, "no code or error")
    #expect(RaycastReturn.read(link: "raycast://oauth?code=c", state: state) == .invalid, "no state")
    #expect(!RaycastReturn.read(link: "raycast://oauth?state=another&code=c", state: state).endsWait)
}

@Test func theStateIsComparedWithTheConstantTimeCompare() {
    #expect(OAuthCallback.constantTimeEqual(state, state))
    #expect(!OAuthCallback.constantTimeEqual(state, String(state.dropLast()) + "x"))
    #expect(!OAuthCallback.constantTimeEqual(state, String(state.dropLast())))
    #expect(!OAuthCallback.constantTimeEqual("", state))
    // The link, the paste and the loopback all read their query through the one function that uses it.
    let items = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "c")]
    #expect(OAuthCallback.read(query: items, state: state) == .code("c"))
}

// MARK: - The paste (§4)

@Test func aPastedAddressFromThisSignInEndsTheWait() {
    let query = "packageName=Extension&state=\(state)&code=c"
    for pasted in [
        "https://raycast.com/redirect?\(query)", "https://www.raycast.com/redirect?\(query)",
        "https://raycast.com/redirect/extension?\(query)", "raycast://oauth?\(query)",
        "  \n https://raycast.com/redirect?\(query) \t\n", "https://some.other.page/after/a/redirect?\(query)",
    ] {
        #expect(RaycastReturn.read(pasted: pasted, state: state) == .code("c"), "\(pasted)")
    }
}

@Test func aPasteThatIsntThisSignInsAddressKeepsItWaiting() {
    #expect(RaycastReturn.read(pasted: "https://raycast.com/redirect?state=another&code=c", state: state) == .invalid)
    #expect(RaycastReturn.read(pasted: "https://raycast.com/redirect?state=\(state)", state: state) == .invalid)
    for notAnAddress in [
        "not a url", "", "c0de", "http://raycast.com/redirect?state=\(state)&code=c",
        "com.raycast:/oauth?state=\(state)&code=c", "raycast://extensions/x?state=\(state)&code=c",
        "https:///redirect?state=\(state)&code=c",
    ] {
        #expect(!RaycastReturn.read(pasted: notAnAddress, state: state).endsWait, "\(notAnAddress)")
    }
    let huge = "https://raycast.com/redirect?state=\(state)&code=c&x=" + String(repeating: "a", count: 20_000)
    #expect(RaycastReturn.read(pasted: huge, state: state) == .notFound, "longer than any real address")
    #expect(RaycastReturn.pasteProblem == "That address isn't from this sign-in.")
    // Only Web's address shows in the browser.
    #expect(OAuthRedirectMethod.allCases.filter(\.canPaste) == [.web])
}

// MARK: - Nothing direct is pending for the fetch rewrite

private final class Wait {}

@Test func aDirectSignInIsNeverPendingAndStoresNoRelayProvider() {
    var requests = SignInRequests<Wait>()
    let wait = Wait()
    let direct = PreparedSignIn(
        path: .direct(.app), authorizeURL: "https://auth.example.com/authorize",
        redirectURI: OAuthRedirectMethod.app.raycastRedirectURI)
    _ = requests.prepare((direct, wait), for: "s1")
    #expect(requests.pending(of: "s1").isEmpty, "prepared")
    _ = requests.show("s1")
    #expect(requests.pending(of: "s1").isEmpty, "shown")
    let finished = requests.finish(wait, signedIn: true)
    #expect(finished)
    #expect(requests.pending(of: "s1").isEmpty, "signed in: its token exchange goes where it was going")
}

// MARK: - The switch (§5, D-89)

@Test func theSwitchCountsOnlyWithItsConsentAndOffRemovesBoth() throws {
    var settings = FudgeSettings()
    #expect(!settings.isOwnAppSignInOn, "off by default")
    settings.ownAppSignIn = true
    #expect(!settings.isOwnAppSignInOn, "a hand-set true counts as off")
    settings.ownAppSignInConsentAt = "not a date"
    #expect(!settings.isOwnAppSignInOn)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    settings.setOwnAppSignIn(true, now: now)
    #expect(settings.isOwnAppSignInOn)
    #expect(settings.ownAppSignInConsentAt == ISO8601DateFormatter().string(from: now))
    #expect(settings.signIn == .off, "independent of the server choice")

    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try settings.save(to: file)
    #expect(FudgeSettings.load(from: file).isOwnAppSignInOn)
    settings.setOwnAppSignIn(false, now: now)
    try settings.save(to: file)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    #expect(object["ownAppSignIn"] == nil && object["ownAppSignInConsentAt"] == nil, "off removes both")
}

@Test func theSwitchesWordsAreTheArchitectsOneString() {
    #expect(OwnAppSignIn.title == "Extensions with their own sign-in")
    #expect(
        OwnAppSignIn.explanation
            == "Let extensions sign in with their own apps. Most of them come back through raycast.com.")
}

@Test func theSwitchIsThisMacsAndItsConsentNeverLeavesInABackup() {
    #expect(Backup.consentKeys.contains("ownAppSignIn") && Backup.consentKeys.contains("ownAppSignInConsentAt"))
    #expect(Backup.exportStrippedKeys.contains("ownAppSignInConsentAt"))
    #expect(!Backup.exportStrippedKeys.contains("ownAppSignIn"), "the switch goes along, as the store's does")
}

// MARK: - Raycast's links and onboarding's step (§3.3, D-88)

private let fudge = URL(fileURLWithPath: "/Applications/Fudge.app", isDirectory: true)
private let helper = RaycastLinksHelper.url(in: fudge)
private let raycast = URL(fileURLWithPath: "/Applications/Raycast.app", isDirectory: true)

@Test func fudgeLinksIsInsideTheAppsHelpers() {
    #expect(helper.path == "/Applications/Fudge.app/Contents/Helpers/Fudge Links.app")
    #expect(RaycastLinksHelper.holder(of: helper).path == fudge.path)
    #expect(RaycastLinksHelper.bundleIdentifier == "io.github.jakeobsen.fudge.links")
    #expect(RaycastLinksHelper.bundleIdentifier.hasPrefix(FudgeVersion.bundleIdentifier + "."))
}

@Test func whoOpensRaycastsLinks() {
    #expect(FixedRaycastLinks(app: helper).status(helper: helper) == .fudge)
    #expect(FixedRaycastLinks(app: raycast).status(helper: helper) == .elsewhere("Raycast"))
    #expect(FixedRaycastLinks(app: nil).status(helper: helper) == .elsewhere(nil))
    #expect(RaycastLinksStatus.fudge.line == "Raycast links open Fudge.")
    #expect(RaycastLinksStatus.elsewhere("Raycast").line == "Raycast links open Raycast.")
    #expect(RaycastLinksStatus.elsewhere(nil).line == "No app opens Raycast links.")
}

@Test func fudgeOpensThemOnlyWhenFudgeLinksOpensBothShapes() async throws {
    let links = FixedRaycastLinks(app: helper)
    try await links.open(scheme: "com.raycast", with: raycast)
    #expect(links.status(helper: helper) == .elsewhere("Raycast"))
    // Fudge.app itself, a build from before Fudge Links that declares the schemes, isn't Fudge Links.
    let older = FixedRaycastLinks(app: fudge)
    older.identifiers = [fudge.path: FudgeVersion.bundleIdentifier]
    #expect(older.status(helper: helper) == .elsewhere("another copy of Fudge"))
}

@Test func anotherCopysFudgeLinksOrAnOlderBuildIsAnotherCopyOfFudge() {
    let copy = URL(fileURLWithPath: "/Users/someone/build/Fudge.app", isDirectory: true)
    let copysHelper = FixedRaycastLinks(app: RaycastLinksHelper.url(in: copy))
    copysHelper.identifiers = [RaycastLinksHelper.url(in: copy).path: RaycastLinksHelper.bundleIdentifier]
    #expect(copysHelper.status(helper: helper) == .elsewhere("another copy of Fudge"))
    let olderBuild = FixedRaycastLinks(app: copy)
    olderBuild.identifiers = [copy.path: FudgeVersion.bundleIdentifier]
    #expect(olderBuild.status(helper: helper) == .elsewhere("another copy of Fudge"))
}

@Test func openWithFudgeRegistersFudgeLinksThenSetsBothSchemes() async {
    let links = FixedRaycastLinks(app: raycast)
    let (status, problem) = await links.openWithFudge(helper: helper, location: .installed)
    #expect(links.registered == [helper])
    #expect(links.opened == ["raycast", "com.raycast"])
    #expect(status == .fudge && problem == nil)
}

@Test func openWithFudgeChangesNothingFromTheDiskImageOrATranslocatedCopy() async {
    for location in [AppLocation.diskImage, .translocated] {
        let links = FixedRaycastLinks(app: raycast)
        let (status, problem) = await links.openWithFudge(helper: helper, location: location)
        #expect(links.registered.isEmpty && links.opened.isEmpty, "nothing changed from \(location)")
        #expect(status == .elsewhere("Raycast"))
        #expect(problem == "Move Fudge to Applications first, so it can open Raycast links.")
    }
}

private struct Refused: LocalizedError {
    var errorDescription: String? { "The system refused." }
}

@Test func aRefusedRegistrationShowsItsMessageAndChangesNoScheme() async {
    let links = FixedRaycastLinks(app: raycast)
    links.registrationRefusal = Refused()
    let (status, problem) = await links.openWithFudge(helper: helper, location: .installed)
    #expect(links.registered == [helper] && links.opened.isEmpty)
    #expect(status == .elsewhere("Raycast"))
    #expect(problem == "The system refused.")
}

@Test func aRefusedSchemeShowsTheSystemsMessageAndReadsTheStatusAgain() async {
    let links = FixedRaycastLinks(app: raycast)
    links.refusal = Refused()
    let (status, problem) = await links.openWithFudge(helper: helper, location: .installed)
    #expect(links.opened == ["raycast", "com.raycast"])
    #expect(status == .elsewhere("Raycast"))
    #expect(problem == "The system refused.")
}

/// A fake LaunchServices that accepts every change but never makes Fudge Links (or the other app) the opener.
private final class Ignoring: RaycastLinks, @unchecked Sendable {
    let app: URL
    init(app: URL) { self.app = app }
    func opener(of url: URL) -> URL? { app }
    func claimants(of url: URL) -> [URL] { [app, raycast] }
    func bundleIdentifier(of app: URL) -> String? { nil }
    func register(_ app: URL) throws {}
    func open(scheme: String, with app: URL) async throws {}
}

@Test func aChangeThatDoesntTakeSaysSo() async {
    let on = await Ignoring(app: raycast).openWithFudge(helper: helper, location: .installed)
    #expect(on.status == .elsewhere("Raycast") && on.problem == "macOS didn't make Fudge open Raycast links.")
    let off = await Ignoring(app: helper).giveBack(to: raycast, helper: helper)
    #expect(off.status == .fudge && off.problem == "macOS didn't give Raycast links back to Raycast.")
}

@Test func switchingOffGivesBothSchemesBackToTheOtherApp() async {
    let links = FixedRaycastLinks(app: helper)
    links.claim(raycast)
    #expect(links.handBackTarget(helper: helper) == raycast)
    let (status, problem) = await links.giveBack(to: raycast, helper: helper)
    #expect(links.opened == ["raycast", "com.raycast"])
    #expect(links.registered.isEmpty)
    #expect(status == .elsewhere("Raycast") && problem == nil)
    // A refusal shows the system's message, and the switch shows who opens them.
    let refused = FixedRaycastLinks(app: helper)
    refused.claim(raycast)
    refused.refusal = Refused()
    let result = await refused.giveBack(to: raycast, helper: helper)
    #expect(result.status == .fudge && result.problem == "The system refused.")
}

@Test func theAppToGiveThemBackToClaimsBothAndIsntFudges() async throws {
    // Raycast claims both.
    let both = FixedRaycastLinks(app: helper)
    both.claim(raycast)
    #expect(both.handBackTarget(helper: helper) == raycast)
    // Raycast claims only one: nothing to give both back to.
    let one = FixedRaycastLinks(app: helper)
    try await one.open(scheme: "raycast", with: raycast)
    try await one.open(scheme: "raycast", with: helper)
    #expect(one.claimants(of: URL(string: "raycast://oauth")!).contains(raycast))
    #expect(one.handBackTarget(helper: helper) == nil)
    // Only copies of Fudge besides Fudge Links: none.
    let copy = URL(fileURLWithPath: "/Users/someone/build/Fudge.app", isDirectory: true)
    let copies = FixedRaycastLinks(app: helper)
    copies.claim(copy)
    copies.claim(RaycastLinksHelper.url(in: copy))
    copies.identifiers = [
        copy.path: FudgeVersion.bundleIdentifier,
        RaycastLinksHelper.url(in: copy).path: RaycastLinksHelper.bundleIdentifier,
    ]
    #expect(copies.handBackTarget(helper: helper) == nil)
    // Nobody else.
    #expect(FixedRaycastLinks(app: helper).handBackTarget(helper: helper) == nil)
}

@Test func theSwitchShowsWhoOpensThemAndWhenItCantBeTurnedOff() {
    #expect(RaycastLinksToggle.title == "Fudge opens Raycast links")
    let on = RaycastLinksToggle(status: .fudge, giveBackTo: "Raycast")
    #expect(on.isOn && on.canChange && on.note == "Turn it off to give them back to Raycast.")
    // On with no other app to give them back to: it can't be switched off, and says why.
    let kept = RaycastLinksToggle(status: .fudge, giveBackTo: nil)
    #expect(kept.isOn && !kept.canChange && kept.note == "No other app can open them, so Fudge keeps them.")
    // Off, it can always be switched on, and says who opens them.
    for (status, note) in [
        (RaycastLinksStatus.elsewhere("Raycast"), "Raycast links open Raycast."),
        (.elsewhere("another copy of Fudge"), "Raycast links open another copy of Fudge."),
        (.elsewhere(nil), "No app opens Raycast links."),
    ] {
        for giveBackTo in ["Raycast", nil] {
            let off = RaycastLinksToggle(status: status, giveBackTo: giveBackTo)
            #expect(!off.isOn && off.canChange && off.note == note)
        }
    }
}

@Test func fudgeLinksHandsOnOnlyRaycastsSchemes() {
    for link in [
        "raycast://oauth?state=s&code=c", "RAYCAST://x", "com.raycast:/oauth?code=c", "COM.Raycast:/oauth",
        "raycast://extensions/a/b",
    ] {
        #expect(RaycastLinksHelper.handsOn(link), "\(link)")
    }
    for link in [
        "https://raycast.com/redirect?code=c", "raycastx://oauth", "com.raycast.macos://x", "fudge://x", "oauth", "",
        "not a link at all",
    ] {
        #expect(!RaycastLinksHelper.handsOn(link), "\(link)")
    }
}

@Test func fudgeLinksHandsTheLinkToEveryRunningFudgeHolderFirst() {
    let other = URL(fileURLWithPath: "/Users/someone/build/Fudge.app", isDirectory: true)
    let third = URL(fileURLWithPath: "/Applications/Fudge 2.app", isDirectory: true)
    // The holder among the running ones comes first, whatever the order, and each app gets it once.
    #expect(
        RaycastLinksHelper.targets(running: [other, fudge, third, other], holder: fudge, holderIsFudge: true)
            == [fudge, other, third])
    // Another running Fudge gets it rather than launching the holder.
    #expect(RaycastLinksHelper.targets(running: [other], holder: fudge, holderIsFudge: true) == [other])
    // With none running, the holder when it's Fudge; else none.
    #expect(RaycastLinksHelper.targets(running: [], holder: fudge, holderIsFudge: true) == [fudge])
    #expect(RaycastLinksHelper.targets(running: [], holder: fudge, holderIsFudge: false).isEmpty)
}

@Test func aSnapshotRunsFixedAnswer() {
    #expect(FixedRaycastLinks(snapshotValue: "fudge", helper: helper).status(helper: helper) == .fudge)
    #expect(FixedRaycastLinks(snapshotValue: "Raycast", helper: helper).status(helper: helper) == .elsewhere("Raycast"))
    #expect(FixedRaycastLinks(snapshotValue: "", helper: helper).status(helper: helper) == .elsewhere(nil))
    let both = FixedRaycastLinks(snapshotValue: "fudge,Raycast", helper: helper)
    #expect(both.status(helper: helper) == .fudge)
    #expect(both.handBackTarget(helper: helper) == raycast)
    #expect(FixedRaycastLinks(snapshotValue: "fudge", helper: helper).handBackTarget(helper: helper) == nil)
}

/// The repository's `App/…` file at `path`.
private func appPlist(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(path)
    return try #require(
        PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
}

@Test func onlyFudgeLinksDeclaresRaycastsSchemes() throws {
    #expect(try appPlist("App/Info.plist")["CFBundleURLTypes"] == nil, "Fudge.app declares no URL types (D-107)")
    let links = try appPlist("App/Links/Info.plist")
    #expect(links["CFBundleIdentifier"] as? String == RaycastLinksHelper.bundleIdentifier)
    #expect(links["CFBundleExecutable"] as? String == "FudgeLinks")
    #expect(links["CFBundleName"] as? String == RaycastLinksHelper.name)
    #expect(links["CFBundleDisplayName"] as? String == RaycastLinksHelper.name)
    #expect(links["LSUIElement"] as? Bool == true)
    #expect(links["NSHumanReadableCopyright"] == nil)
    let types = try #require(links["CFBundleURLTypes"] as? [[String: Any]])
    #expect(types.count == 1)
    #expect(types.first?["CFBundleURLSchemes"] as? [String] == RaycastReturn.schemes)
}

@Test func theRaycastStepsReturnChangesNothing() {
    for links in [RaycastLinksStatus.fudge, .elsewhere("Raycast"), .elsewhere(nil)] {
        for on in [true, false] {
            let buttons = RaycastStep.buttons(links: links, ownAppSignInOn: on)
            #expect(buttons.defaultButton == .next, "↵ neither changes the Mac nor turns anything on")
            #expect(buttons.all.last == .next)
            #expect(buttons.all.contains(.openLinks) == !links.isFudge)
            #expect(buttons.all.contains(.turnOnOwnAppSignIn) == !on)
            let title = RaycastStep.nextTitle(links: links, ownAppSignInOn: on)
            #expect(title == (links.isFudge && on ? "Continue" : "Not Now"))
        }
    }
    #expect(RaycastStep.Button.openLinks.title == "Open Raycast Links with Fudge")
    #expect(RaycastStep.Button.turnOnOwnAppSignIn.title == "Turn On")
    #expect(OnboardingStep.optIns["ownAppSignIn"] == .raycast)
    #expect(OnboardingStep.raycast.rawValue == "raycast", "the id kept in onboarding.json")
}

@Test func theStepExplainsTheClashAndThePromptPointsToSettings() {
    #expect(RaycastStep.explanation.contains("Fudge runs extensions made for Raycast."))
    #expect(RaycastStep.explanation.contains("ends with a Raycast link, which has to open Fudge"))
    #expect(RaycastStep.linksNote == "Raycast's own links then open Fudge too.")
    #expect(RaycastReturn.elsewhereHint(.fudge) == nil)
    let hint = RaycastReturn.elsewhereHint(.elsewhere("Raycast"))
    #expect(hint?.contains("Raycast links open Raycast") == true)
    #expect(hint?.contains("Settings → Sign-in") == true)
    #expect(RaycastReturn.elsewhereHint(.elsewhere(nil))?.contains("don't open Fudge") == true)
}

extension Result {
    fileprivate var failure: Failure? { if case .failure(let failure) = self { failure } else { nil } }
    fileprivate var value: Success? { if case .success(let value) = self { value } else { nil } }
}
