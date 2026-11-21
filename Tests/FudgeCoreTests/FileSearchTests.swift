import Foundation
import Testing

@testable import FudgeCore

private let home = "/Users/someone"
private let day: TimeInterval = 24 * 60 * 60
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func file(
    _ path: String, modified: Date = now.addingTimeInterval(-day), lastUsed: Date? = nil, isFolder: Bool = false
) -> FoundFile {
    FoundFile(
        path: path, name: (path as NSString).lastPathComponent, kind: isFolder ? "Folder" : "Document",
        isFolder: isFolder, size: isFolder ? nil : 1024, modified: modified, lastUsed: lastUsed)
}

// MARK: - The call and the preferences

@Test func aCallTakesAQueryAndALimitOf200ByDefaultAndAt500AtMost() throws {
    #expect(try FileSearchRequest(params: .object(["query": .string("  report ")])) == .init(query: "report"))
    #expect(try FileSearchRequest(params: .object(["query": .string("a")])).limit == 200)
    #expect(try FileSearchRequest(params: .object(["query": .string("a"), "limit": .number(9000)])).limit == 500)
    #expect(try FileSearchRequest(params: .object(["query": .string("a"), "limit": .number(0)])).limit == 1)
    #expect(try FileSearchRequest(params: .object(["query": .string("a"), "limit": .null])).limit == 200)
    #expect(throws: FileSearchError.self) { try FileSearchRequest(params: .object([:])) }
    #expect(throws: FileSearchError.self) {
        try FileSearchRequest(params: .object(["query": .string("a"), "limit": .string("10")]))
    }
    #expect(FileSearchRequest(query: "q1  budget\treport").words == ["q1", "budget", "report"])
}

@Test func thePreferencesSayWhereToSearch() {
    let defaults = FileSearchOptions(preferences: [:], home: home + "/")
    #expect(defaults == FileSearchOptions(scope: .home, leaveOut: [], home: home))

    let options = FileSearchOptions(
        preferences: [
            "searchIn": .string("mac"),
            "leaveOut": .string(" ~/Library, /Volumes/Backup/ ,, relative/folder, ~ , ~other"),
        ],
        home: home)
    #expect(options.scope == .mac)
    #expect(options.leaveOut == [home + "/Library", "/Volumes/Backup", home], "relative and `~user` paths are skipped")
    #expect(FileSearchOptions(preferences: ["searchIn": .string("everywhere")], home: home).scope == .home)
}

// MARK: - The predicate

@Test func everyWordMustBeInTheNameMatchingLiterally() {
    #expect(FileSearchPredicate.pattern("report") == "*report*")
    #expect(FileSearchPredicate.pattern(#"a*b?c\d"#) == #"*a\*b\?c\\d*"#)
    #expect(FileSearchPredicate.pattern(#"say "hi""#) == #"*say "hi"*"#, "quotes go in an argument, so they stay")

    let one = FileSearchPredicate.make(FileSearchRequest(query: "report"), now: now)
    #expect(one.predicateFormat == #"kMDItemFSName LIKE[cd] "*report*""#)
    let two = FileSearchPredicate.make(FileSearchRequest(query: "q1 rep*rt"), now: now)
    #expect(two.predicateFormat == #"kMDItemFSName LIKE[cd] "*q1*" AND kMDItemFSName LIKE[cd] "*rep\\*rt*""#)
}

@Test func anEmptyQueryAsksForWhatWasUsedInTheLast30Days() throws {
    let predicate = try #require(
        FileSearchPredicate.make(FileSearchRequest(query: "  "), now: now) as? NSComparisonPredicate)
    #expect(predicate.leftExpression.keyPath == "kMDItemLastUsedDate")
    #expect(predicate.predicateOperatorType == .greaterThanOrEqualTo)
    #expect(predicate.rightExpression.constantValue as? Date == now.addingTimeInterval(-30 * day))
}

// MARK: - What's left out

@Test func resultsOutsideTheScopeUnderLeaveOutHiddenOrInsideAPackageAreLeftOut() {
    let options = FileSearchOptions(scope: .home, leaveOut: [home + "/Library", home + "/Archive"], home: home)
    func keeps(_ path: String, _ options: FileSearchOptions = options) -> Bool {
        FileSearchFilter.keeps(path, options: options)
    }
    #expect(keeps(home + "/Documents/report.pdf"))
    #expect(!keeps("/Applications/Report.app"), "outside the home folder")
    #expect(keeps("/Applications/Report.app", FileSearchOptions(scope: .mac, home: home)), "This Mac")

    #expect(!keeps(home + "/Library/Caches/report.pdf"))
    #expect(!keeps(home + "/library/report.pdf"), "ignoring case, as the file system does")
    #expect(!keeps(home + "/Archive"), "the folder itself")
    #expect(keeps(home + "/Archives/report.pdf"), "only inside the folder, not a longer name")

    #expect(!keeps(home + "/.config/report.pdf"))
    #expect(!keeps(home + "/Documents/.report.pdf"))
    #expect(keeps(home + "/Documents/report.v2.pdf"))

    #expect(keeps(home + "/Applications/Report.app"), "a package itself is a result")
    #expect(!keeps(home + "/Applications/Report.app/Contents/Info.plist"))
    #expect(!keeps(home + "/Pictures/Photos Library.photoslibrary/originals/IMG_1.heic"))
    #expect(!keeps(home + "/Code/Thing.bundle/Contents/Resources/report.pdf"))
    #expect(keeps(home + "/Code/thing.app.notes/report.pdf"), "an extension that isn't a package's")
}

@Test func packagesAreKnownByTheirExtension() {
    #expect(FileSearchFilter.isPackage("Report.app"))
    #expect(FileSearchFilter.isPackage("Photos Library.photoslibrary"))
    #expect(FileSearchFilter.isPackage("Thing.BUNDLE"))
    #expect(!FileSearchFilter.isPackage("Documents"))
    #expect(!FileSearchFilter.isPackage("report.pdf"))
}

// MARK: - Ranking

@Test func theNameMatchingTheQueryBestComesFirst() {
    let files = [
        file(home + "/a/annual report summary.pdf"),  // 3: a word starts with it
        file(home + "/a/myreport.txt"),  // 4: anywhere
        file(home + "/a/Report draft.pages"),  // 2: the name starts with it
        file(home + "/a/REPORT.pdf"),  // 1: equal without the extension
        file(home + "/a/réport"),  // 1: equal, diacritics ignored
    ]
    let ranked = FileSearchRanking.rank(files, query: "report").map(\.name)
    #expect(ranked == ["réport", "REPORT.pdf", "Report draft.pages", "annual report summary.pdf", "myreport.txt"])
}

@Test func tiesGoToTheMostRecentlyUsedThenModifiedThenTheShorterPath() {
    let files = [
        file(home + "/b/longer/notes.txt"),
        file(home + "/b/notes.txt"),
        file(home + "/c/notes.txt", modified: now),
        file(home + "/d/notes.txt", lastUsed: now.addingTimeInterval(-3 * day)),
        file(home + "/e/notes.txt", lastUsed: now.addingTimeInterval(-day)),
    ]
    #expect(
        FileSearchRanking.rank(files, query: "notes").map(\.path) == [
            home + "/e/notes.txt", home + "/d/notes.txt", home + "/c/notes.txt", home + "/b/notes.txt",
            home + "/b/longer/notes.txt",
        ])
    #expect(
        FileSearchRanking.rank(files, query: "").map(\.path).prefix(2) == [
            home + "/e/notes.txt", home + "/d/notes.txt",
        ],
        "no query: the most recently used first")
}

// MARK: - Spotlight's results

@Test func aSpotlightResultIsReadAndAnsweredWithDatesAsDateMarkers() throws {
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    let attributes: [String: Any] = [
        NSMetadataItemPathKey: home + "/Documents/report.pdf", NSMetadataItemFSNameKey: "report.pdf",
        NSMetadataItemKindKey: "PDF document", NSMetadataItemContentTypeTreeKey: ["com.adobe.pdf", "public.data"],
        NSMetadataItemFSSizeKey: NSNumber(value: 52_000), "kMDItemContentModificationDate": modified,
    ]
    let found = try #require(FoundFile(attribute: { attributes[$0] }))
    #expect(
        found
            == FoundFile(
                path: home + "/Documents/report.pdf", name: "report.pdf", kind: "PDF document", size: 52_000,
                modified: modified))
    #expect(
        found.json
            == .object([
                "path": .string(home + "/Documents/report.pdf"), "name": .string("report.pdf"),
                "kind": .string("PDF document"), "isFolder": .bool(false), "size": .number(52_000),
                "modified": .object(["$date": .string("2023-11-14T22:13:20.000Z")]),
            ]))

    let folder: [String: Any] = [
        NSMetadataItemPathKey: home + "/Projects", NSMetadataItemContentTypeTreeKey: ["public.folder", "public.item"],
        NSMetadataItemFSSizeKey: NSNumber(value: 64), NSMetadataItemFSContentChangeDateKey: modified,
        NSMetadataItemLastUsedDateKey: now,
    ]
    let read = try #require(FoundFile(attribute: { folder[$0] }))
    #expect(read.isFolder && read.size == nil && read.name == "Projects" && read.lastUsed == now)
    #expect(FoundFile(json: read.json, home: home) == read, "snapshots read the same shape back")
    #expect(FoundFile(attribute: { [NSMetadataItemPathKey: "/x"][$0] }) == nil, "no modification date")
}

@Test func aFixedResultsPathMayStartInTheHomeFolder() {
    let json: JSONValue = .object([
        "path": .string("~/Documents/Plan.key"), "kind": .string("Keynote"), "size": .number(10),
        "modified": .object(["$date": .string("2026-01-02T03:04:05Z")]),
    ])
    let found = FoundFile(json: json, home: home)
    #expect(found?.path == home + "/Documents/Plan.key" && found?.name == "Plan.key" && found?.size == 10)
}

// MARK: - Running a search

/// A Spotlight query that answers with fixed results, finishing at once, never, or failing.
private final class FakeQuery: FileMetadataQuery, @unchecked Sendable {
    enum Behaviour {
        case finishes, neverFinishes
        case fails(String)
    }
    private let lock = NSLock()
    let files: [FoundFile]
    let behaviour: Behaviour
    private var _started: (request: FileSearchRequest, scope: FileSearchScope)?
    private var _cap: Int?
    private var _cancelled = false

    init(_ files: [FoundFile], _ behaviour: Behaviour = .finishes) {
        self.files = files
        self.behaviour = behaviour
    }

    var started: (request: FileSearchRequest, scope: FileSearchScope)? { lock.withLock { _started } }
    var cap: Int? { lock.withLock { _cap } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func start(
        _ request: FileSearchRequest, now: Date, scope: FileSearchScope,
        finished: @escaping @Sendable (_ failure: String?) -> Void
    ) {
        lock.withLock { _started = (request, scope) }
        switch behaviour {
        case .finishes: finished(nil)
        case .neverFinishes: break
        case .fails(let message): finished(message)
        }
    }

    func finish(cap: Int) async -> [FoundFile] {
        lock.withLock { _cap = cap }
        return files
    }

    func cancel() { lock.withLock { _cancelled = true } }
}

/// Hands out the given queries in order, and remembers them.
private final class Queries: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [FakeQuery]
    private(set) var made: [FakeQuery] = []
    init(_ queries: [FakeQuery]) { waiting = queries }
    func next() -> FileMetadataQuery {
        lock.withLock {
            let query = waiting.removeFirst()
            made.append(query)
            return query
        }
    }
    var count: Int { lock.withLock { made.count } }
}

private func params(_ query: String, limit: Int? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["query": .string(query)]
    if let limit { object["limit"] = .number(Double(limit)) }
    return .object(object)
}

private let homeOptions = FileSearchOptions(scope: .home, leaveOut: [home + "/Library"], home: home)

@Test func onlySearchFilesMayCall() async throws {
    let queries = Queries([FakeQuery([])])
    let search = FileSearch(makeQuery: queries.next)
    for caller in ["weather", "fudge-extension-store", nil] as [String?] {
        await #expect(throws: FileSearchError.notSearchFiles) {
            try await search.search(params("x"), options: homeOptions, session: "s-1", caller: caller)
        }
    }
    await #expect(throws: FileSearchError.notSearchFiles, "refused before its params are read") {
        try await search.search(.null, options: homeOptions, session: "s-1", caller: "weather")
    }
    #expect(queries.count == 0, "Spotlight isn't asked")
    #expect(FileSearchError.notSearchFiles.description == "files.search is only for Fudge's Search Files.")
}

@Test func aSearchAsksInTheScopeLeavesOutRanksAndCuts() async throws {
    let query = FakeQuery([
        file(home + "/Library/report.pdf"), file(home + "/x/.hidden/report.pdf"), file(home + "/x/my report.pdf"),
        file(home + "/x/report.pdf"),
    ])
    let queries = Queries([query])
    let search = FileSearch(makeQuery: queries.next)
    let found = try await search.search(
        params("report", limit: 1), options: homeOptions, session: "s-1", caller: FileSearch.extensionName)
    #expect(found.map(\.path) == [home + "/x/report.pdf"])
    #expect(query.started?.request == FileSearchRequest(query: "report", limit: 1))
    #expect(query.started?.scope == .home)
    #expect(query.cap == FileSearch.readCap, "everything up to the cap is read, not just the limit")
}

@Test func everythingGatheredIsRankedBeforeTheLimitCutsIt() async throws {
    // Spotlight answers unordered: the exact match comes last of 600.
    var files = (0..<600).map { file(home + "/docs/budget notes \($0).txt", lastUsed: now) }
    files[599] = file(home + "/docs/budget.xlsx")
    let search = FileSearch(makeQuery: Queries([FakeQuery(files)]).next)
    let found = try await search.search(
        params("budget", limit: 200), options: homeOptions, session: "s-1", caller: FileSearch.extensionName)
    #expect(found.count == 200)
    #expect(found.first?.name == "budget.xlsx")
}

@Test func aNewerCallFromTheSameSessionStopsTheOlderOne() async throws {
    let older = FakeQuery([file(home + "/old.txt")], .neverFinishes)
    let newer = FakeQuery([file(home + "/new.txt")])
    let other = FakeQuery([file(home + "/other.txt")])
    let queries = Queries([older, other, newer])
    let search = FileSearch(timeLimit: .seconds(60), makeQuery: queries.next)
    let caller = FileSearch.extensionName

    let first = Task { try await search.search(params("o"), options: homeOptions, session: "s-1", caller: caller) }
    let deadline = ContinuousClock.now + .seconds(30)
    while queries.count < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }

    // Another session's call doesn't touch it.
    let elsewhere = try await search.search(params("o"), options: homeOptions, session: "s-2", caller: caller)
    #expect(elsewhere.map(\.name) == ["other.txt"])
    #expect(!older.cancelled)

    let second = try await search.search(params("n"), options: homeOptions, session: "s-1", caller: caller)
    #expect(try await first.value == [], "the older call answers nothing")
    #expect(older.cancelled, "and its query is stopped")
    #expect(older.cap == nil, "without reading its results")
    #expect(second.map(\.name) == ["new.txt"])
}

@Test func aSearchAnswersWithWhatItHasAfterTheTimeLimit() async throws {
    #expect(FileSearch.defaultTimeLimit == .milliseconds(1500))
    let slow = FakeQuery([file(home + "/slow.txt")], .neverFinishes)
    let search = FileSearch(timeLimit: .milliseconds(100), makeQuery: Queries([slow]).next)
    let started = ContinuousClock.now
    let found = try await search.search(
        params("slow"), options: homeOptions, session: "s-1", caller: FileSearch.extensionName)
    let elapsed = ContinuousClock.now - started
    #expect(found.map(\.name) == ["slow.txt"])
    #expect(elapsed >= .milliseconds(100))
    #expect(elapsed < .seconds(30))
}

@Test func spotlightFailingIsTheCallsError() async throws {
    let search = FileSearch(makeQuery: Queries([FakeQuery([], .fails("Spotlight is off."))]).next)
    await #expect(throws: FileSearchError.spotlight("Spotlight is off.")) {
        try await search.search(params("x"), options: homeOptions, session: "s-1", caller: FileSearch.extensionName)
    }
}

// MARK: - Bundling

@Test func searchFilesIsBundledAlongsideTheStoreAndEnabledByDefault() throws {
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let resources = try Fixtures.temporaryDirectory()
    func write(_ name: String, title: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest =
            #"{ "name": "\#(name)", "title": "\#(title)", "commands": [ { "name": "main", "title": "\#(title)", "mode": "view" } ] }"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("package.json"))
    }
    try write(
        ExtensionStore.extensionName, title: "Extension Store", in: resources.appendingPathComponent("store-extension"))
    try write(
        FileSearch.extensionName, title: "Search Files", in: resources.appendingPathComponent("file-search-extension"))
    try write("fudge-emoji", title: "Search Emoji & Symbols", in: resources.appendingPathComponent("emoji-extension"))
    try write(
        FileSearch.extensionName, title: "Impostor", in: paths.extensionsDirectory.appendingPathComponent("impostor"))
    try write("weather", title: "Weather", in: paths.extensionsDirectory.appendingPathComponent("weather"))

    #expect(BundledExtensions.folders == ["store-extension", "file-search-extension", "emoji-extension"])
    let installed = InstalledExtension.all(paths: paths, resources: resources)
    #expect(
        installed.map(\.manifest.title) == ["Extension Store", "Search Emoji & Symbols", "Search Files", "Weather"],
        "the impostor gives way")
    let settings = FudgeSettings()
    #expect(settings.isEnabled(extension: FileSearch.extensionName), "unlike the store")
    #expect(settings.isEnabled(extension: "fudge-emoji"))
    #expect(!settings.isEnabled(extension: ExtensionStore.extensionName))
}

@Test func theHomeFolderIsTheOneTheExtensionSees() {
    #expect(FileSearchOptions.home(environment: ["HOME": "/tmp/someone"]) == "/tmp/someone", "Node's os.homedir() too")
    #expect(FileSearchOptions.home(environment: [:]) == NSHomeDirectory())
    #expect(FileSearchOptions.home(environment: ["HOME": ""]) == NSHomeDirectory())
}
