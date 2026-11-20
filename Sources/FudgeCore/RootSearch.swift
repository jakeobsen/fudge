import Foundation

/// Something the root search can open: an application, an extension command, or one of fudge's own items.
public struct RootItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case application(URL)
        case command(extension: String, command: String, mode: String, entry: URL)
        /// fudge's Settings window, on its default page.
        case settings
    }

    public var id: String
    public var title: String
    /// Shown dimmed after the title: the extension's title for commands.
    public var subtitle: String?
    public var keywords: [String]
    public var kind: Kind
    /// An image file for the row, if there is one (an extension's asset).
    public var iconFile: URL?
    /// A command's `arguments`, entered in fields after the query.
    public var arguments: [ExtensionManifest.Argument]

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        kind: Kind,
        iconFile: URL? = nil,
        arguments: [ExtensionManifest.Argument] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.kind = kind
        self.iconFile = iconFile
        self.arguments = arguments
    }

    public static func application(at url: URL, title: String) -> RootItem {
        RootItem(id: "app:\(url.path)", title: title, kind: .application(url))
    }

    /// "fudge Settings": opens the Settings window.
    public static let settings = RootItem(
        id: "fudge:settings",
        title: "fudge Settings",
        keywords: ["settings", "preferences", "config", "fudge"],
        kind: .settings
    )

    /// The id of a command's item, which its launches count under in `LaunchHistory`.
    public static func commandID(extension extensionName: String, command: String) -> String {
        "command:\(extensionName)/\(command)"
    }

    /// One item per view or no-view command of the extension.
    public static func commands(of installed: InstalledExtension) -> [RootItem] {
        let manifest = installed.manifest
        return manifest.commands.filter { $0.mode == "view" || $0.mode == "no-view" }.map { command in
            let icon = (command.icon ?? manifest.icon).map { installed.assetsDirectory.appendingPathComponent($0) }
            return RootItem(
                id: commandID(extension: manifest.name, command: command.name),
                title: command.title,
                subtitle: manifest.title,
                keywords: command.keywords,
                kind: .command(
                    extension: manifest.name,
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
public enum RootSearch {
    /// fudge's own items, searched alongside applications and commands.
    public static let builtInItems: [RootItem] = [.settings]

    public static func rank(_ items: [RootItem], query: String, history: LaunchHistory, now: Date = Date())
        -> [RootItem]
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Nothing typed: commands and apps you use, most-used first, then the rest by title.
            return items.sorted { a, b in
                let (fa, fb) = (history.score(a.id, now: now), history.score(b.id, now: now))
                if fa != fb { return fa > fb }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
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

    static func bestMatch(_ query: String, for item: RootItem) -> Int? {
        var best = Fuzzy.match(query, in: item.title)?.score
        for keyword in item.keywords {
            if let score = Fuzzy.match(query, in: keyword)?.score, score - 5 > (best ?? .min) { best = score - 5 }
        }
        if let subtitle = item.subtitle, let score = Fuzzy.match(query, in: subtitle)?.score,
            score - 20 > (best ?? .min)
        {
            best = score - 20
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
