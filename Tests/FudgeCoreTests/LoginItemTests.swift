import Foundation
import Testing

@testable import FudgeCore

/// A login item that records calls and never touches the system.
@MainActor
private final class FakeLoginItem: LoginItem {
    var status: LoginItemStatus
    var failure: Error?
    /// What `register()` leaves the status at: macOS may want the user's approval first.
    var afterRegister: LoginItemStatus = .enabled
    private(set) var calls: [String] = []

    init(_ status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = afterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }

    func openSystemSettings() {
        calls.append("openSystemSettings")
    }
}

private struct Refused: LocalizedError {
    var errorDescription: String? { "The operation couldn't be completed." }
}

@Test func theSwitchFollowsTheSystemsStatus() {
    #expect(LoginItemState(.enabled) == LoginItemState(isOn: true, note: nil, offersLoginItemsSettings: false))
    #expect(LoginItemState(.notRegistered) == LoginItemState(isOn: false, note: nil, offersLoginItemsSettings: false))
    #expect(LoginItemState(.notFound) == LoginItemState(isOn: false, note: nil, offersLoginItemsSettings: false))
    let approval = LoginItemState(.requiresApproval)
    #expect(approval.isOn, "on, waiting for the user's approval")
    #expect(approval.note == "Allow Fudge in System Settings → General → Login Items")
    #expect(approval.offersLoginItemsSettings)
}

@MainActor
@Test func turningItOnRegistersAndOffUnregisters() {
    let item = FakeLoginItem(.notRegistered)
    let on = LoginItemState.change(item, to: true)
    #expect(on.state.isOn)
    #expect(on.error == nil)
    let off = LoginItemState.change(item, to: false)
    #expect(!off.state.isOn)
    #expect(off.error == nil)
    #expect(item.calls == ["register", "unregister"])
}

@MainActor
@Test func aRegistrationAwaitingApprovalShowsTheNoteAndButton() {
    let item = FakeLoginItem(.notRegistered)
    item.afterRegister = .requiresApproval
    let result = LoginItemState.change(item, to: true)
    #expect(result.state == LoginItemState(.requiresApproval))
    #expect(result.error == nil)
}

@MainActor
@Test func aFailureShowsItsMessageAndTheRealStateAgain() {
    let item = FakeLoginItem(.notRegistered)
    item.failure = Refused()
    let on = LoginItemState.change(item, to: true)
    #expect(!on.state.isOn, "the switch goes back to the real state")
    #expect(on.error == "The operation couldn't be completed.")

    let enabled = FakeLoginItem(.enabled)
    enabled.failure = Refused()
    let off = LoginItemState.change(enabled, to: false)
    #expect(off.state.isOn)
    #expect(off.error != nil)
}

@Test func everyStatusHasARawValueForSnapshots() {
    #expect(LoginItemStatus.allCases.map(\.rawValue) == ["notRegistered", "enabled", "requiresApproval", "notFound"])
    #expect(LoginItemStatus(rawValue: "requiresApproval") == .requiresApproval)
}

// MARK: - Clear Search History

@Test func clearingTheHistoryForgetsEveryLaunchAndRanksByMatchAgain() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("history.json")
    var history = LaunchHistory()
    history.record("app:/Applications/Notes.app")
    history.record("app:/Applications/Notes.app")
    history.record("command:greeter/greet")
    try history.save(to: file)

    history.clear()
    #expect(history.entries.isEmpty)
    #expect(history.score("app:/Applications/Notes.app") == 0)
    try history.save(to: file)
    #expect(LaunchHistory.load(from: file) == LaunchHistory(), "history.json is empty too")
}

// MARK: - Where the app runs from (SPEC-114 §1)

@Test func theDiskImageAndATranslocatedCopyAreOfferedTheMove() {
    let image = AppLocation(bundlePath: "/Volumes/Fudge/Fudge.app", isOnReadOnlyVolume: true)
    #expect(image == .diskImage && image.offersMove)
    let translocated = AppLocation(
        bundlePath:
            "/private/var/folders/xy/abc123/T/AppTranslocation/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/d/Fudge.app",
        isOnReadOnlyVolume: true)
    #expect(translocated == .translocated && translocated.offersMove)
    // A translocated copy counts as one even if the volume flag were missed.
    #expect(
        AppLocation(bundlePath: "/private/var/folders/x/T/AppTranslocation/U/d/Fudge.app", isOnReadOnlyVolume: false)
            == .translocated)
    for (path, readOnly) in [
        ("/Applications/Fudge.app", false), ("/Users/someone/Applications/Fudge.app", false),
        ("/Users/someone/Downloads/Fudge.app", false), ("/Users/someone/fudge/build/Fudge.app", false),
        // Only the folder named exactly so counts.
        ("/Users/someone/AppTranslocationNotes/Fudge.app", false),
    ] {
        let location = AppLocation(bundlePath: path, isOnReadOnlyVolume: readOnly)
        #expect(location == .installed && !location.offersMove && location.moveMessage == nil, "\(path)")
    }
    #expect(image.moveMessage?.contains("disk image") == true)
    #expect(translocated.moveMessage?.contains("temporary copy") == true)
    #expect(AppLocation.moveTitle == "Move Fudge to Applications?")
}

@Test func theMovePutsTheAppInApplicationsOrTheUsersOwnNeverAskingForAPassword() {
    let bundle = URL(fileURLWithPath: "/Volumes/Fudge/Fudge.app", isDirectory: true)
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let admin = AppLocation.destination(for: bundle, applicationsWritable: true, home: home)
    #expect(admin.path == "/Applications/Fudge.app")
    #expect(AppLocation.diskImage.moveMessage(destination: admin) == AppLocation.diskImage.moveMessage)
    // A standard account can't add apps to /Applications: the app goes to its own Applications folder, and says so.
    let standard = AppLocation.destination(for: bundle, applicationsWritable: false, home: home)
    #expect(standard.path == "/Users/someone/Applications/Fudge.app")
    let message = AppLocation.diskImage.moveMessage(destination: standard)
    #expect(message?.hasSuffix("so it goes to Applications in your home folder.") == true)
    #expect(AppLocation.installed.moveMessage(destination: standard) == nil)
}

@Test func aCopyStillTranslocatedAfterTheMoveSaysSoOnceInsteadOfOfferingAgain() {
    // The spec review's MUST: a moved copy that macOS translocates again would get the offer at every launch.
    #expect(AppLocation.translocated.launchStep(arguments: ["Fudge"]) == .offer)
    #expect(AppLocation.diskImage.launchStep(arguments: ["Fudge"]) == .offer)
    #expect(AppLocation.translocated.launchStep(arguments: ["Fudge", AppLocation.movedArgument]) == .stillNotMoved)
    #expect(AppLocation.installed.launchStep(arguments: ["Fudge", AppLocation.movedArgument]) == .nothing)
    #expect(AppLocation.installed.launchStep(arguments: ["Fudge"]) == .nothing)
    #expect(AppLocation.movedArgument == "--moved-to-applications")
}

@Test func raycastsLinksAreRefusedFromTheDiskImageOrATranslocatedCopy() {
    for location in [AppLocation.diskImage, .translocated] {
        #expect(location.raycastLinksRefusal == "Move Fudge to Applications first, so it can open Raycast links.")
    }
    #expect(AppLocation.installed.raycastLinksRefusal == nil)
}

@MainActor
@Test func openAtLoginIsNeverSetFromTheDiskImageOrATranslocatedCopy() {
    for location in [AppLocation.diskImage, .translocated] {
        let item = FakeLoginItem(.notRegistered)
        let result = LoginItemState.change(item, to: true, location: location)
        #expect(item.calls.isEmpty, "nothing registered from \(location)")
        #expect(!result.state.isOn)
        #expect(result.error == "Move Fudge to Applications first, so it can open at login.")
        // Turning it off still works from anywhere.
        let enabled = FakeLoginItem(.enabled)
        let off = LoginItemState.change(enabled, to: false, location: location)
        #expect(enabled.calls == ["unregister"] && !off.state.isOn && off.error == nil)
    }
    let installed = FakeLoginItem(.notRegistered)
    #expect(LoginItemState.change(installed, to: true, location: .installed).state.isOn)
    #expect(installed.calls == ["register"])
}
