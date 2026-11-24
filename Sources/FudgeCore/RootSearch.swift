import Foundation

/// Something the root search can open: an application, an extension command, or one of fudge's own items.
public struct RootItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case application(URL)
        case command(extension: ExtensionID, command: String, mode: String, entry: URL)
        /// fudge's Settings window, on its default page.
        case settings
        /// Reads the extensions and applications again, as the menu bar item's "Reload Extensions" does.
        case reloadExtensions
        /// Quits fudge, after asking.
        case quit
        /// Opens a quicklink, with its arguments filled in.
        case quicklink(Quicklink)
        /// Opens the Create Quicklink form.
        case createQuicklink
        /// Opens Search Snippets (`SnippetList`).
        case searchSnippets
        /// Opens the Create Snippet form.
        case createSnippet
        /// Runs one of Fudge's own commands (`BuiltInCommandGroup`).
        case builtInCommand(group: BuiltInGroup, command: String)

        /// The SF Symbol of one of Fudge's own items (Reload Extensions, Quit Fudge, …); nil for the rest, whose
        /// icons are an app's, an extension's, a quicklink's, Fudge's own or their group's command's.
        public var symbol: String? {
            switch self {
            case .reloadExtensions: "arrow.clockwise"
            case .quit: "power"
            case .createQuicklink: "link.badge.plus"
            case .searchSnippets: "doc.text"
            case .createSnippet: "text.badge.plus"
            case .application, .command, .settings, .quicklink, .builtInCommand: nil
            }
        }
    }

    public var id: String
    public var title: String
    /// Shown dimmed after the title. For a command: the subtitle it set with `updateCommandMetadata`, else its
    /// manifest's, else its extension's title.
    public var subtitle: String?
    /// A command's extension title, which search matches like the subtitle even when the row shows another one.
    public var extensionTitle: String?
    public var keywords: [String]
    public var kind: Kind
    /// An image file for the row, if there is one (an extension's asset).
    public var iconFile: URL?
    /// A command's `arguments`, entered in fields after the query.
    public var arguments: [ExtensionManifest.Argument]
    /// A command's alias, from `settings.json`, or its default (`FudgeSettings.alias(ofCommand:)`).
    public var alias: String?
    /// Matched like the subtitle, but never shown: a quicklink's link.
    public var secondaryText: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        extensionTitle: String? = nil,
        keywords: [String] = [],
        kind: Kind,
        iconFile: URL? = nil,
        arguments: [ExtensionManifest.Argument] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.extensionTitle = extensionTitle
        self.keywords = keywords
        self.kind = kind
        self.iconFile = iconFile
        self.arguments = arguments
    }

    public static func application(at url: URL, title: String) -> RootItem {
        RootItem(id: "app:\(url.path)", title: title, kind: .application(url))
    }

    /// "Fudge Settings": opens the Settings window.
    public static let settings = RootItem(
        id: "fudge:settings",
        title: "Fudge Settings",
        keywords: ["settings", "preferences", "config", "fudge"],
        kind: .settings
    )

    /// "Reload Extensions": the menu bar item's reload, so nothing needs the menu bar.
    public static let reloadExtensions = RootItem(
        id: "fudge:reload-extensions",
        title: "Reload Extensions",
        keywords: ["reload", "refresh", "extensions", "fudge"],
        kind: .reloadExtensions
    )

    /// "Quit Fudge": asks first, since Fudge's hotkeys stop working until it's opened again.
    public static let quit = RootItem(
        id: "fudge:quit",
        title: "Quit Fudge",
        keywords: ["quit", "exit", "fudge"],
        kind: .quit
    )

    /// "Create Quicklink": opens Fudge's form for a new quicklink (SPEC-052 B1).
    public static let createQuicklink = RootItem(
        id: "fudge:create-quicklink",
        title: "Create Quicklink",
        keywords: ["quicklink", "link", "bookmark", "new", "fudge"],
        kind: .createQuicklink
    )

    /// "Search Snippets": lists the saved snippets, to paste or copy one (SPEC-078 §3).
    public static let searchSnippets = RootItem(
        id: "fudge:search-snippets",
        title: "Search Snippets",
        keywords: ["snippet", "snippets", "text", "paste", "fudge"],
        kind: .searchSnippets
    )

    /// "Create Snippet": opens Fudge's form for a new snippet.
    public static let createSnippet = RootItem(
        id: "fudge:create-snippet",
        title: "Create Snippet",
        keywords: ["snippet", "text", "new", "fudge"],
        kind: .createSnippet
    )

    /// Whether opening the item counts in `LaunchHistory`. Quitting doesn't, so an empty search never puts
    /// "Quit Fudge" at the top.
    public var recordsLaunch: Bool {
        kind != .quit
    }

    /// A quicklink's item: its name, its link as a secondary match, and its arguments as fields. The row's kind
    /// says "Quicklink", so there's no subtitle saying it again; "quicklink" still finds them.
    public static func quicklink(_ quicklink: Quicklink) -> RootItem {
        var item = RootItem(
            id: quicklink.rootItemID, title: quicklink.name, keywords: ["quicklink"], kind: .quicklink(quicklink),
            arguments: QuicklinkTemplate(quicklink.link).fields)
        item.secondaryText = QuicklinkTemplate(quicklink.link).searchableText
        return item
    }

    /// The id of a command's item, which its launches count under in `LaunchHistory`.
    public static func commandID(owner: CommandOwner, command: String) -> String {
        "command:\(owner.key)/\(command)"
    }

    /// The `settings.json` id of a command's item, an extension's or one of Fudge's own, or of a quicklink's
    /// (`QuicklinkCommands`): its alias, hotkey and Enabled are kept under it. Nil for other items, and for a
    /// quicklink whose id can't be part of a key.
    public var commandSettingsID: String? {
        switch kind {
        case .command(let id, let command, _, _):
            FudgeSettings.commandID(owner: .extension(id), command: command)
        case .builtInCommand(let group, let command):
            FudgeSettings.commandID(owner: .group(group), command: command)
        case .quicklink(let quicklink):
            QuicklinkCommands.commandID(ofQuicklink: quicklink.id)
        default:
            nil
        }
    }

    /// The id of the root item a `settings.json` command id belongs to: a quicklink's (`quicklink:<id>`) or a
    /// command's (`command:<id>`). A pressed hotkey finds its item by it, and a row shows its hotkey by it.
    public static func id(forCommandSettingsID commandID: String) -> String {
        if let quicklink = QuicklinkCommands.quicklinkID(inCommandID: commandID) { return "quicklink:\(quicklink)" }
        return "command:\(commandID)"
    }

    /// `subtitle`, or nil when it only repeats `title`, ignoring case and spaces around either (SPEC-120). It's for
    /// the subtitle a row falls back to, its extension's or group's title: a one-command extension named like its
    /// command would otherwise show its name twice. A subtitle an author set (the command's own in `package.json`, or
    /// one from `updateCommandMetadata`) is shown as set.
    static func subtitle(_ subtitle: String?, unlessItRepeats title: String) -> String? {
        guard let subtitle else { return nil }
        return ExtensionTitles.same(subtitle, title) ? nil : subtitle
    }

    /// One item per command of a group of Fudge's own, with the group's title as its subtitle.
    public static func builtInCommands(of group: BuiltInCommandGroup) -> [RootItem] {
        group.commands.map { command in
            RootItem(
                id: commandID(owner: .group(group.name), command: command.name),
                title: command.title,
                subtitle: subtitle(group.title, unlessItRepeats: command.title),
                extensionTitle: group.title,
                keywords: command.keywords,
                kind: .builtInCommand(group: group.name, command: command.name),
                arguments: command.arguments
            )
        }
    }

    /// One item per command of the extension (view, no-view and menu-bar), with the subtitles commands set for
    /// themselves. An install whose title another install shares has its repository's label after its subtitle, so
    /// the two read apart (`ExtensionTitles`, SPEC-174).
    public static func commands(
        of installed: InstalledExtension, titles: ExtensionTitles, metadata: CommandMetadata = CommandMetadata()
    ) -> [RootItem] {
        let manifest = installed.manifest
        let suffix = titles.label(of: installed).map { " (\($0))" } ?? ""
        let title = titles.title(of: installed)
        return manifest.commands.filter { ["view", "no-view", "menu-bar"].contains($0.mode) }.map { command in
            let icon = (command.icon ?? manifest.icon).map { installed.assetsDirectory.appendingPathComponent($0) }
            let shown =
                metadata.subtitle(extension: installed.id, command: command.name) ?? command.subtitle
                ?? subtitle(manifest.title, unlessItRepeats: command.title)
            return RootItem(
                id: commandID(owner: .extension(installed.id), command: command.name),
                title: command.title,
                subtitle: suffix.isEmpty ? shown : shown.map { $0 + suffix } ?? title,
                // What search matches a repository's name in: the title as shown, so only while it's labeled.
                extensionTitle: title,
                keywords: command.keywords,
                kind: .command(
                    extension: installed.id,
                    command: command.name,
                    mode: command.mode,
                    entry: installed.entry(for: command.name)
                ),
                iconFile: icon.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
                arguments: command.arguments
            )
        }
    }
}

/// Ranks root items for a query: fuzzy match first, launch history second.
/// One row of root search: a ranked item, or the Calculator card.
public enum RootRow: Sendable, Equatable, Identifiable {
    case item(RootItem)
    case calculator

    /// The Calculator card's id, as the selection holds it.
    public static let calculatorID = "calculator"

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .calculator: Self.calculatorID
        }
    }
}

public enum RootSearch {
    /// fudge's own items, searched alongside applications and commands.
    public static let builtInItems: [RootItem] = [
        .settings, .createQuicklink, .searchSnippets, .createSnippet, .reloadExtensions, .quit,
    ]

    /// What an empty root search lists first while nothing has been opened yet (SPEC-114 §4), so a new user sees
    /// some of what Fudge does: Search Snippets, Clipboard History, Search Emoji & Symbols and Fudge Settings, in that
    /// order, each only when it's there. Any launch history at all puts it back to most-used first, then by title.
    public static let firstRunItemIDs = [
        RootItem.searchSnippets.id,
        RootItem.commandID(owner: .extension(ClipboardHistory.id), command: "clipboard-history"),
        RootItem.commandID(owner: .extension(BundledExtensions.emojiID), command: "search-emoji"),
        RootItem.settings.id,
    ]

    /// Applies `settings` to command items, an extension's or one of Fudge's own: disabled commands (or commands of
    /// disabled extensions or groups) are left out, and each command gets its alias.
    public static func applying(_ settings: FudgeSettings, to items: [RootItem]) -> [RootItem] {
        items.compactMap { item in
            guard let id = item.commandSettingsID else { return item }
            guard settings.isEnabled(commandID: id) else { return nil }
            var item = item
            item.alias = settings.alias(ofCommand: id)
            return item
        }
    }

    /// Root search's rows in order: the command whose alias the query is exactly, then the Calculator card when the
    /// query is a calculation, then the other `results` as ranked. The panel draws these, and ↑↓ moves through
    /// them, so the two always agree.
    public static func rows(_ results: [RootItem], query: String, hasCalculator: Bool) -> [RootRow] {
        let match = exactAliasMatch(in: results, query: query)
        var rows = match.map { [RootRow.item($0)] } ?? []
        if hasCalculator { rows.append(.calculator) }
        return rows + results.filter { $0.id != match?.id }.map(RootRow.item)
    }

    /// The result whose alias is exactly `query`, ignoring case and surrounding spaces.
    public static func exactAliasMatch(in results: [RootItem], query: String) -> RootItem? {
        let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return nil }
        return results.first { $0.alias?.lowercased() == typed }
    }

    public static func rank(_ items: [RootItem], query: String, history: LaunchHistory, now: Date = Date())
        -> [RootItem]
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Nothing typed: commands and apps you use, most-used first, then the rest by title.
            let sorted = items.sorted { a, b in
                let (fa, fb) = (history.score(a.id, now: now), history.score(b.id, now: now))
                if fa != fb { return fa > fb }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            // Nothing opened yet: a few of Fudge's own items first.
            guard history.entries.isEmpty else { return sorted }
            let first = firstRunItemIDs.compactMap { id in sorted.first { $0.id == id } }
            return first + sorted.filter { !firstRunItemIDs.contains($0.id) }
        }
        let scored: [(RootItem, Double)] = items.compactMap { item in
            guard let match = bestMatch(trimmed, for: item) else { return nil }
            let boost = 12 * log2(1 + history.score(item.id, now: now))
            return (item, Double(match) + boost)
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.title.localizedStandardCompare(b.0.title) == .orderedAscending
        }.map(\.0)
    }

    /// An exact alias outranks everything, and an alias the query starts outranks any fuzzy match of a title.
    static let exactAliasScore = 1_000_000
    static let aliasPrefixScore = 100_000

    static func bestMatch(_ query: String, for item: RootItem) -> Int? {
        if let alias = item.alias?.lowercased() {
            let typed = query.lowercased()
            if alias == typed { return exactAliasScore }
            if alias.hasPrefix(typed) { return aliasPrefixScore + typed.count }
        }
        var best = Fuzzy.match(query, in: item.title)?.score
        for keyword in item.keywords {
            if let score = Fuzzy.match(query, in: keyword)?.score, score - 5 > (best ?? .min) { best = score - 5 }
        }
        for subtitle in [item.subtitle, item.extensionTitle, item.secondaryText].compactMap(\.self) {
            if let score = Fuzzy.match(query, in: subtitle)?.score, score - 20 > (best ?? .min) { best = score - 20 }
        }
        return best
    }
}

/// How often and how recently each root item was opened. Stored as JSON.
public struct LaunchHistory: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var count: Int
        public var lastUsed: Date
    }

    public var entries: [String: Entry] = [:]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public mutating func record(_ id: String, at date: Date = Date()) {
        let count = (entries[id]?.count ?? 0) + 1
        entries[id] = Entry(count: count, lastUsed: date)
    }

    /// Forgets every launch: root search ranks by match alone again (Clear Search History).
    public mutating func clear() {
        entries = [:]
    }

    /// Uses, discounted by age: a launch a week ago counts half as much as one today.
    public func score(_ id: String, now: Date = Date()) -> Double {
        guard let entry = entries[id] else { return 0 }
        let days = max(0, now.timeIntervalSince(entry.lastUsed) / 86_400)
        return Double(entry.count) / (1 + days / 7)
    }

    public static func load(from file: URL) -> LaunchHistory {
        guard let data = try? Data(contentsOf: file) else { return LaunchHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LaunchHistory.self, from: data)) ?? LaunchHistory()
    }

    public func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}

/// Finds installed applications by looking in the usual folders.
public enum ApplicationIndex {
    public static let standardFolders: [URL] =
        [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]

    /// Every `.app` directly inside `folders`, titled by its display name, without duplicates.
    public static func scan(_ folders: [URL] = standardFolders) -> [RootItem] {
        let files = FileManager.default
        var seen = Set<String>()
        var items: [RootItem] = []
        for folder in folders {
            let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".app") {
                let url = folder.appendingPathComponent(name, isDirectory: true).resolvingSymlinksInPath()
                guard seen.insert(url.path).inserted else { continue }
                let title = (files.displayName(atPath: url.path) as NSString).deletingPathExtension
                items.append(.application(at: url, title: title))
            }
        }
        return items
    }
}
