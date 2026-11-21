import Foundation
import Testing

@testable import FudgeCore

/// Runs a mutating call outside `#expect`, which can't hold one.
private func step<T>(_ body: () -> T) -> T { body() }

@Test func onlyAUserInitiatedCallMayBringFudgeForward() {
    #expect(CallOrigin.userInitiated.mayComeForward)
    #expect(!CallOrigin.background.mayComeForward)
    #expect(CallOrigin.launched(userInitiated: true) == .userInitiated)
    #expect(CallOrigin.launched(userInitiated: false) == .background)
}

@Test func aBackgroundConfirmAlertResolvesFalseWithoutAsking() {
    #expect(CallOrigin.background.unaskedAnswer == false, "as if the user had picked the dismiss button")
    #expect(CallOrigin.userInitiated.unaskedAnswer == nil, "the user is asked")
}

@Test func aMenuBarSessionIsUserInitiatedWhileItsMenuIsOpenOrAPickIsRunning() {
    var lifecycle = MenuBarLifecycle()
    #expect(lifecycle.origin(of: "s1") == .background, "nothing loaded")

    // An interval refresh: background.
    lifecycle.launched("s1", userInitiated: false)
    #expect(lifecycle.origin(of: "s1") == .background)
    _ = lifecycle.rendered("s1", isLoading: true)
    lifecycle.menuOpened()
    #expect(lifecycle.origin(of: "s1") == .userInitiated, "the user opened its menu")
    lifecycle.eventSent("s1")
    lifecycle.menuClosed()
    #expect(lifecycle.origin(of: "s1") == .userInitiated, "the user's pick is still running after the menu closed")
    lifecycle.eventSettled("s1")
    #expect(lifecycle.origin(of: "s1") == .background, "settled: back to how it was launched")
    #expect(lifecycle.origin(of: "s0") == .background, "another session isn't this instance")

    // A click or root search: user-initiated throughout, unloading included.
    var clicked = MenuBarLifecycle()
    clicked.launched("s2", userInitiated: true)
    #expect(clicked.origin(of: "s2") == .userInitiated)
    _ = clicked.rendered("s2", isLoading: false)
    #expect(step { clicked.takeUnload() } == "s2")
    #expect(clicked.origin(of: "s2") == .userInitiated)
    _ = clicked.exited("s2")
    #expect(clicked.origin(of: "s2") == .background, "gone")
}

@Test func aBackgroundLaunchPermissionQuestionIsRefusedAndNotSaved() throws {
    #expect(LaunchPermissions.step(answer: true, origin: .background) == .allowed, "an answer given before stands")
    #expect(LaunchPermissions.step(answer: false, origin: .background) == .refused)
    #expect(LaunchPermissions.step(answer: nil, origin: .background) == .refusedUnasked)
    #expect(LaunchPermissions.step(answer: nil, origin: .userInitiated) == .ask)
    #expect(LaunchPermissions.step(answer: true, origin: .userInitiated) == .allowed)
    #expect(
        LaunchPermissions.unaskedNotice(callerTitle: "Weather", targetTitle: "Calendar")
            == "Weather wants to open Calendar. Open Weather from Fudge to allow it.")
    #expect(
        LaunchCommandError.permissionNeeded(extensionTitle: "Calendar").description
            == #"Not allowed to launch commands of "Calendar" yet: Fudge asks the user when they open this command"#)
}

@Test func aBackgroundNoticeShowsOncePerKeyPerRun() {
    var notices = OncePerRun()
    #expect(step { notices.first("launch:weather/calendar") })
    #expect(!step { notices.first("launch:weather/calendar") }, "a 30 s refresh doesn't repeat it")
    #expect(step { notices.first("launch:weather/mail") }, "another pair gets its own")
}

@Test func aBackgroundInstancesOwnCallWhileItsMenuIsOpenIsUserInitiated() {
    // A decision, not an accident (#2971): an interval refresh that raises a confirm by itself, with no pick, while
    // the user happens to have its menu open, may ask, because the user is in Fudge's menu at that moment.
    var lifecycle = MenuBarLifecycle()
    lifecycle.launched("s1", userInitiated: false)
    lifecycle.menuOpened()
    #expect(lifecycle.runningEvents == 0, "no pick is running")
    #expect(lifecycle.origin(of: "s1") == .userInitiated)
    lifecycle.menuClosed()
    #expect(lifecycle.origin(of: "s1") == .background, "with the menu closed, the same call can't ask")
}
