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

/// Root search's hand-off (`CommandAliases.handOff`), once per query (FUD-140).
///
/// The hand-off moves the keyboard to the argument field, and SwiftUI's search field writes its text back when it
/// loses the keyboard, so the query just handed off can come back while the keyboard is in the field. Handed off
/// again, its rest would replace what the user has typed in the field since.
public struct AliasHandOff: Sendable, Equatable {
    public enum Answer: Sendable, Equatable {
        /// Select `item` and move `rest` into its first argument field.
        case handOff(item: RootItem, rest: String)
        /// The query the last hand-off took, back while an argument field has the keyboard: nothing changes.
        case alreadyHandedOff
        /// An ordinary query.
        case query
    }

    private struct Taken: Sendable, Equatable {
        var query: String
        var item: RootItem.ID
    }

    /// The query the last hand-off took, and the row it selected, until another query is typed.
    private var last: Taken?

    public init() {}

    /// `query` was typed in root search, where `inArgument` says whether an argument field has the keyboard.
    /// The same query for the same row is handed off again only from the search field: the user typed it again.
    public mutating func answer(_ query: String, in items: [RootItem], inArgument: Bool) -> Answer {
        guard let handed = CommandAliases.handOff(query, in: items) else {
            last = nil
            return .query
        }
        let taken = Taken(query: query, item: handed.item.id)
        if inArgument, taken == last { return .alreadyHandedOff }
        last = taken
        return .handOff(item: handed.item, rest: handed.rest)
    }
}
