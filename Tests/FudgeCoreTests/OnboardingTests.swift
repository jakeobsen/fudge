import Foundation
import Testing

@testable import FudgeCore

@Test func nothingAnsweredShowsEveryStep() {
    let onboarding = Onboarding()
    #expect(onboarding.pending == [.welcome, .hotkey, .accessibility, .openAtLogin, .currency, .updates, .done])
    #expect(onboarding.pending == OnboardingStep.allCases, "the cases are the one step list")
    #expect(!onboarding.isComplete)
    #expect(!onboarding.hasSomethingNew)
}

@Test func someAnsweredShowsTheRestThenDone() {
    var onboarding = Onboarding()
    onboarding.answer(.welcome)
    onboarding.answer(.hotkey)
    #expect(
        onboarding.pending == [.accessibility, .openAtLogin, .currency, .updates, .done], "Welcome isn't shown again")
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
    #expect(onboarding.pending == [.openAtLogin, .currency, .updates, .done])
}

@Test func aNewStepShowsOnlyThatStepAndDone() {
    // A user who completed onboarding before the Currency and Updates steps existed.
    let onboarding = Onboarding(answered: ["welcome", "hotkey", "accessibility", "openAtLogin", "done"])
    #expect(onboarding.pending == [.currency, .updates, .done])
    #expect(onboarding.hasSomethingNew)
    #expect(!onboarding.isComplete)
    // Welcome never comes back once completed, even if its id is missing.
    let noWelcome = Onboarding(answered: ["hotkey", "accessibility", "openAtLogin", "currency", "done"])
    #expect(noWelcome.pending == [.updates, .done])
    let complete = Onboarding(answered: OnboardingStep.allCases.map(\.rawValue) + ["retiredStep"])
    #expect(complete.isComplete, "ids that aren't a step any more don't count")
}

@Test func theUpdatesStepComesAfterCurrencyAndShowsAloneToThoseWhoFinished() {
    let steps = OnboardingStep.allCases
    #expect(steps.firstIndex(of: .updates) == steps.firstIndex(of: .currency).map { $0 + 1 })
    #expect(OnboardingStep.updates.rawValue == "updates", "the id kept in onboarding.json")
    // A user who completed onboarding before the Updates step existed sees just it, under "Something new to decide".
    var onboarding = Onboarding(answered: ["welcome", "hotkey", "accessibility", "openAtLogin", "currency", "done"])
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
