import Foundation
import Testing

@testable import FudgeCore

// Fakes only: these tests never ask macOS about Accessibility, show an alert, open System Settings, post key events
// or touch the pasteboard.

@MainActor
private final class FakeAccess: AccessibilityAccess {
    var trusted = false
    var prompts: [Bool] = []

    func isTrusted(prompt: Bool) -> Bool {
        prompts.append(prompt)
        return trusted
    }

    func selectedText(pid: Int32) async -> String? { nil }
}

@MainActor
private final class FakeKeys: CopyKeyPoster, PasteKeyPoster {
    var posted = 0
    func postCopy(to pid: Int32) { posted += 1 }
    func postPaste(to pid: Int32) { posted += 1 }
}

@MainActor
private final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    var current = PasteboardContents(items: [])

    func contents() -> PasteboardContents { current }

    func replace(with contents: PasteboardContents) {
        current = contents
        changeCount += 1
    }

    func plainText() -> String? { nil }
}

private let me: Int32 = 100
private let textEdit = FrontmostApplication(pid: 200, bundleIdentifier: "com.apple.TextEdit")

@Test @MainActor func theFirstRefusalPromptsTheSecondOffersTheThirdDoesNeither() {
    let access = FakeAccess()
    let gate = AccessibilityGate(access: access)

    #expect(gate.check(origin: .userInitiated) == .refused(offerSettings: false))
    #expect(access.prompts == [true], "the first refusal asks for macOS's prompt")
    #expect(gate.check(origin: .userInitiated) == .refused(offerSettings: true))
    #expect(access.prompts == [true, false], "the second doesn't prompt again; it offers the pane")
    #expect(gate.check(origin: .userInitiated) == .refused(offerSettings: false))
    #expect(gate.check(origin: .userInitiated) == .refused(offerSettings: false))
    #expect(access.prompts == [true, false, false, false])
}

@Test @MainActor func aGrantBetweenRefusalsIsTrustedWithNoOffer() {
    let access = FakeAccess()
    let gate = AccessibilityGate(access: access)

    #expect(gate.check(origin: .userInitiated) == .refused(offerSettings: false))
    access.trusted = true
    #expect(gate.check(origin: .userInitiated) == .trusted)
    #expect(gate.check(origin: .userInitiated) == .trusted)
    #expect(access.prompts == [true, false, false])
}

@Test @MainActor func trustedFromTheStartNeverOffers() {
    let access = FakeAccess()
    access.trusted = true
    var offers = 0
    let gate = AccessibilityGate(access: access, offerSettings: { _ in offers += 1 })

    #expect(gate.isTrusted(origin: .userInitiated))
    #expect(gate.isTrusted(origin: .userInitiated))
    #expect(offers == 0)
}

@Test @MainActor func isTrustedTellsTheAppOnlyWhenItsTimeToOffer() {
    let access = FakeAccess()
    var offers = 0
    let gate = AccessibilityGate(access: access, offerSettings: { _ in offers += 1 })

    #expect(!gate.isTrusted(origin: .userInitiated))
    #expect(offers == 0)
    #expect(!gate.isTrusted(origin: .userInitiated))
    #expect(offers == 1)
    #expect(!gate.isTrusted(origin: .userInitiated))
    #expect(!gate.isTrusted(origin: .userInitiated))
    #expect(offers == 1, "once per run")
}

@Test @MainActor func oneGateSharedByTheSelectionAndPasteOffersOnceAcrossBoth() async {
    let access = FakeAccess()
    var offers = 0
    let gate = AccessibilityGate(access: access, offerSettings: { _ in offers += 1 })
    let keys = FakeKeys()
    let pasteboard = FakePasteboard()
    let turns = PasteboardTurns()
    let selection = SelectedText(
        accessibility: access, keys: keys, pasteboard: pasteboard, ownPid: me, turns: turns, gate: gate)
    let paste = Paste(gate: gate, keys: keys, pasteboard: pasteboard, ownPid: me, turns: turns)
    func pasteText() async throws {
        try await paste.paste(
            PasteboardContents.forPaste(text: "hi", html: nil, file: nil), closeMainWindow: true,
            origin: .userInitiated, hideWindow: {},
            frontmost: { textEdit })
    }

    // A refused Selection Check, then a refused Paste: the Paste shows the offer.
    await #expect(throws: SelectionError.accessibilityNeeded) {
        try await selection.read(from: textEdit, origin: .userInitiated)
    }
    #expect(offers == 0)
    await #expect(throws: PasteError.accessibilityNeeded) { try await pasteText() }
    #expect(offers == 1)
    await #expect(throws: SelectionError.accessibilityNeeded) {
        try await selection.read(from: textEdit, origin: .userInitiated)
    }
    await #expect(throws: PasteError.accessibilityNeeded) { try await pasteText() }
    #expect(offers == 1, "once per run, across both")
    #expect(access.prompts == [true, false, false, false], "macOS's prompt only for the first")
    #expect(keys.posted == 0)
}

@Test @MainActor func aBackgroundRefusalNeitherPromptsNorOffersAndLeavesBothForTheUser() async {
    let access = FakeAccess()
    var offers: [CallOrigin] = []
    let gate = AccessibilityGate(access: access, offerSettings: { offers.append($0) })

    // An interval refresh reads the selection: refused, with no macOS prompt and no offer, however often.
    #expect(gate.check(origin: .background) == .refused(offerSettings: false))
    #expect(!gate.isTrusted(origin: .background))
    #expect(!gate.isTrusted(origin: .background))
    #expect(access.prompts == [false, false, false], "a background call never asks for macOS's prompt")
    #expect(offers.isEmpty)

    // The user's own calls still get the prompt first, then the offer, as if nothing had happened before.
    #expect(!gate.isTrusted(origin: .userInitiated))
    #expect(access.prompts.last == true, "the first user-initiated refusal prompts")
    #expect(!gate.isTrusted(origin: .userInitiated))
    #expect(offers == [.userInitiated], "and the next offers the pane, passing its origin on")
    #expect(!gate.isTrusted(origin: .background))
    #expect(offers == [.userInitiated])

    // A background paste is refused the same way, and posts nothing.
    let keys = FakeKeys()
    let paste = Paste(
        gate: AccessibilityGate(access: access), keys: keys, pasteboard: FakePasteboard(), ownPid: me,
        turns: PasteboardTurns())
    await #expect(throws: PasteError.accessibilityNeeded) {
        try await paste.paste(
            PasteboardContents.forPaste(text: "hi", html: nil, file: nil), closeMainWindow: false, origin: .background,
            hideWindow: {}, frontmost: { textEdit })
    }
    #expect(keys.posted == 0)
}

@Test @MainActor func aBackgroundCallIsTrustedWhenAccessibilityIsAllowed() {
    let access = FakeAccess()
    access.trusted = true
    let gate = AccessibilityGate(access: access)
    #expect(gate.check(origin: .background) == .trusted)
    #expect(access.prompts == [false])
}

@Test func theAlertSaysWhatToDoAndOpensTheAccessibilityPane() {
    #expect(AccessibilitySettingsAlert.title == "Allow Fudge to use Accessibility")
    #expect(
        AccessibilitySettingsAlert.text
            == "Fudge needs Accessibility permission to read the selected text, to paste and to move windows. Turn Fudge "
            + "on in System "
            + "Settings → Privacy & Security → Accessibility. If Fudge is already in the list, select it, remove it "
            + "with −, and add it again with +. An older build of Fudge can leave an entry that no longer matches.")
    #expect(AccessibilitySettingsAlert.openButton == "Open Accessibility Settings")
    #expect(AccessibilitySettingsAlert.dismissButton == "Not Now")
    #expect(
        AccessibilitySettingsAlert.paneURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
