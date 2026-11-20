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
    #expect(approval.note == "Allow fudge in System Settings → General → Login Items")
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
