import Foundation

/// One of Fudge's own commands, in a `BuiltInCommandGroup`. Root search lists it, and it gets an alias, a hotkey and
/// Enabled as an extension's command does (SPEC-066 §1).
public struct BuiltInCommand: Sendable, Equatable {
    public var name: String
    public var title: String
    public var keywords: [String]
    /// The SF Symbol its rows show.
    public var symbol: String
    /// Its arguments, entered in fields after the query as an extension command's are.
    public var arguments: [ExtensionManifest.Argument]
    /// Its alias until the user sets or clears one (`FudgeSettings.alias(ofCommand:)`): "define" for Define Word, so
    /// `define serendipity` hands the word to its field.
    public var defaultAlias: String?

    public init(
        name: String, title: String, keywords: [String] = [], symbol: String,
        arguments: [ExtensionManifest.Argument] = [], defaultAlias: String? = nil
    ) {
        self.name = name
        self.title = title
        self.keywords = keywords
        self.symbol = symbol
        self.arguments = arguments
        self.defaultAlias = defaultAlias
    }
}

/// A group of Fudge's own commands. Its commands' alias, hotkey and Enabled live in `settings.json`'s `commands` like an
/// extension command's, keyed `<group>/<command>`, and the group's own Enabled in `extensions`, like an extension's.
/// A group's name is `:` and then a valid extension name (`:window-management`). The extension name rule allows no
/// `:`, so no installed extension can take a group's keys (`isValidName`).
public struct BuiltInCommandGroup: Sendable, Equatable, Identifiable {
    /// Its key, one of a closed list, so no group is made from a free string.
    public var name: BuiltInGroup
    public var title: String
    public var commands: [BuiltInCommand]

    public var id: String { name.rawValue }

    public init(name: BuiltInGroup, title: String, commands: [BuiltInCommand]) {
        self.name = name
        self.title = title
        self.commands = commands
    }

    /// Fudge's groups, by title, which the Commands page lists in this order above the extensions.
    public static let all: [BuiltInCommandGroup] = [.apps, .calendar, .system, .tools, .windowManagement]

    /// The Commands page's Type column for a group's row and for its commands' rows: "Built-in" and "Command" for
    /// Fudge's own groups, "Quicklinks" and "Quicklink" for the quicklinks.
    public static func typeLabels(ofGroup name: BuiltInGroup) -> (group: String, command: String) {
        name == .quicklinks ? ("Quicklinks", "Quicklink") : ("Built-in", "Command")
    }

    /// Whether `name` can name a group: `:` and a valid extension name, so it's never an extension's name.
    public static func isValidName(_ name: String) -> Bool {
        name.hasPrefix(":") && ExtensionManifest.isValidName(String(name.dropFirst()))
    }

    /// The `settings.json` id of one of the group's commands.
    public func commandID(_ command: BuiltInCommand) -> String {
        FudgeSettings.commandID(owner: .group(name), command: command.name)
    }

    /// The ids of every command in `groups`. Their hotkeys are registered, and block a key, as installed commands'
    /// do.
    public static func commandIDs(in groups: [BuiltInCommandGroup] = all) -> [String] {
        groups.flatMap { group in group.commands.map(group.commandID) }
    }

    /// The group and command a root item's `.builtInCommand` kind names.
    public static func command(group name: BuiltInGroup, command: String, in groups: [BuiltInCommandGroup] = all)
        -> (group: BuiltInCommandGroup, command: BuiltInCommand)?
    {
        guard let group = groups.first(where: { $0.name == name }),
            let found = group.commands.first(where: { $0.name == command })
        else { return nil }
        return (group, found)
    }
}
