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

    #expect(gate.check() == .refused(offerSettings: false))
    #expect(access.prompts == [true], "the first refusal asks for macOS's prompt")
    #expect(gate.check() == .refused(offerSettings: true))
    #expect(access.prompts == [true, false], "the second doesn't prompt again; it offers the pane")
    #expect(gate.check() == .refused(offerSettings: false))
    #expect(gate.check() == .refused(offerSettings: false))
    #expect(access.prompts == [true, false, false, false])
}

@Test @MainActor func aGrantBetweenRefusalsIsTrustedWithNoOffer() {
    let access = FakeAccess()
    let gate = AccessibilityGate(access: access)

    #expect(gate.check() == .refused(offerSettings: false))
    access.trusted = true
    #expect(gate.check() == .trusted)
    #expect(gate.check() == .trusted)
    #expect(access.prompts == [true, false, false])
}

@Test @MainActor func trustedFromTheStartNeverOffers() {
    let access = FakeAccess()
    access.trusted = true
    var offers = 0
    let gate = AccessibilityGate(access: access, offerSettings: { offers += 1 })

    #expect(gate.isTrusted())
    #expect(gate.isTrusted())
    #expect(offers == 0)
}

@Test @MainActor func isTrustedTellsTheAppOnlyWhenItsTimeToOffer() {
    let access = FakeAccess()
    var offers = 0
    let gate = AccessibilityGate(access: access, offerSettings: { offers += 1 })

    #expect(!gate.isTrusted())
    #expect(offers == 0)
    #expect(!gate.isTrusted())
    #expect(offers == 1)
    #expect(!gate.isTrusted())
    #expect(!gate.isTrusted())
    #expect(offers == 1, "once per run")
}

@Test @MainActor func oneGateSharedByTheSelectionAndPasteOffersOnceAcrossBoth() async {
    let access = FakeAccess()
    var offers = 0
    let gate = AccessibilityGate(access: access, offerSettings: { offers += 1 })
    let keys = FakeKeys()
    let pasteboard = FakePasteboard()
    let selection = SelectedText(accessibility: access, keys: keys, pasteboard: pasteboard, ownPid: me, gate: gate)
    let paste = Paste(gate: gate, keys: keys, pasteboard: pasteboard, ownPid: me)
    func pasteText() async throws {
        try await paste.paste(
            PasteboardContents.forPaste(text: "hi", html: nil, file: nil), closeMainWindow: true, hideWindow: {},
            frontmost: { textEdit })
    }

    // A refused Selection Check, then a refused Paste: the Paste shows the offer.
    await #expect(throws: SelectionError.accessibilityNeeded) { try await selection.read(from: textEdit) }
    #expect(offers == 0)
    await #expect(throws: PasteError.accessibilityNeeded) { try await pasteText() }
    #expect(offers == 1)
    await #expect(throws: SelectionError.accessibilityNeeded) { try await selection.read(from: textEdit) }
    await #expect(throws: PasteError.accessibilityNeeded) { try await pasteText() }
    #expect(offers == 1, "once per run, across both")
    #expect(access.prompts == [true, false, false, false], "macOS's prompt only for the first")
    #expect(keys.posted == 0)
}

@Test func theAlertSaysWhatToDoAndOpensTheAccessibilityPane() {
    #expect(AccessibilitySettingsAlert.title == "Allow Fudge to use Accessibility")
    #expect(
        AccessibilitySettingsAlert.text
            == "Fudge needs Accessibility permission to read the selected text and to paste. Turn Fudge on in System "
            + "Settings → Privacy & Security → Accessibility. If Fudge is already in the list, select it, remove it "
            + "with −, and add it again with +. An older build of Fudge can leave an entry that no longer matches.")
    #expect(AccessibilitySettingsAlert.openButton == "Open Accessibility Settings")
    #expect(AccessibilitySettingsAlert.dismissButton == "Not Now")
    #expect(
        AccessibilitySettingsAlert.paneURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
