import Foundation
import Testing

@testable import FudgeCore

@Test func nothingAnsweredShowsEveryStep() {
    let onboarding = Onboarding()
    #expect(
        onboarding.pending == [
            .welcome, .hotkey, .accessibility, .openAtLogin, .currency, .extensionStore, .signIn, .clipboardHistory,
            .snippetExpansion, .hyperkey, .updates, .done,
        ])
    #expect(onboarding.pending == OnboardingStep.allCases, "the cases are the one step list")
    #expect(!onboarding.isComplete)
    #expect(!onboarding.hasSomethingNew)
}

@Test func someAnsweredShowsTheRestThenDone() {
    var onboarding = Onboarding()
    onboarding.answer(.welcome)
    onboarding.answer(.hotkey)
    #expect(
        onboarding.pending == [
            .accessibility, .openAtLogin, .currency, .extensionStore, .signIn, .clipboardHistory, .snippetExpansion,
            .hyperkey,
            .updates, .done,
        ], "Welcome isn't shown again")
    #expect(!onboarding.hasSomethingNew, "not completed yet, so nothing is new")
}

@Test func doneIsNeededForCompletion() {
    var onboarding = Onboarding()
    for step in OnboardingStep.allCases where step != .done { onboarding.answer(step) }
    #expect(onboarding.pending == [.done], "every step answered, but Done not clicked")
    #expect(!onboarding.isComplete)
    onboarding.answer(.done)
    #expect(onboarding.pending == [])
    #expect(onboarding.isComplete)
    #expect(!onboarding.hasSomethingNew)
}

@Test func notNowCountsAsAnAnswer() {
    var onboarding = Onboarding()
    onboarding.answer(.welcome)
    onboarding.answer(.hotkey)
    // "Not now" on Accessibility answers it as Continue would.
    onboarding.answer(.accessibility)
    #expect(
        onboarding.pending == [
            .openAtLogin, .currency, .extensionStore, .signIn, .clipboardHistory, .snippetExpansion, .hyperkey,
            .updates, .done,
        ])
}

@Test func aNewStepShowsOnlyThatStepAndDone() {
    // A user who completed onboarding before the Currency step and the ones after it existed.
    let onboarding = Onboarding(answered: ["welcome", "hotkey", "accessibility", "openAtLogin", "done"])
    #expect(
        onboarding.pending == [
            .currency, .extensionStore, .signIn, .clipboardHistory, .snippetExpansion, .hyperkey, .updates, .done,
        ])
    #expect(onboarding.hasSomethingNew)
    #expect(!onboarding.isComplete)
    // Welcome never comes back once completed, even if its id is missing.
    let noWelcome = Onboarding(answered: ["hotkey", "accessibility", "openAtLogin", "currency", "done"])
    #expect(
        noWelcome.pending == [
            .extensionStore, .signIn, .clipboardHistory, .snippetExpansion, .hyperkey, .updates, .done,
        ])
    let complete = Onboarding(answered: OnboardingStep.allCases.map(\.rawValue) + ["retiredStep"])
    #expect(complete.isComplete, "ids that aren't a step any more don't count")
}

@Test func theUpdatesStepComesAfterTheOptInsAndShowsAloneToThoseWhoFinished() {
    let steps = OnboardingStep.allCases
    // The order agreed between FUD-114, FUD-117, FUD-101 and FUD-125: Clipboard history, Snippet expansion,
    // Hyperkey, Updates.
    #expect(steps.firstIndex(of: .hyperkey) == steps.firstIndex(of: .snippetExpansion).map { $0 + 1 })
    #expect(steps.firstIndex(of: .updates) == steps.firstIndex(of: .hyperkey).map { $0 + 1 })
    #expect(OnboardingStep.updates.rawValue == "updates", "the id kept in onboarding.json")
    // A user who completed onboarding before the Updates step existed sees just it, under "Something new to decide".
    var onboarding = Onboarding(answered: OnboardingStep.allCases.filter { $0 != .updates }.map(\.rawValue))
    #expect(onboarding.pending == [.updates, .done])
    #expect(onboarding.hasSomethingNew)
    onboarding.answer(.updates)
    #expect(onboarding.isComplete, "Done was clicked before, so answering the new step completes it")
    #expect(!onboarding.hasSomethingNew)
}

@Test func restartShowsEveryStepAgain() {
    var onboarding = Onboarding(answered: OnboardingStep.allCases.map(\.rawValue))
    onboarding.restart()
    #expect(onboarding.pending == OnboardingStep.allCases)
    #expect(!onboarding.hasSomethingNew)
}

@Test func theOnboardingFileIsReadTolerantlyAndReplacedWhenBroken() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("nested/onboarding.json")
    #expect(Onboarding.load(from: file) == Onboarding(), "a missing file: nothing answered")

    var onboarding = Onboarding()
    onboarding.answer(.welcome)
    onboarding.answer(.hotkey)
    onboarding.answer(.welcome)
    #expect(onboarding.answered == ["welcome", "hotkey"], "answering twice changes nothing")
    try onboarding.save(to: file)
    #expect(Onboarding.load(from: file) == onboarding)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String]]
    #expect(json == ["answered": ["welcome", "hotkey"]])

    try Data(#"{"answered": ["welcome", 3, "welcome", "currency"]}"#.utf8).write(to: file)
    #expect(Onboarding.load(from: file).answered == ["welcome", "currency"], "only strings, without duplicates")

    for broken in ["not json", "[1, 2]", #"{"answered": "welcome"}"#, ""] {
        try Data(broken.utf8).write(to: file)
        #expect(Onboarding.load(from: file) == Onboarding(), "\(broken): nothing answered, so onboarding shows")
        #expect(Onboarding.load(from: file).pending == OnboardingStep.allCases)
    }
    try onboarding.save(to: file)
    #expect(Onboarding.load(from: file) == onboarding, "a broken file is replaced")
}

@Test func openAccessibilitySettingsPromptsFirstThenOpensThePane() {
    #expect(AccessibilityPermission.request(promptShown: false) == .prompt)
    #expect(AccessibilityPermission.request(promptShown: true) == .openPane)
    #expect(AccessibilityPermission.reason.contains("paste"), "Paste needs it too")
}

@Test func theAccessibilityReasonNamesFudgesOwnCommandsBeforeExtensions() throws {
    let reason = AccessibilityPermission.reason
    let extensions = try #require(reason.range(of: "Extensions that read your selection or paste"))
    for own in [
        "window management", "layouts", "Switch Windows", "Search Menu Items", "snippets", "emoji", "clipboard items",
    ] {
        let named = try #require(reason.range(of: own), "\(own)")
        #expect(named.upperBound <= extensions.lowerBound, "\(own) comes before the extensions")
    }
    #expect(reason.hasSuffix("under Privacy & Security → Accessibility."))
}

@Test func clipboardHistoryComesAfterSignInAndExistingUsersSeeJustIt() {
    let steps = OnboardingStep.allCases
    #expect(steps.firstIndex(of: .clipboardHistory) == steps.firstIndex(of: .signIn)! + 1)
    #expect(steps.last == .done)

    // Someone who finished onboarding before the step existed: just it, then Done, as something new.
    let existing = Onboarding(answered: OnboardingStep.allCases.filter { $0 != .clipboardHistory }.map(\.rawValue))
    #expect(existing.pending == [.clipboardHistory, .done])
    #expect(existing.hasSomethingNew)
}

@Test func theStepsChoiceWritesWhatTheSwitchWrites() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var fromStep = FudgeSettings()
    fromStep.setClipboardHistory(true, now: now)
    #expect(fromStep.isClipboardHistoryOn)
    #expect(fromStep.clipboardHistoryConsentAt == ISO8601DateFormatter().string(from: now))
    #expect(!FudgeSettings().isClipboardHistoryOn, "Not Now writes nothing, so it stays off")
}

@Test func theConsentTextIsOneSharedString() {
    let message = ClipboardHistory.consentMessage
    for clause in [
        "keep what you copy", "encrypted on this Mac", "password managers mark as private are skipped",
        "Extensions can read it, as in Raycast.",
    ] {
        #expect(message.contains(clause), "\(clause)")
    }
}

// MARK: - Every opt-in asks (SPEC-096)

@Test func theStepsAreInTheirAgreedOrder() {
    #expect(
        OnboardingStep.allCases == [
            .welcome, .hotkey, .accessibility, .openAtLogin, .currency, .extensionStore, .signIn, .clipboardHistory,
            .snippetExpansion, .hyperkey, .updates, .done,
        ])
    #expect(OnboardingStep.extensionStore.rawValue == "extensionStore", "the id kept in onboarding.json")
    #expect(OnboardingStep.signIn.rawValue == "signIn")
}

@Test func someoneWhoFinishedBeforeSeesOnlyTheNewSteps() {
    // Finished with every step mainline had before FUD-128, FUD-101's expansion and FUD-125.
    let before: [OnboardingStep] = [
        .welcome, .hotkey, .accessibility, .openAtLogin, .currency, .clipboardHistory, .updates, .done,
    ]
    var onboarding = Onboarding(answered: before.map(\.rawValue))
    #expect(onboarding.pending == [.extensionStore, .signIn, .snippetExpansion, .hyperkey, .done])
    #expect(onboarding.hasSomethingNew)
    onboarding.answer(.extensionStore)
    onboarding.answer(.signIn)
    onboarding.answer(.snippetExpansion)
    onboarding.answer(.hyperkey)
    #expect(onboarding.isComplete, "Done was clicked before")
}

@Test func everyFeatureThatsOffByDefaultHasAStep() {
    // Every stored property of FudgeSettings is either an opt-in, with the step that asks about it, or listed here as
    // not one, with why. A new property fails this test until it's one or the other (CLAUDE.md, Conventions).
    let notOptIns: [String: String] = [
        "hotkey": "the launcher's hotkey, which has its own step",
        "commands": "per-command aliases, hotkeys and Enabled",
        "extensions": "per-extension Enabled; the store's is set by its step",
        "numberFormat": "a format, not a feature",
        "extensionStoreConsentAt": "the store's consent date, written with it",
        "signInServerConsentAt": "the sign-in server's consent date, written with it",
        "clipboardHistoryConsentAt": "clipboard history's consent date, written with it",
        "clipboardHistoryKeepDays": "a detail of clipboard history",
        "clipboardHistoryIgnoredApps": "a detail of clipboard history",
        "resetAfter": "a choice that's on by default",
        "showOnScreen": "a choice, not a feature",
        "escapeBehavior": "a choice, not a feature",
        "hyperkeyQuickPress": "a detail of Hyperkey, which has its own step",
        "colorFormat": "the Color Picker's format, not a feature",
        "calendarHidden": "which calendars My Schedule shows; it asks for access when first run",
        "calendarDaysAhead": "a detail of My Schedule",
        "offByDefault": "worked out from the installed extensions at each load, never saved (SPEC-109)",
    ]
    let defaults = FudgeSettings()
    let properties = Mirror(reflecting: defaults).children.compactMap { child in child.label.map { ($0, child.value) } }
    #expect(properties.count == OnboardingStep.optIns.count + notOptIns.count, "nothing listed twice or missed")
    for (name, value) in properties {
        if let step = OnboardingStep.optIns[name] {
            #expect(notOptIns[name] == nil, "\(name) is listed as both")
            #expect(OnboardingStep.allCases.contains(step) && step != .done)
            // Off by default: false, or not set.
            let off = (value as? Bool) == false || "\(value)" == "nil"
            #expect(off, "\(name) is an opt-in, so it's off until the user turns it on")
        } else {
            #expect(notOptIns[name] != nil, "\(name): an off-by-default feature needs an onboarding step")
        }
    }
    #expect(
        Set(OnboardingStep.optIns.values) == [
            .currency, .extensionStore, .signIn, .clipboardHistory, .snippetExpansion, .hyperkey, .updates,
        ])
}

@Test func turningOnTheStoreInOnboardingWritesWhatTheSwitchWritesAndEnablesIt() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var switched = FudgeSettings()
    switched.setExtensionStore(true, now: now)
    var onboarded = FudgeSettings()
    onboarded.turnOnExtensionStore(now: now)
    #expect(onboarded.isExtensionStoreOn)
    #expect(onboarded.extensionStore == switched.extensionStore)
    #expect(onboarded.extensionStoreConsentAt == switched.extensionStoreConsentAt)
    #expect(onboarded.extensionStoreConsentAt == ISO8601DateFormatter().string(from: now))
    // The switch alone never enables it on the Commands page; onboarding's Turn On does, so it's in root search.
    #expect(!switched.isEnabled(extension: ExtensionStore.extensionName))
    #expect(onboarded.isEnabled(extension: ExtensionStore.extensionName))
    // Not Now writes nothing: the defaults stay off.
    #expect(!FudgeSettings().isExtensionStoreOn && !FudgeSettings().isEnabled(extension: ExtensionStore.extensionName))
}

@Test func theStepsShowTheirSettingsOwnWords() {
    // One string each, shared with the store's consent sheet and the Sign-in page.
    #expect(SignInServer.explanation == "Extensions sign in to services like GitHub and Linear through this server.")
    #expect(ExtensionStore.Consent.message.hasPrefix("This adds the Extension Store to Fudge."))
    #expect(ExtensionStore.Consent.note.contains(ExtensionStore.Consent.issueLinkText))
    #expect(FudgeSettings().signIn == .off, "Sign-in starts Off, which ↵ keeps")
}

@Test func snippetExpansionIsAskedAfterClipboardHistoryAndExistingUsersSeeJustIt() {
    let steps = OnboardingStep.allCases
    #expect(steps.firstIndex(of: .snippetExpansion) == steps.firstIndex(of: .clipboardHistory).map { $0 + 1 })
    #expect(OnboardingStep.snippetExpansion.rawValue == "snippetExpansion", "the id kept in onboarding.json")
    #expect(OnboardingStep.optIns["expandSnippets"] == .snippetExpansion)
    #expect(!FudgeSettings().expandSnippets, "Not Now writes nothing, so it stays off")
    let existing = Onboarding(answered: OnboardingStep.allCases.filter { $0 != .snippetExpansion }.map(\.rawValue))
    #expect(existing.pending == [.snippetExpansion, .done])
    #expect(existing.hasSomethingNew)
    // The step and the Snippets page's sheet say the same thing, from one string.
    #expect(SnippetExpander.permissionsExplanation.contains("Input Monitoring"))
    #expect(SnippetExpander.permissionsExplanation.contains("while macOS protects a password field"))
    // Pasting the snippet needs Accessibility, so the step says that too (SPEC-114 §5).
    #expect(SnippetExpander.permissionsExplanation.contains("Pasting the snippet in its place needs Accessibility."))
}

@Test func hyperkeyIsAskedAfterClipboardHistoryAndExistingUsersSeeJustIt() {
    let steps = OnboardingStep.allCases
    #expect(steps.firstIndex(of: .hyperkey) == steps.firstIndex(of: .snippetExpansion).map { $0 + 1 })
    #expect(OnboardingStep.hyperkey.rawValue == "hyperkey", "the id kept in onboarding.json")
    #expect(OnboardingStep.optIns["hyperkey"] == .hyperkey)
    #expect(!FudgeSettings().hyperkey, "Not Now writes nothing, so it stays off")
    let existing = Onboarding(answered: OnboardingStep.allCases.filter { $0 != .hyperkey }.map(\.rawValue))
    #expect(existing.pending == [.hyperkey, .done])
    #expect(existing.hasSomethingNew)
}

// MARK: - Done says where Fudge is (SPEC-114 §2)

@Test func doneSaysToPressTheHotkeyAndThatFudgeStaysInTheMenuBar() {
    #expect(
        OnboardingDone.line(hotkeyRegistered: true)
            == .press(before: "Press", after: "to open Fudge. It stays in the menu bar."))
    // A hotkey another app has does nothing, so Done never says to press it.
    guard case .hotkeyTaken(let text) = OnboardingDone.line(hotkeyRegistered: false) else {
        Issue.record("a taken hotkey isn't offered")
        return
    }
    #expect(text.contains("menu bar") && text.contains("Settings → General") && !text.hasPrefix("Press"))
}
