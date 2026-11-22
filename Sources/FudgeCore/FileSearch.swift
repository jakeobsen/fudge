import Foundation
import UniformTypeIdentifiers

/// Search Files (FUD-100, SPEC-069): the bundled `fudge-file-search` extension asks the app for files by name with the
/// `files.search` rpc, and the app asks Spotlight. Everything but the Spotlight query itself is here: the call's
/// params, the extension's preferences, the predicate, what's left out, the ranking, and the timing.
public enum FileSearchScope: String, Sendable, Equatable {
    /// The home folder (`NSMetadataQueryUserHomeScope`), the default.
    case home
    /// The whole Mac (`NSMetadataQueryLocalComputerScope`).
    case mac
}

/// Where to search, from the extension's preferences: **Search In** (`searchIn`: `home` or `mac`) and **Leave Out**
/// (`leaveOut`: folders separated by commas, a leading `~` being the home folder).
public struct FileSearchOptions: Sendable, Equatable {
    public var scope: FileSearchScope
    /// Absolute paths, without a trailing `/`.
    public var leaveOut: [String]
    /// The home folder, without a trailing `/`.
    public var home: String

    public init(scope: FileSearchScope = .home, leaveOut: [String] = [], home: String) {
        self.scope = scope
        self.leaveOut = leaveOut
        self.home = Self.trimmed(home)
    }

    public init(preferences: [String: JSONValue], home: String) {
        let scope: FileSearchScope =
            if case .string(let value) = preferences["searchIn"], let scope = FileSearchScope(rawValue: value) {
                scope
            } else {
                .home
            }
        var folders: [String] = []
        if case .string(let list) = preferences["leaveOut"] {
            for entry in list.split(separator: ",") {
                var folder = entry.trimmingCharacters(in: .whitespaces)
                if folder == "~" || folder.hasPrefix("~/") { folder = Self.trimmed(home) + folder.dropFirst() }
                // Only absolute folders: a relative one would mean something different for every result.
                guard folder.hasPrefix("/") else { continue }
                folders.append(Self.trimmed(folder))
            }
        }
        self.init(scope: scope, leaveOut: folders, home: home)
    }

    /// The home folder as the extension sees it: `$HOME`, which Node's `os.homedir()` reads too, else the account's.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["HOME"], home.hasPrefix("/") { return home }
        return NSHomeDirectory()
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// One `files.search` call's params: `query`, and `limit` (default 200, at most 500).
public struct FileSearchRequest: Sendable, Equatable {
    public static let defaultLimit = 200
    public static let maxLimit = 500

    /// Trimmed of whitespace.
    public var query: String
    public var limit: Int

    public init(query: String, limit: Int = defaultLimit) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.limit = min(max(limit, 1), Self.maxLimit)
    }

    public init(params: JSONValue) throws {
        guard case .object(let object) = params, case .string(let query) = object["query"] else {
            throw FileSearchError.badParams("files.search needs a string `query`")
        }
        switch object["limit"] {
        case nil, .null:
            self.init(query: query)
        case .number(let limit) where limit.isFinite:
            self.init(query: query, limit: Int(limit))
        default:
            throw FileSearchError.badParams("files.search's `limit` must be a number")
        }
    }

    /// The query's whitespace-separated words, each of which must appear in a result's name.
    public var words: [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }
}

public enum FileSearchError: Error, Equatable, CustomStringConvertible {
    case badParams(String)
    /// The caller isn't Search Files.
    case notSearchFiles
    /// Spotlight couldn't run the query, e.g. because it's off.
    case spotlight(String)

    public var description: String {
        switch self {
        case .badParams(let message), .spotlight(let message): message
        case .notSearchFiles: "files.search is only for Fudge's Search Files."
        }
    }
}

/// A file or folder Spotlight found, as `files.search` answers it.
public struct FoundFile: Sendable, Equatable {
    public var path: String
    public var name: String
    /// Spotlight's localized kind, e.g. "PDF document".
    public var kind: String
    public var isFolder: Bool
    /// In bytes; files only.
    public var size: Int?
    public var modified: Date
    public var lastUsed: Date?

    public init(
        path: String, name: String, kind: String = "", isFolder: Bool = false, size: Int? = nil, modified: Date,
        lastUsed: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.isFolder = isFolder
        self.size = isFolder ? nil : size
        self.modified = modified
        self.lastUsed = lastUsed
    }

    /// Reads one Spotlight result through `attribute` (`NSMetadataItem.value(forAttribute:)`). Nil without a path
    /// or a modification date.
    public init?(attribute: (String) -> Any?) {
        guard let path = attribute(NSMetadataItemPathKey) as? String, !path.isEmpty,
            let modified = attribute("kMDItemContentModificationDate") as? Date
                ?? attribute(NSMetadataItemFSContentChangeDateKey) as? Date
        else { return nil }
        let types = attribute(NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        self.init(
            path: path,
            name: attribute(NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent,
            kind: attribute(NSMetadataItemKindKey) as? String ?? "",
            isFolder: types.contains("public.folder"),
            size: (attribute(NSMetadataItemFSSizeKey) as? NSNumber)?.intValue,
            modified: modified,
            lastUsed: attribute(NSMetadataItemLastUsedDateKey) as? Date
        )
    }

    /// Reads an entry written as `json` writes it, as snapshot runs' fixed results are. A `path` starting with `~/`
    /// is inside `home`.
    public init?(json: JSONValue, home: String) {
        guard case .object(let object) = json, case .string(var path) = object["path"],
            let modified = FormDates.date(object["modified"])
        else { return nil }
        if path.hasPrefix("~/") { path = home + path.dropFirst() }
        func string(_ key: String) -> String? { if case .string(let value) = object[key] { value } else { nil } }
        let size: Int? = if case .number(let size) = object["size"], size.isFinite { Int(size) } else { nil }
        self.init(
            path: path, name: string("name") ?? (path as NSString).lastPathComponent, kind: string("kind") ?? "",
            isFolder: object["isFolder"] == .bool(true), size: size, modified: modified,
            lastUsed: FormDates.date(object["lastUsed"]))
    }

    /// The answer's entry: dates as `{ "$date": iso }`, and `size` and `lastUsed` only when known.
    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "path": .string(path), "name": .string(name), "kind": .string(kind), "isFolder": .bool(isFolder),
            "modified": FormDates.json(modified),
        ]
        if let size { object["size"] = .number(Double(size)) }
        if let lastUsed { object["lastUsed"] = FormDates.json(lastUsed) }
        return .object(object)
    }
}

/// What Spotlight is asked.
public enum FileSearchPredicate {
    /// An empty query lists what was used in the last 30 days.
    public static let recentDays = 30

    /// Every word of the query in the name (`kMDItemFSName LIKE[cd] "*word*"`), or, with no words, used in the last
    /// `recentDays` days. The words go in as arguments, never into the format, so only `LIKE`'s own `*`, `?` and `\`
    /// are escaped.
    public static func make(_ request: FileSearchRequest, now: Date) -> NSPredicate {
        let words = request.words
        guard !words.isEmpty else {
            let since = now.addingTimeInterval(-Double(recentDays) * 24 * 60 * 60)
            return NSPredicate(format: "%K >= %@", NSMetadataItemLastUsedDateKey, since as NSDate)
        }
        let parts = words.map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, pattern($0)) }
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// `*word*`, with `word`'s `\`, `*` and `?` matching literally.
    static func pattern(_ word: String) -> String {
        var escaped = ""
        for character in word {
            if character == "\\" || character == "*" || character == "?" { escaped.append("\\") }
            escaped.append(character)
        }
        return "*\(escaped)*"
    }
}

/// What a search leaves out of Spotlight's results.
public enum FileSearchFilter {
    /// Folder extensions that are packages, whatever the system says about them.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "photoslibrary", "plugin", "playground", "rtfd", "sparsebundle",
        "xcodeproj", "xcworkspace", "xpc",
    ]

    /// Whether a folder named `name` is a package (an `.app`, a `.bundle`, a `.photoslibrary` …): its extension is
    /// a known one, or its type conforms to `com.apple.package`.
    public static func isPackage(_ name: String) -> Bool {
        let pathExtension = (name as NSString).pathExtension.lowercased()
        guard !pathExtension.isEmpty else { return false }
        if packageExtensions.contains(pathExtension) { return true }
        return UTType(filenameExtension: pathExtension)?.conforms(to: .package) ?? false
    }

    /// Whether `path` is kept: inside the home folder when that's the scope, not under a **Leave Out** folder
    /// (ignoring case, as the Mac's file system does), with no hidden component (starting with `.`), and not inside
    /// a package, though a package itself is kept.
    public static func keeps(
        _ path: String, options: FileSearchOptions, isPackage: (String) -> Bool = FileSearchFilter.isPackage
    ) -> Bool {
        if options.scope == .home, !isInside(path, options.home) { return false }
        if options.leaveOut.contains(where: { isInside(path, $0) }) { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0.hasPrefix(".") }) { return false }
        return !components.dropLast().contains { isPackage(String($0)) }
    }

    /// `path` is `folder` or inside it, ignoring case.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let path = path.lowercased()
        let folder = folder.lowercased()
        if folder == "/" { return path.hasPrefix("/") }
        return path == folder || path.hasPrefix(folder + "/")
    }
}

/// The order of the results, best first (SPEC-069 §2):
/// 1. the name equals the query, with or without its extension;
/// 2. the name starts with it;
/// 3. a word in the name (a run of letters and digits) starts with it;
/// 4. anywhere.
/// Letter case and diacritics are ignored. Ties go to the most recently used, then the most recently modified, then
/// the shorter path. With no query, it's the most recently used first.
public enum FileSearchRanking {
    public static func rank(_ files: [FoundFile], query: String) -> [FoundFile] {
        let query = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let tiers = files.map { query.isEmpty ? 0 : tier(name: $0.name, query: query) }
        return zip(files, tiers).sorted { first, second in
            if first.1 != second.1 { return first.1 < second.1 }
            return isNewer(first.0, than: second.0)
        }.map(\.0)
    }

    /// 1 to 4, as above; `query` is already folded.
    static func tier(name: String, query: String) -> Int {
        let name = fold(name)
        let stem = (name as NSString).deletingPathExtension
        if name == query || stem == query { return 1 }
        if name.hasPrefix(query) { return 2 }
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(query) }) { return 3 }
        return 4
    }

    private static func isNewer(_ first: FoundFile, than second: FoundFile) -> Bool {
        switch (first.lastUsed, second.lastUsed) {
        case (let first?, let second?) where first != second: return first > second
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if first.modified != second.modified { return first.modified > second.modified }
        if first.path.count != second.path.count { return first.path.count < second.path.count }
        return first.path < second.path
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// One Spotlight query, as `FileSearch` drives it: the app's runs an `NSMetadataQuery` on its own `OperationQueue`,
/// and tests use a fake. Each is used once.
public protocol FileMetadataQuery: AnyObject, Sendable {
    /// Starts gathering what `FileSearchPredicate.make(request, now:)` asks for, in `scope`. `finished` is called
    /// once the first gathering is done, or with why the query couldn't start.
    func start(
        _ request: FileSearchRequest, now: Date, scope: FileSearchScope,
        finished: @escaping @Sendable (_ failure: String?) -> Void)
    /// Stops the query and returns what it gathered: at most `cap` results, the most recently used first.
    func finish(cap: Int) async -> [FoundFile]
    /// Stops the query; its results aren't needed.
    func cancel()
}

/// Runs `files.search` calls (SPEC-069 §2). Each call gets a new query, answered with what Spotlight has gathered
/// once it finishes gathering or after `timeLimit`, whichever comes first. Everything gathered, up to `readCap`, is
/// left out or kept, ranked, and only then cut to the call's `limit`, so a late exact match isn't lost. A newer call
/// from the same session stops the older one's query, and the older call answers `[]`. Only Search Files may call it.
public actor FileSearch {
    /// The bundled extension that may call it.
    public static let extensionName = "fudge-file-search"
    /// Its id, the key its settings and data are kept under.
    public static let id = ExtensionID.bundled(extensionName)
    public static let defaultTimeLimit: Duration = .milliseconds(1500)
    /// How many of Spotlight's results are read, the most recently used first. A broad query on the whole Mac can
    /// gather far more.
    public static let readCap = 5000

    private enum Outcome {
        case gathered([FoundFile])
        case superseded
        case failed(String)
    }

    private final class Call: @unchecked Sendable {
        let query: FileMetadataQuery
        var continuation: CheckedContinuation<Outcome, Never>?
        init(query: FileMetadataQuery) { self.query = query }
    }

    private let makeQuery: @Sendable () -> FileMetadataQuery
    private let timeLimit: Duration
    private let now: @Sendable () -> Date
    private var running: [String: Call] = [:]

    public init(
        timeLimit: Duration = FileSearch.defaultTimeLimit, now: @escaping @Sendable () -> Date = Date.init,
        makeQuery: @escaping @Sendable () -> FileMetadataQuery
    ) {
        self.timeLimit = timeLimit
        self.now = now
        self.makeQuery = makeQuery
    }

    /// Answers one call with `params` from `session`, a session of the extension `caller`.
    public func search(
        _ params: JSONValue, options: FileSearchOptions, session: String, caller: ExtensionID?
    ) async throws -> [FoundFile] {
        guard BundledCalls.mayCall(.filesSearch, from: caller) else { throw FileSearchError.notSearchFiles }
        let request = try FileSearchRequest(params: params)
        if let older = running[session] { await end(older, session: session, with: .superseded) }
        let call = Call(query: makeQuery())
        running[session] = call
        let now = now()
        let limit = timeLimit
        let outcome: Outcome = await withCheckedContinuation { continuation in
            call.continuation = continuation
            call.query.start(request, now: now, scope: options.scope) { failure in
                Task { await self.end(call, session: session, with: failure.map(Outcome.failed)) }
            }
            Task {
                try? await Task.sleep(for: limit)
                await self.end(call, session: session, with: nil)
            }
        }
        switch outcome {
        case .superseded:
            return []
        case .failed(let message):
            throw FileSearchError.spotlight(message)
        case .gathered(let gathered):
            let kept = gathered.filter { FileSearchFilter.keeps($0.path, options: options) }
            return Array(FileSearchRanking.rank(kept, query: request.query).prefix(request.limit))
        }
    }

    /// Ends `call` once: with `outcome`, or, when that's nil, with what its query gathered.
    private func end(_ call: Call, session: String, with outcome: Outcome?) async {
        guard let continuation = call.continuation else { return }
        call.continuation = nil
        if running[session] === call { running[session] = nil }
        switch outcome {
        case .some(let outcome):
            call.query.cancel()
            continuation.resume(returning: outcome)
        case nil:
            continuation.resume(returning: .gathered(await call.query.finish(cap: Self.readCap)))
        }
    }
}
