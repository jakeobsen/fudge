import Foundation

/// Quicklinks as commands (SPEC-097): each quicklink is a command of the `:quicklinks` group, with an alias, a hotkey
/// and Enabled, as a built-in group's commands are. They're kept in `settings.json`'s `commands` under
/// `:quicklinks/<quicklink id>`, and the group's own Enabled under `extensions`. The key holds the quicklink's `id`,
/// never its name, so a rename keeps them.
public enum QuicklinkCommands {
    /// The group's name: `:` and a valid extension name, so no extension can take its keys.
    /// The group's key, also the prefix of its commands' ids.
    public static let groupName = BuiltInGroup.quicklinks.rawValue
    public static let groupTitle = "Quicklinks"
    /// The SF Symbol a quicklink's row shows on the Commands page.
    public static let symbol = "link"
    /// How a message names a quicklink's key when no quicklink has that id any more.
    public static let deletedName = "a deleted quicklink"

    /// `deletedName` for a `:quicklinks/…` key, which a message shows when the key's quicklink isn't found; nil for
    /// any other key.
    public static func nameWhenGone(_ commandID: String) -> String? {
        commandID.hasPrefix(groupName + "/") ? deletedName : nil
    }

    /// Whether a quicklink's `id` can be part of a settings key: 1 to 64 ASCII letters, digits, `-` and `_`, letter
    /// case kept, as `UUID().uuidString` is. This is the quicklink group's own rule, not the extension name rule,
    /// which allows no upper case. A quicklink whose id doesn't fit (one edited by hand to hold a `/` or a space,
    /// say) gets no alias, hotkey or Enabled, and still shows and opens.
    public static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.utf8.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                    UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                    true
                default:
                    false
                }
            }
    }

    /// A quicklink's key in `settings.json`'s `commands`: `:quicklinks/<id>`, the id exactly as `quicklinks.json`
    /// holds it. Nil when the id can't be part of a key (`isValidID`).
    public static func commandID(ofQuicklink id: String) -> String? {
        isValidID(id) ? FudgeSettings.commandID(owner: .group(.quicklinks), command: id) : nil
    }

    /// The quicklink id a command key names; nil for any other key, and for one whose id `isValidID` refuses.
    public static func quicklinkID(inCommandID commandID: String) -> String? {
        guard commandID.hasPrefix(groupName + "/") else { return nil }
        let id = String(commandID.dropFirst(groupName.count + 1))
        return isValidID(id) ? id : nil
    }

    /// The keys of `quicklinks` that can have settings. Their hotkeys are registered and block a key, and conflicts
    /// name them, as installed commands' do.
    public static func commandIDs(_ quicklinks: [Quicklink]) -> [String] {
        quicklinks.compactMap { commandID(ofQuicklink: $0.id) }
    }

    /// The group as the Commands page and conflict messages see it: one command per quicklink that can have settings,
    /// sorted by name, titled with the name.
    public static func group(_ quicklinks: [Quicklink]) -> BuiltInCommandGroup {
        let commands =
            quicklinks
            .filter { isValidID($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { BuiltInCommand(name: $0.id, title: $0.name, keywords: ["quicklink"], symbol: symbol) }
        return BuiltInCommandGroup(name: .quicklinks, title: groupTitle, commands: commands)
    }

    /// What pressing a quicklink's hotkey does, as a no-view command's does: open it straight away, or show root
    /// search with it selected and its fields when one is required (it has no default). A quicklink is never "on
    /// screen", so the hotkey never just hides the panel.
    public static func hotkeyLaunch(_ quicklink: Quicklink) -> HotKeyLaunch {
        HotKeyLaunch.action(
            mode: "no-view",
            hasRequiredArgument: QuicklinkTemplate(quicklink.link).fields.contains { $0.required == true },
            isOnScreen: false)
    }

    /// Takes out the settings of quicklinks that are gone from `store`'s file: `:quicklinks/…` keys whose id no entry
    /// has. An entry that's still there but isn't a valid quicklink (a hand edit) keeps its settings, so fixing it
    /// brings them back. Run it only with a store read from a file that could be read. True when it took something
    /// out.
    @discardableResult
    public static func prune(_ settings: inout FudgeSettings, in store: QuicklinkStore) -> Bool {
        prune(&settings, keepingIDs: store.entryIDs)
    }

    /// `prune(_:in:)` for these quicklinks' ids.
    @discardableResult
    public static func prune(_ settings: inout FudgeSettings, keeping quicklinks: [Quicklink]) -> Bool {
        prune(&settings, keepingIDs: Set(quicklinks.map(\.id)))
    }

    static func prune(_ settings: inout FudgeSettings, keepingIDs kept: Set<String>) -> Bool {
        let prefix = groupName + "/"
        let gone = settings.commands.keys.filter {
            $0.hasPrefix(prefix) && !kept.contains(String($0.dropFirst(prefix.count)))
        }
        for key in gone { settings.commands[key] = nil }
        return !gone.isEmpty
    }
}
