import Foundation
import Testing

@testable import FudgeCore

@Test(arguments: [
    (PanelResetSetting.immediately, 0),
    (.after30Seconds, 30),
    (.after1Minute, 60),
    (.after90Seconds, 90),
])
func resetIsDueFromItsLimitOn(setting: PanelResetSetting, seconds: Int) {
    #expect(PanelReset.isDue(hiddenFor: .seconds(seconds), setting: setting), "at the limit")
    #expect(PanelReset.isDue(hiddenFor: .seconds(seconds) + .milliseconds(1), setting: setting), "just over")
    if seconds > 0 {
        #expect(!PanelReset.isDue(hiddenFor: .seconds(seconds) - .milliseconds(1), setting: setting), "just under")
    }
}

@Test func neverIsNeverDue() {
    #expect(!PanelReset.isDue(hiddenFor: .seconds(86_400 * 365), setting: .never))
}

@Test func theSettingRoundTripsAndOnlyItsDefaultIsLeftOut() throws {
    let folder = try Fixtures.temporaryDirectory()
    let file = folder.appendingPathComponent("settings.json")
    try Data(#"{ "theme": "dark" }"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file).resetAfter == .after90Seconds, "a missing key is 90 seconds")

    let written: [PanelResetSetting: Any?] = [
        .immediately: 0, .after30Seconds: 30, .after1Minute: 60, .after90Seconds: nil, .never: "never",
    ]
    for setting in PanelResetSetting.allCases {
        var settings = FudgeSettings.load(from: file)
        settings.resetAfter = setting
        try settings.save(to: file)
        #expect(FudgeSettings.load(from: file).resetAfter == setting)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["theme"] as? String == "dark", "a key fudge doesn't know is kept")
        switch written[setting]! {
        case nil: #expect(object["resetAfterSeconds"] == nil, "\(setting) is the default, so it isn't written")
        case let value as Int: #expect(object["resetAfterSeconds"] as? Int == value)
        case let value as String: #expect(object["resetAfterSeconds"] as? String == value)
        default: Issue.record("unexpected value")
        }
    }
}

@Test(arguments: [#""soon""#, "45", "30.5", "-30", "false", "true", "null", "[30]", #""30""#])
func anyOtherValueReadsAsNinetySeconds(json: String) throws {
    let folder = try Fixtures.temporaryDirectory()
    let file = folder.appendingPathComponent("settings.json")
    try Data(#"{ "resetAfterSeconds": \#(json) }"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file).resetAfter == .after90Seconds)
}

/// A clock the tests move by hand.
private final class FakeClock {
    var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

@Test func onlyTimeSpentHiddenCountsAndADueResetHappensOnce() {
    let clock = FakeClock()
    let reset = PanelReset(setting: .after90Seconds, now: { clock.now })
    #expect(!reset.takeDue(), "never hidden yet")

    reset.panelHidden()
    clock.advance(.seconds(30))
    #expect(!reset.takeDue(), "a no-view command run 30 s in doesn't use the hide up")
    clock.advance(.seconds(61))
    #expect(reset.takeDue())
    #expect(!reset.takeDue(), "asking twice resets once")

    reset.panelHidden()
    clock.advance(.seconds(10))
    reset.panelShown()
    clock.advance(.seconds(3600))
    #expect(!reset.takeDue(), "a panel left open isn't reset under the user")
}

/// The launcher's state as far as a reset goes, with the paths that show the panel built as `LauncherModel`
/// builds them: each puts its screen together inside `PanelReset.enter`, and shows the panel after.
private final class FakePanel {
    enum Screen: Equatable {
        case root(query: String, fields: String?)
        case command(String)
    }

    var screen = Screen.root(query: "", fields: nil)
    var unloaded: [String] = []
    let reset: PanelReset

    init(reset: PanelReset) {
        self.reset = reset
    }

    private func resetToRoot(keeping session: String?) {
        if case .command(let name) = screen, name != session { unloaded.append(name) }
        screen = .root(query: "", fields: nil)
    }

    private func leaveCommand() {
        if case .command(let name) = screen { unloaded.append(name) }
    }

    func hide() { reset.panelHidden() }
    private func show() { reset.panelShown() }

    func toggle() {
        reset.enter(reset: { resetToRoot(keeping: nil) }, build: {})
        show()
    }

    func open(_ name: String) {
        leaveCommand()
        screen = .command(name)
        show()
    }

    func type(_ query: String) {
        screen = .root(query: query, fields: nil)
    }

    func commandHotkey(_ name: String) {
        reset.enter(
            reset: { resetToRoot(keeping: nil) },
            build: {
                leaveCommand()
                screen = .command(name)
            })
        show()
    }

    func requiredArgumentHotkey(_ name: String) {
        reset.enter(
            reset: { resetToRoot(keeping: nil) },
            build: {
                leaveCommand()
                screen = .root(query: "", fields: name)
            })
        show()
    }

    /// A user-initiated view launch from the command on screen: the caller is answered, then unloaded.
    func launchCommand(_ name: String) {
        let caller: String? = if case .command(let name) = screen { name } else { nil }
        reset.enter(reset: { resetToRoot(keeping: caller) }, build: { screen = .command(name) })
        if let caller { unloaded.append(caller) }
        show()
    }
}

private func panel(_ setting: PanelResetSetting = .after90Seconds) -> (FakePanel, FakeClock) {
    let clock = FakeClock()
    return (FakePanel(reset: PanelReset(setting: setting, now: { clock.now })), clock)
}

@Test func afterALongHideTheToggleOpensAnEmptyRootSearch() {
    let (panel, clock) = panel()
    panel.open("weather")
    panel.hide()
    clock.advance(.seconds(91))
    panel.toggle()
    #expect(panel.screen == .root(query: "", fields: nil))
    #expect(panel.unloaded == ["weather"])
}

@Test func afterAShortHideTheToggleKeepsTheCommand() {
    let (panel, clock) = panel()
    panel.open("weather")
    panel.hide()
    clock.advance(.seconds(30))
    panel.toggle()
    #expect(panel.screen == .command("weather"))
    #expect(panel.unloaded.isEmpty)
}

@Test func afterALongHideACommandHotkeyShowsItsCommand() {
    let (panel, clock) = panel()
    panel.open("weather")
    panel.hide()
    clock.advance(.seconds(91))
    panel.commandHotkey("scratch")
    #expect(panel.screen == .command("scratch"), "the target isn't thrown away by the reset")
    #expect(panel.unloaded == ["weather"])
}

@Test func afterALongHideARequiredArgumentHotkeyShowsItsFields() {
    let (panel, clock) = panel()
    panel.type("calc")
    panel.hide()
    clock.advance(.seconds(91))
    panel.requiredArgumentHotkey("translate")
    #expect(panel.screen == .root(query: "", fields: "translate"))
}

@Test func afterALongHideLaunchCommandShowsItsTargetAndUnloadsTheCallerAfterAnswering() {
    let (panel, clock) = panel()
    panel.open("timer")
    panel.hide()
    clock.advance(.seconds(91))
    panel.launchCommand("stopwatch")
    #expect(panel.screen == .command("stopwatch"))
    #expect(panel.unloaded == ["timer"], "once, by the launch itself, not by the reset")
}

@Test func withNeverADayHiddenChangesNothing() {
    let (panel, clock) = panel(.never)
    panel.open("weather")
    panel.hide()
    clock.advance(.seconds(86_400))
    panel.toggle()
    #expect(panel.screen == .command("weather"))
    #expect(panel.unloaded.isEmpty)
}
