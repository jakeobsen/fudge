import Foundation
import Testing

@testable import FudgeCore

struct HeldKeyTests {
    let pressed = ContinuousClock.now
    let commandO = KeyShortcut(key: "o", modifiers: ["cmd"])

    /// The screen the key was pressed on: command `s1`, its first view, item 7 selected.
    func screen(
        panelShown: Bool = true, session: String? = "s1", depth: Int = 1, selected: Int? = 7, actionsCame: Bool
    ) -> HeldKey.Screen {
        HeldKey.Screen(
            panelShown: panelShown, session: session, depth: depth, selected: selected, actionsCame: actionsCame)
    }

    func held(_ key: HeldKey.Key, after delay: Duration = .zero) -> HeldKey {
        HeldKey(key, session: "s1", depth: 1, node: 7, pressedAt: pressed + delay)
    }

    @Test func theKeyRunsWhenTheActionsComeWithinTwoSeconds() {
        let key = held(.primary)
        // Still waiting until they come.
        #expect(key.outcome(at: pressed, on: screen(actionsCame: false)) == .wait)
        #expect(key.outcome(at: pressed + .milliseconds(1999), on: screen(actionsCame: false)) == .wait)
        // They come just inside the time.
        #expect(key.outcome(at: pressed + .milliseconds(1999), on: screen(actionsCame: true)) == .run(.primary))
        let shortcut = held(.shortcut(commandO))
        #expect(
            shortcut.outcome(at: pressed + .milliseconds(10), on: screen(actionsCame: true))
                == .run(.shortcut(commandO)))
    }

    @Test func theKeyIsDroppedWithTheToastAfterTwoSeconds() {
        let key = held(.actionPanel)
        #expect(key.deadline == pressed + .seconds(2))
        #expect(HeldKey.timeout == .seconds(2))
        #expect(key.outcome(at: pressed + .seconds(2), on: screen(actionsCame: false)) == .timedOut)
        // Actions that come once the time is up are too late: the key is never run late.
        #expect(key.outcome(at: pressed + .seconds(2), on: screen(actionsCame: true)) == .timedOut)
        #expect(key.outcome(at: pressed + .seconds(30), on: screen(actionsCame: true)) == .timedOut)
        #expect(HeldKey.timeoutMessage == "This command didn't send its actions in time.")
    }

    /// SPEC-065 MUST 1: a key is held, the panel hides, and neither the key nor the toast comes, whether the actions
    /// come while it's hidden or the time runs out.
    @Test func aHiddenPanelGetsNeitherTheKeyNorTheToast() {
        let key = held(.primary)
        let hidden = { (actionsCame: Bool) in self.screen(panelShown: false, actionsCame: actionsCame) }
        #expect(key.outcome(at: pressed + .milliseconds(500), on: hidden(true)) == .drop)
        #expect(key.outcome(at: pressed + .milliseconds(500), on: hidden(false)) == .drop)
        #expect(key.outcome(at: pressed + .seconds(2), on: hidden(false)) == .drop)
        #expect(key.outcome(at: pressed + .seconds(2), on: hidden(true)) == .drop)
        #expect(!key.applies(to: hidden(true)))
    }

    /// MUST 1 too: leaving the view or the command (a push, a pop, another launch, root search) drops it silently.
    @Test func leavingTheViewOrCommandDropsItSilently() {
        let key = held(.secondary)
        let soon = pressed + .milliseconds(100)
        let late = pressed + .seconds(3)
        for moved in [
            screen(depth: 2, actionsCame: true),  // a push
            screen(depth: 0, actionsCame: true),  // a pop below the view it was pressed in
            screen(session: "s2", actionsCame: true),  // another command
            screen(session: nil, depth: 0, selected: nil, actionsCame: false),  // root search
            screen(selected: 8, actionsCame: true),  // the selection moved
            screen(selected: nil, actionsCame: false),  // nothing selected
        ] {
            #expect(key.outcome(at: soon, on: moved) == .drop)
            // And after the time is up: no toast for a key that no longer applies.
            #expect(key.outcome(at: late, on: moved) == .drop)
        }
    }

    @Test func aSecondPressStartsTheTimeOver() {
        let first = held(.primary)
        let second = held(.actionPanel, after: .milliseconds(1500))
        let later = pressed + .milliseconds(2500)
        #expect(first.outcome(at: later, on: screen(actionsCame: false)) == .timedOut)
        #expect(second.outcome(at: later, on: screen(actionsCame: false)) == .wait)
        #expect(second.outcome(at: later, on: screen(actionsCame: true)) == .run(.actionPanel))
        #expect(second.deadline == pressed + .milliseconds(3500))
    }
}
