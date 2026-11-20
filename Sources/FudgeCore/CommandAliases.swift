import Foundation

/// Command aliases: short names typed in root search (`sf` for Scratch Folders).
public enum CommandAliases {
    public enum Problem: Sendable, Equatable {
        case length
        case spaces
        /// Another command has it already (case doesn't count).
        case duplicate(String)
    }

    /// Why `alias` can't be `commandID`'s: 1 to 32 characters, no spaces, unique among commands ignoring case.
    public static func problem(with alias: String, for commandID: String, in settings: FudgeSettings) -> Problem? {
        guard (1...32).contains(alias.count) else { return .length }
        guard !alias.contains(where: \.isWhitespace) else { return .spaces }
        let typed = alias.lowercased()
        if let other = settings.commands.first(where: { $0.key != commandID && $0.value.alias?.lowercased() == typed })
        {
            return .duplicate(other.key)
        }
        return nil
    }

    /// "Alias then space", as in Raycast: when `query` is an alias of a command with arguments followed by a space,
    /// the command takes the alias and the rest of the query becomes its first argument's text.
    public static func handOff(_ query: String, in items: [RootItem]) -> (item: RootItem, rest: String)? {
        guard let space = query.firstIndex(of: " ") else { return nil }
        let typed = query[..<space].lowercased()
        guard !typed.isEmpty,
            let item = items.first(where: { $0.alias?.lowercased() == typed && !$0.arguments.isEmpty })
        else { return nil }
        return (item, String(query[query.index(after: space)...]))
    }
}
