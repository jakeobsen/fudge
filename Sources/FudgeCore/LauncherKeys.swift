import Foundation

/// Which of the view's actions a key press in the launcher runs (SPEC-127). `LauncherModel.handleKey` asks it for
/// every key, and a command hotkey pressed while the launcher holds the keyboard asks it too (`hotkeyPress`), so an
/// action's shortcut beats a command's hotkey with the same keys exactly when the key would have run that action.
///
/// Before it, `handleKey` gives the sign-in prompt, an open calendar, ⌘K, an `Action.PickDate` picker, ⌘P on an open
/// dropdown and root search's argument fields their keys. None of those takes a key with ⌘, ⌥ or ⌃, nor an F-key, so
/// none takes a key a command hotkey can have, except ⌘K, which isn't an action's (`actionPanelKey`).
public enum LauncherKeys {
    /// ⌘K opens and closes the action panel: Fudge's own key, never an action's.
    public static let actionPanelKey = KeyShortcut(key: "k", modifiers: ["cmd"])

    /// ↵ runs the primary action, except in a Form, where ↵ belongs to the fields and ⌘↵ submits.
    public static func primaryKey(form: Bool) -> KeyShortcut {
        KeyShortcut(key: "return", modifiers: form ? ["cmd"] : [])
    }

    /// ⌘↵ runs the secondary action; ⌘⇧↵ in a Form.
    public static func secondaryKey(form: Bool) -> KeyShortcut {
        KeyShortcut(key: "return", modifiers: form ? ["cmd", "shift"] : ["cmd"])
    }

    /// What the launcher shows, as far as its keys go.
    public struct State: Sendable, Equatable {
        public enum Place: Sendable, Equatable {
            /// Root search, with Fudge's own actions for the selected item (`RootActions`).
            case root
            /// A notice in a command's place, with the notice's actions.
            case failure
            /// A running command's view. A Detail or a Form has no search field; a Form's primary and secondary keys
            /// are ⌘↵ and ⌘⇧↵.
            case command(hasSearchField: Bool, isForm: Bool)
            /// A running command whose view failed: only Fudge's own keys.
            case failedCommand
        }

        /// What's over the view.
        public enum Overlay: Sendable, Equatable {
            /// The action panel's list (⌘K), with "Search for actions…".
            case actionPanel
            /// An `Action.PickDate`'s picker in the action panel, which takes every key.
            case datePick
            /// A dropdown's panel.
            case dropdown
            /// The "Sign in to …" prompt, which takes every key.
            case signIn
        }

        public var place: Place
        public var overlay: Overlay?
        /// The view's actions (`LauncherModel.currentActions`).
        public var actions: [ActionSection]
        /// While the selected item's actions haven't come, the shortcuts the host named for them
        /// (`ListContent.Item.deferredShortcuts`); nil once they're here, or with no such item.
        public var pendingShortcuts: [KeyShortcut]?

        public init(
            place: Place, overlay: Overlay? = nil, actions: [ActionSection], pendingShortcuts: [KeyShortcut]? = nil
        ) {
            self.place = place
            self.overlay = overlay
            self.actions = actions
            self.pendingShortcuts = pendingShortcuts
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Runs this action, or opens its submenu or picker (`LauncherModel.run`).
        case run(ActionEntry)
        /// Waits for the selected item's actions, which the key belongs to (`HeldKey`).
        case wait(HeldKey.Key)
    }

    /// The action `pressed` runs, or waits for, in `state`; nil when it runs none.
    /// - With the action panel open (§0), a key with a modifier runs the view's action with that shortcut, as with the
    ///   panel shut, submenus included; plain keys go to "Search for actions…".
    /// - With a picker, a dropdown's panel or the sign-in prompt open, no action runs.
    /// - Otherwise a key with a modifier runs the action with that shortcut. In a command, ⌘↵ (⌘⇧↵ in a Form) runs
    ///   the secondary action, and in a Detail or a Form the primary key runs the primary action; a key that belongs
    ///   to the selected item's actions before they've come waits for them.
    public static func outcome(of pressed: KeyShortcut, in state: State) -> Outcome? {
        if pressed == actionPanelKey { return nil }
        switch state.overlay {
        case .datePick, .dropdown, .signIn:
            return nil
        case .actionPanel:
            return shortcut(pressed, in: state.actions)
        case nil:
            break
        }
        switch state.place {
        case .failedCommand:
            return nil
        case .root, .failure:
            return shortcut(pressed, in: state.actions)
        case .command(let hasSearchField, let isForm):
            if pressed == secondaryKey(form: isForm) {
                if state.pendingShortcuts != nil { return .wait(.secondary) }
                return ActionPanelReader.secondary(state.actions).map(Outcome.run)
            }
            if !hasSearchField, pressed == primaryKey(form: isForm) {
                return ActionPanelReader.primary(state.actions).map(Outcome.run)
            }
            guard !pressed.modifiers.isEmpty else { return nil }
            if state.pendingShortcuts?.contains(pressed) == true { return .wait(.shortcut(pressed)) }
            return shortcut(pressed, in: state.actions)
        }
    }

    /// The action whose shortcut is `pressed`, for a key with a modifier; plain keys are typing.
    private static func shortcut(_ pressed: KeyShortcut, in actions: [ActionSection]) -> Outcome? {
        guard !pressed.modifiers.isEmpty else { return nil }
        return ActionPanelReader.action(for: pressed, in: actions).map(Outcome.run)
    }

    /// The key press a command hotkey stands for in the launcher (SPEC-127 §1): while the launcher holds the keyboard,
    /// a hotkey whose keys an action takes there (`outcome`) is that key press, which the app hands to `handleKey`
    /// instead of opening the command. Nil when the hotkey opens its command, as it does everywhere else: the launcher
    /// doesn't hold the keyboard, or no action takes those keys.
    /// `layout` is what a key types on the current keyboard layout with no modifiers, read only when the launcher
    /// holds the keyboard.
    public static func hotkeyPress(
        _ spec: HotKeySpec, layout: (UInt16) -> String?, launcherHoldsKeyboard: Bool, in state: State
    ) -> KeyShortcut? {
        guard launcherHoldsKeyboard, let pressed = KeyShortcut(hotkey: spec, layout: layout),
            outcome(of: pressed, in: state) != nil
        else { return nil }
        return pressed
    }
}

extension KeyShortcut {
    /// A hotkey as the key press it is: its key code named as a key event's is (`init(keyCode:characters:modifiers:)`),
    /// with `layout` giving what the key types with no modifiers on the current keyboard layout, as a key event's
    /// `characters(byApplyingModifiers: [])` does, and the hotkey's modifiers. So a hotkey and an action's shortcut
    /// name the same key on any layout: on AZERTY, key code 0 is "q", never the "a" it is on US keyboards.
    public init?(hotkey spec: HotKeySpec, layout: (UInt16) -> String?) {
        guard let keyCode = UInt16(exactly: spec.keyCode) else { return nil }
        var modifiers: Set<String> = []
        if spec.command { modifiers.insert("cmd") }
        if spec.control { modifiers.insert("ctrl") }
        if spec.option { modifiers.insert("opt") }
        if spec.shift { modifiers.insert("shift") }
        self.init(keyCode: keyCode, characters: layout(keyCode), modifiers: modifiers)
    }
}
