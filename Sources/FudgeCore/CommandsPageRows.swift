import Foundation

/// The Settings window's Commands page as rows, which `CommandsPage` only draws: Fudge's own groups first (with the
/// saved window positions and layouts), then the quicklinks, then every installed extension, each with its commands,
/// as far as they match the search. Every row has an id of its own across the whole page: a group's is its owner, and
/// a command's is its whole command id, so two extensions of one name, whose commands have the same names, both list
/// their commands (FUD-183).
public enum CommandsPageRows {
    /// A row's icon, read only when the row is drawn, so the search doesn't load every extension's icon on each
    /// keystroke.
    public enum Icon: Sendable, Equatable {
        /// Fudge's own icon.
        case app
        /// An SF Symbol.
        case symbol(String)
        /// A file in the extension's assets folder, or the placeholder when there's none.
        case asset(String?, InstalledExtension)
    }

    /// One group of rows: a group of Fudge's own commands, or an installed extension.
    public struct Group: Sendable, Equatable {
        /// Keys its Enabled and whether it's collapsed, and identifies its row.
        public var owner: CommandOwner
        public var title: String
        /// The Type column: "Built-in", "Quicklinks" or "Extension".
        public var type: String
        public var icon: Icon
        public var commands: [Command]
    }

    /// One command's row.
    public struct Command: Sendable, Equatable {
        /// Its whole command id (`FudgeSettings.commandID(owner:command:)`): it keys the command's alias, hotkey and
        /// Enabled, and identifies its row, since another extension can have a command of the same name.
        public var id: String
        public var title: String
        public var icon: Icon
        /// The Type column: "Command", or "Quicklink" in the quicklinks' group.
        public var type: String
    }

    /// The page's rows: `groups` (`SettingsModel.commandGroups`) that have commands, then `extensions` in the order
    /// given, each with its view, no-view and menu-bar commands. A non-empty `search` keeps a group whose title has it
    /// with all its commands, and of any other group only the commands whose titles have it, ignoring case.
    public static func rows(groups: [BuiltInCommandGroup], extensions: [InstalledExtension], search: String) -> [Group]
    {
        // The quicklinks' group shows once there's a quicklink.
        let own = groups.filter { !$0.commands.isEmpty }.map { group in
            let types = BuiltInCommandGroup.typeLabels(ofGroup: group.name)
            let owner = CommandOwner.group(group.name)
            return Group(
                owner: owner, title: group.title, type: types.group, icon: .app,
                commands: group.commands.map {
                    Command(
                        id: FudgeSettings.commandID(owner: owner, command: $0.name), title: $0.title,
                        icon: .symbol($0.symbol), type: types.command)
                })
        }
        let installed = extensions.map { installed in
            let owner = CommandOwner.extension(installed.id)
            return Group(
                owner: owner, title: installed.displayTitle, type: "Extension",
                icon: .asset(installed.manifest.icon, installed),
                commands: installed.manifest.commands.filter { ["view", "no-view", "menu-bar"].contains($0.mode) }
                    .map { command in
                        Command(
                            id: FudgeSettings.commandID(owner: owner, command: command.name), title: command.title,
                            icon: .asset(command.icon ?? installed.manifest.icon, installed), type: "Command")
                    })
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return own + installed }
        return (own + installed).compactMap { group in
            if group.title.lowercased().contains(query) { return group }
            var group = group
            group.commands = group.commands.filter { $0.title.lowercased().contains(query) }
            return group.commands.isEmpty ? nil : group
        }
    }
}
