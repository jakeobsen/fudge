import Foundation

/// A backup of everything a user has set or made in fudge that can't be rebuilt: settings, launch permissions, the
/// search ranking, each extension's preferences and data, and the list of installed extensions (their code isn't in
/// it). `collect` gathers it from a support folder, `contents` checks an archive's entries as untrusted input, and
/// `apply` imports one.
public enum Backup {
    /// The format this fudge writes and reads; a newer one is refused.
    public static let formatVersion = 1

    /// The most extension data (`extension-data/` and `local-storage/`) a backup holds. Beyond it, the biggest
    /// extensions' data is left out, and the export says which.
    public static let dataCap = 100 * 1024 * 1024

    /// `settings.json` keys an import never takes from a backup: the Extension Store's switch and its consent
    /// (D-52), the sign-in server and its consent, whose sign-ins are in this Mac's Keychain, and clipboard history's
    /// switch and consent, whose history and key are this Mac's only. This Mac's stay as they are.
    public static let consentKeys = [
        "extensionStore", "extensionStoreConsentAt", "signInServer", "signInServerConsentAt", "clipboardHistory",
        "clipboardHistoryConsentAt",
    ]
    /// The consents themselves never go into a backup. The switch does, so an import can say the store was on.
    static let exportStrippedKeys = ["extensionStoreConsentAt", "signInServerConsentAt", "clipboardHistoryConsentAt"]

    /// Single files at the top of the support folder.
    static let rootFiles = [
        "settings.json", "launch-permissions.json", "history.json", "dropdown-values.json", "command-metadata.json",
        "quicklinks.json", "snippets.json", "colors.json",
    ]
    /// Root files that must be a JSON object to be imported.
    static let objectFiles: Set<String> = ["settings.json", "quicklinks.json", "snippets.json", "colors.json"]
    /// Of those, the ones keyed by `<extension>/…`, which an import merges extension by extension.
    static let keyedFiles: Set<String> = ["dropdown-values.json", "command-metadata.json"]
    /// Folders holding one `<extension>.json` each.
    static let perExtensionFolders = ["preferences", "local-storage", "form-values"]
    static let dataFolder = "extension-data"
    static let manifestFile = "manifest.json"

    // MARK: - What a backup says about itself

    public struct Manifest: Codable, Equatable, Sendable {
        public var format: Int
        public var fudgeVersion: String
        public var created: Date
        public var extensions: [Listed]
    }

    /// An installed extension, as the backup lists it.
    public struct Listed: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable {
            /// Installed from the Extension Store (recorded in its `installed.json`).
            case store
            /// Built from a local folder.
            case local
        }

        public var name: String
        public var title: String
        public var version: String?
        public var source: Source
        /// For an extension the Extension Store installed, the git tree id its `installed.json` records, which
        /// changes when the store updates it. `nil` for local builds, and in backups made before it was recorded.
        public var storeTree: String?
    }

    /// What a backup holds, for the export's and the import's sheets.
    public struct Summary: Equatable, Sendable {
        public var settings: Bool
        public var preferences: [String]
        public var data: [String]
        public var listed: [Listed]
        /// How many quicklinks `quicklinks.json` holds.
        public var quicklinks = 0
        /// How many snippets `snippets.json` holds.
        public var snippets = 0

        /// "Settings, 2 quicklinks, 7 extensions' preferences, 3 extensions' data, 9 installed extensions listed".
        public var text: String {
            var parts: [String] = []
            if settings { parts.append("Settings") }
            if quicklinks > 0 { parts.append(Self.count(quicklinks, "quicklink", "quicklinks")) }
            if snippets > 0 { parts.append(Self.count(snippets, "snippet", "snippets")) }
            parts.append(Self.count(preferences.count, "extension's preferences", "extensions' preferences"))
            parts.append(Self.count(data.count, "extension's data", "extensions' data"))
            parts.append(Self.count(listed.count, "installed extension listed", "installed extensions listed"))
            return parts.joined(separator: ", ")
        }

        private static func count(_ n: Int, _ one: String, _ many: String) -> String {
            "\(n) \(n == 1 ? one : many)"
        }
    }

    // MARK: - Export

    public struct Export: Sendable {
        public var manifest: Manifest
        public var entries: [BackupEntry]
        /// Extensions whose data the cap left out, biggest first.
        public var leftOut: [String]
        /// Links, files outside the support folder and anything else that isn't a regular file, not exported.
        public var skipped: Int
        public var summary: Summary
    }

    /// Gathers the backup from `paths`: only regular files inside the support folder (links are never followed),
    /// and extension data up to `dataCap`.
    public static func collect(
        from paths: FudgePaths, installed: [InstalledExtension], fudgeVersion: String, now: Date,
        dataCap: Int = dataCap
    ) -> Export {
        let support = paths.supportDirectory
        let reader = SupportReader(support: support)
        var entries: [BackupEntry] = []

        for name in rootFiles {
            guard var data = reader.file(support.appendingPathComponent(name)) else { continue }
            if name == "settings.json" { data = withoutConsent(data) }
            entries.append(BackupEntry(path: name, data: data))
        }
        var preferences: [String] = []
        for folder in ["preferences", "form-values"] {
            for (extensionName, data) in reader.perExtensionFiles(support.appendingPathComponent(folder)) {
                entries.append(BackupEntry(path: "\(folder)/\(extensionName).json", data: data))
                if folder == "preferences" { preferences.append(extensionName) }
            }
        }

        // Extension data, per extension, capped as a whole.
        var data: [String: [BackupEntry]] = [:]
        for (extensionName, file) in reader.perExtensionFiles(support.appendingPathComponent("local-storage")) {
            data[extensionName, default: []].append(
                BackupEntry(path: "local-storage/\(extensionName).json", data: file))
        }
        for (extensionName, files) in reader.dataFolders(support.appendingPathComponent(dataFolder)) {
            data[extensionName, default: []].append(contentsOf: files)
        }
        var sizes = data.mapValues { $0.reduce(0) { $0 + $1.data.count } }
        var leftOut: [String] = []
        while sizes.values.reduce(0, +) > dataCap,
            let biggest = sizes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })
        {
            leftOut.append(biggest.key)
            sizes[biggest.key] = nil
        }
        for name in sizes.keys.sorted() { entries.append(contentsOf: data[name] ?? []) }

        let listed = Self.listed(installed, paths: paths)
        let manifest = Manifest(format: formatVersion, fudgeVersion: fudgeVersion, created: now, extensions: listed)
        entries.insert(BackupEntry(path: manifestFile, data: encode(manifest)), at: 0)
        let summary = Summary(
            settings: entries.contains { $0.path == "settings.json" }, preferences: preferences.sorted(),
            data: sizes.keys.sorted(), listed: listed,
            quicklinks: Self.quicklinkCount(entries.first { $0.path == "quicklinks.json" }?.data),
            snippets: Self.snippetCount(entries.first { $0.path == "snippets.json" }?.data))
        return Export(
            manifest: manifest, entries: entries, leftOut: leftOut, skipped: reader.skipped, summary: summary)
    }

    // MARK: - Import: checking an untrusted backup

    /// Reads and checks a backup file without writing anything. Each path is checked as it's read (`part(of:)`),
    /// and the manifest's format as soon as it's read, so a backup from a newer fudge says so. A plain file (a
    /// before-import backup) takes no password; one in this support folder's `backups/` is fudge's own, and is read
    /// without the size limits (`readLimits`), since it may hold more than an export.
    public static func open(_ file: URL, password: String?, paths: FudgePaths? = nil) throws -> Contents {
        let limits = readLimits(for: file, password: password, paths: paths)
        let entries = try BackupArchive.read(
            from: file, password: password, entryLimit: limits.entry, totalLimit: limits.total,
            checkPath: { _ = try part(of: $0) },
            checkEntry: { entry in if entry.path == manifestFile { try checkFormat(entry.data) } })
        return try contents(of: entries)
    }

    /// The size limits a backup file is read with: an export's, unless it's a plain file in this support folder's
    /// own `backups/` (a before-import backup, written uncapped).
    public static func readLimits(for file: URL, password: String?, paths: FudgePaths?) -> (entry: Int, total: Int) {
        guard password == nil, let paths,
            file.resolvingSymlinksInPath().deletingLastPathComponent().path
                == paths.backupsDirectory.resolvingSymlinksInPath().path
        else { return (BackupArchive.entryLimit, BackupArchive.totalLimit) }
        return (.max, .max)
    }

    /// A checked backup: every path is one fudge writes, and every extension name is valid.
    public struct Contents: Sendable, Equatable {
        public var manifest: Manifest
        /// Top-level files by name (`settings.json`, …).
        public var root: [String: Data]
        /// `preferences/`, `local-storage/` and `form-values/` files, by folder, then extension.
        public var perExtension: [String: [String: Data]]
        /// Each extension's data folder: its files by path inside the folder.
        public var data: [String: [String: Data]]
        /// Whether the backup's settings had the Extension Store on. It isn't turned on by an import.
        public var hadExtensionStore: Bool

        public var summary: Summary {
            Summary(
                settings: root["settings.json"] != nil, preferences: (perExtension["preferences"] ?? [:]).keys.sorted(),
                data: Set(data.keys).union((perExtension["local-storage"] ?? [:]).keys).sorted(),
                listed: manifest.extensions, quicklinks: Backup.quicklinkCount(root["quicklinks.json"]),
                snippets: Backup.snippetCount(root["snippets.json"]))
        }
    }

    /// What a path in a backup is: one of the parts fudge writes, or refused.
    enum Part: Equatable {
        case manifest
        case root(String)
        case perExtension(folder: String, name: String)
        case data(name: String, path: String)
    }

    /// The part a backup path names. Anything else is refused: an absolute path, a segment that's empty, `.` or
    /// `..`, a folder or file fudge doesn't write, an invalid extension name, and the Extension Store's own folder,
    /// whose data is its clone of the store and is never imported.
    static func part(of path: String) throws -> Part {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), segments.allSatisfy(isPlainSegment) else {
            throw BackupError.refused(.path(path))
        }
        switch (segments.first ?? "", segments.count) {
        case (manifestFile, 1):
            return .manifest
        case (let name, 1) where rootFiles.contains(name):
            return .root(name)
        case (let folder, 2) where perExtensionFolders.contains(folder):
            let file = segments[1]
            guard file.hasSuffix(".json") else { throw BackupError.refused(.path(path)) }
            let name = String(file.dropLast(5))
            guard ExtensionManifest.isValidName(name) else { throw BackupError.refused(.extensionName(name)) }
            return .perExtension(folder: folder, name: name)
        case (dataFolder, 3...):
            let name = segments[1]
            guard ExtensionManifest.isValidName(name) else { throw BackupError.refused(.extensionName(name)) }
            guard name != ExtensionStore.extensionName else { throw BackupError.refused(.path(path)) }
            return .data(name: name, path: segments.dropFirst(2).joined(separator: "/"))
        default:
            throw BackupError.refused(.path(path))
        }
    }

    /// A newer format is refused as soon as its manifest is read, before its paths are judged by this format.
    static func checkFormat(_ manifest: Data) throws {
        if let format = formatOf(manifest), format > formatVersion { throw BackupError.newerFormat(format) }
    }

    /// Checks a backup's entries as untrusted input: a path fudge doesn't write, an invalid extension name, a
    /// duplicate, a `settings.json` or keyed file that isn't a JSON object, no manifest or a newer format refuses
    /// the whole backup. (Links, non-files and sizes are refused while reading, by `BackupArchive.read`.)
    public static func contents(of entries: [BackupEntry]) throws -> Contents {
        guard let manifestData = entries.first(where: { $0.path == manifestFile })?.data else {
            throw BackupError.refused(.noManifest)
        }
        try checkFormat(manifestData)
        guard let manifest = decodeManifest(manifestData) else { throw BackupError.unreadable }
        for listed in manifest.extensions where !ExtensionManifest.isValidName(listed.name) {
            throw BackupError.refused(.extensionName(listed.name))
        }
        var seen: Set<String> = []
        var root: [String: Data] = [:]
        var perExtension: [String: [String: Data]] = [:]
        var data: [String: [String: Data]] = [:]
        for entry in entries {
            guard seen.insert(entry.path).inserted else { throw BackupError.refused(.duplicate(entry.path)) }
            switch try part(of: entry.path) {
            case .manifest:
                break
            case .root(let name):
                if objectFiles.contains(name) || keyedFiles.contains(name) {
                    guard (try? JSONSerialization.jsonObject(with: entry.data)) is [String: Any] else {
                        throw BackupError.refused(.invalidPart(name))
                    }
                }
                root[name] = entry.data
            case .perExtension(let folder, let name):
                perExtension[folder, default: [:]][name] = entry.data
            case .data(let name, let path):
                data[name, default: [:]][path] = entry.data
            }
        }
        let settings = root["settings.json"].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return Contents(
            manifest: manifest, root: root, perExtension: perExtension, data: data,
            hadExtensionStore: settings?["extensionStore"] as? Bool == true)
    }

    /// The quicklinks in a `quicklinks.json`, for the summary.
    static func quicklinkCount(_ data: Data?) -> Int {
        guard let data, case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .array(let entries) = object["quicklinks"]
        else { return 0 }
        return QuicklinkStore(entries: entries).quicklinks.count
    }

    /// The snippets in a `snippets.json`, for the summary.
    static func snippetCount(_ data: Data?) -> Int {
        guard let data, case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .array(let entries) = object["snippets"]
        else { return 0 }
        return SnippetStore(entries: entries).snippets.count
    }

    /// A path segment fudge could have written: not empty, `.` or `..`, and without a NUL.
    static func isPlainSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".." && !segment.contains("\0")
    }

    // MARK: - Import: what changed since the backup

    /// An extension the backup lists that's installed now, but not as the backup recorded it. The import summary
    /// only says so: the import restores its settings and data like any other's, and an extension that
    /// updated does its own migration.
    public struct Changed: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// Both have a version, and they differ.
            case version(backup: String, now: String)
            /// Both were installed from the Extension Store, from different trees.
            case storeUpdated
            /// Installed from the other source now.
            case source(now: Listed.Source)
        }

        public var name: String
        /// The current install's title.
        public var title: String
        public var reason: Reason

        /// "version 1.2.0 in the backup, 1.3.0 now".
        public var text: String {
            switch reason {
            case .version(let backup, let now): "version \(backup) in the backup, \(now) now"
            case .storeUpdated: "updated in the Extension Store since the backup"
            case .source(.local): "installed from a local folder now"
            case .source(.store): "installed from the Extension Store now"
            }
        }
    }

    /// The backup's extensions that are installed now but changed since it was made, sorted by title. They're
    /// matched by name, and the first rule that applies says why: a different version when both have one, a
    /// different Extension Store tree when both have one, or a different source. What it can't tell isn't listed,
    /// and neither is the bundled Extension Store, nor an extension that isn't installed (the import lists those).
    public static func changedExtensions(
        _ contents: Contents, installed: [InstalledExtension], paths: FudgePaths
    ) -> [Changed] {
        let current = Dictionary(
            listed(installed, paths: paths).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return contents.manifest.extensions.compactMap { backup in
            guard backup.name != ExtensionStore.extensionName, seen.insert(backup.name).inserted,
                let now = current[backup.name], let reason = changeReason(from: backup, to: now)
            else { return nil }
            return Changed(name: backup.name, title: now.title, reason: reason)
        }
        .sorted { first, second in
            let order = first.title.localizedStandardCompare(second.title)
            return order == .orderedSame ? first.name < second.name : order == .orderedAscending
        }
    }

    /// Why `now` differs from what the backup listed, by the first rule that applies, or `nil` when it can't tell.
    static func changeReason(from backup: Listed, to now: Listed) -> Changed.Reason? {
        if let then = backup.version, let current = now.version, then != current {
            return .version(backup: then, now: current)
        }
        if let then = backup.storeTree, let current = now.storeTree, then != current { return .storeUpdated }
        if backup.source != now.source { return .source(now: now.source) }
        return nil
    }

    // MARK: - Import: applying it

    public struct ImportResult: Sendable, Equatable {
        /// The before-import backup of what was there.
        public var beforeImport: URL
        /// The backup's extensions that aren't installed here, to reinstall.
        public var notInstalled: [Listed]
        public var hadExtensionStore: Bool
    }

    /// How an import writes a file. Tests inject failures through it.
    public struct FileWriter: Sendable {
        public var write: @Sendable (Data, URL) throws -> Void

        public init(write: @escaping @Sendable (Data, URL) throws -> Void) {
            self.write = write
        }

        public static let atomic = FileWriter { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// The before-import backups kept in `backups/`; older ones are deleted.
    public static let beforeImportKept = 3

    /// Imports `contents` into `paths`. First it writes the current state to a before-import backup. Then each part
    /// the backup holds replaces the same part here; parts it doesn't hold, and other extensions' data, are left
    /// alone. `settings.json` keeps this Mac's Extension Store consent, and the keyed files are merged extension by
    /// extension. If a write fails, everything changed so far is put back.
    public static func apply(
        _ contents: Contents, to paths: FudgePaths, installed: [InstalledExtension], fudgeVersion: String, now: Date,
        writer: FileWriter = .atomic
    ) throws -> ImportResult {
        let support = paths.supportDirectory
        let beforeImport = try writeBeforeImport(
            paths: paths, installed: installed, fudgeVersion: fudgeVersion, now: now)

        var changes: [(URL, Data)] = []
        for (name, imported) in contents.root.sorted(by: { $0.key < $1.key }) {
            let file = support.appendingPathComponent(name)
            let current = try? Data(contentsOf: file)
            switch name {
            case "settings.json": changes.append((file, settings(imported, keepingConsentOf: current)))
            case let keyed where keyedFiles.contains(keyed): changes.append((file, merged(imported, into: current)))
            default: changes.append((file, imported))
            }
        }
        for (folder, files) in contents.perExtension.sorted(by: { $0.key < $1.key }) {
            for (name, data) in files.sorted(by: { $0.key < $1.key }) {
                changes.append((support.appendingPathComponent("\(folder)/\(name).json"), data))
            }
        }

        let staging = support.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        var undo: [() throws -> Void] = []
        do {
            for (file, data) in changes {
                let old = try? Data(contentsOf: file)
                try writer.write(data, file)
                undo.append {
                    if let old { try writer.write(old, file) } else { try FileManager.default.removeItem(at: file) }
                }
            }
            for (name, files) in contents.data.sorted(by: { $0.key < $1.key }) {
                let target = support.appendingPathComponent("\(dataFolder)/\(name)", isDirectory: true)
                let fresh = staging.appendingPathComponent("new/\(name)", isDirectory: true)
                let old = staging.appendingPathComponent("old/\(name)", isDirectory: true)
                for (path, data) in files.sorted(by: { $0.key < $1.key }) {
                    try writer.write(data, fresh.appendingPathComponent(path))
                }
                let manager = FileManager.default
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
                let hadOld = manager.fileExists(atPath: target.path)
                if hadOld { try manager.moveItem(at: target, to: old) }
                do {
                    try manager.moveItem(at: fresh, to: target)
                } catch {
                    if hadOld { try? manager.moveItem(at: old, to: target) }
                    throw error
                }
                undo.append {
                    try manager.removeItem(at: target)
                    if hadOld { try manager.moveItem(at: old, to: target) }
                }
            }
        } catch {
            // Every step is tried, even after one fails. If any did, the staging folder stays: it may hold an
            // extension's old data that couldn't be moved back.
            var restored = true
            for step in undo.reversed() {
                do { try step() } catch { restored = false }
            }
            guard restored else { throw BackupError.restoreFailed(beforeImport: beforeImport.path) }
            try? FileManager.default.removeItem(at: staging)
            throw BackupError.importFailed(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: staging)

        let installedNames = Set(installed.map(\.manifest.name))
        return ImportResult(
            beforeImport: beforeImport,
            notInstalled: contents.manifest.extensions.filter { !installedNames.contains($0.name) },
            hadExtensionStore: contents.hadExtensionStore)
    }

    /// Writes the current state, uncapped and unencrypted, to `backups/before-import-<time>.fudgebackup` (folder
    /// 0700, file 0600), keeping the last `beforeImportKept`.
    static func writeBeforeImport(
        paths: FudgePaths, installed: [InstalledExtension], fudgeVersion: String, now: Date
    ) throws -> URL {
        let folder = paths.backupsDirectory
        let manager = FileManager.default
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        let file = folder.appendingPathComponent("before-import-\(formatter.string(from: now)).fudgebackup")
        let current = collect(
            from: paths, installed: installed, fudgeVersion: fudgeVersion, now: now, dataCap: .max)
        try BackupArchive.write(current.entries, to: file, password: nil)
        let kept = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("before-import-") && $0.hasSuffix(".fudgebackup") }
            .sorted()
        // The one just written always stays, even if the clock was set back and it sorts first.
        for old in kept.filter({ $0 != file.lastPathComponent }).dropLast(beforeImportKept - 1) {
            try? manager.removeItem(at: folder.appendingPathComponent(old))
        }
        return file
    }

    // MARK: - Pieces

    /// `settings.json` without the Extension Store's consent.
    static func withoutConsent(_ data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        for key in exportStrippedKeys { object[key] = nil }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? data
    }

    /// The imported settings, with this Mac's consent keys as they are (and none of the backup's).
    static func settings(_ imported: Data, keepingConsentOf current: Data?) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: imported) as? [String: Any] else { return imported }
        let here = current.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for key in consentKeys { object[key] = here[key] }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? imported
    }

    /// A file keyed by `<extension>/…`: the imported entries replace those of the same extensions here, and the
    /// other extensions' entries stay.
    static func merged(_ imported: Data, into current: Data?) -> Data {
        guard let incoming = try? JSONSerialization.jsonObject(with: imported) as? [String: Any] else {
            return imported
        }
        var object = current.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func extensionOf(_ key: String) -> Substring { key.split(separator: "/").first ?? Substring(key) }
        let replaced = Set(incoming.keys.map(extensionOf))
        object = object.filter { !replaced.contains(extensionOf($0.key)) }
        object.merge(incoming) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? imported
    }

    /// The installed extensions as a backup lists them, by name: each one's source, and for the Extension Store's
    /// installs the tree it recorded.
    static func listed(_ installed: [InstalledExtension], paths: FudgePaths) -> [Listed] {
        let store = storeInstalls(paths)
        return installed.map { installed in
            let record = store[installed.manifest.name]
            return Listed(
                name: installed.manifest.name, title: installed.manifest.title, version: installed.manifest.version,
                source: record == nil ? .local : .store, storeTree: record?.tree)
        }
        .sorted { $0.name < $1.name }
    }

    /// One of the Extension Store's installs, as its `installed.json` records it.
    struct StoreInstall: Equatable {
        /// The git tree id of the extension's folder when it was installed, if the record has one.
        var tree: String?
    }

    /// What the Extension Store recorded as its installs (`installed.json`: `{ "<name>": { "tree", "commit",
    /// "installedAt" } }`), by name. A missing or broken file reads as none.
    static func storeInstalls(_ paths: FudgePaths) -> [String: StoreInstall] {
        let file = paths.supportDirectory(forExtension: ExtensionStore.extensionName)
            .appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var installs: [String: StoreInstall] = [:]
        for (name, record) in object where ExtensionManifest.isValidName(name) {
            installs[name] = StoreInstall(tree: (record as? [String: Any])?["tree"] as? String)
        }
        return installs
    }

    static func encode(_ manifest: Manifest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(manifest)) ?? Data()
    }

    static func decodeManifest(_ data: Data) -> Manifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    static func formatOf(_ data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? Int
    }
}

/// Reads the support folder for an export: regular files only, never through a link, and only inside the folder.
/// Everything else is counted in `skipped`.
private final class SupportReader {
    let support: URL
    let realSupport: String
    private(set) var skipped = 0

    init(support: URL) {
        self.support = support
        realSupport = support.resolvingSymlinksInPath().path
    }

    /// The file's bytes, if it's a regular file whose real path is inside the support folder. A missing file isn't
    /// counted as skipped.
    func file(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else {
            return nil
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true,
            url.resolvingSymlinksInPath().path.hasPrefix(realSupport + "/"),
            let data = try? Data(contentsOf: url)
        else {
            skipped += 1
            return nil
        }
        return data
    }

    /// A folder's `<extension>.json` files with valid names, sorted by name.
    func perExtensionFiles(_ folder: URL) -> [(String, Data)] {
        guard isPlainFolder(folder) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { file in
            guard file.hasSuffix(".json") else { return nil }
            let name = String(file.dropLast(5))
            guard ExtensionManifest.isValidName(name), let data = self.file(folder.appendingPathComponent(file)) else {
                return nil
            }
            return (name, data)
        }
    }

    /// Each extension's data folder: its files as backup entries, sorted. The Extension Store's is left out: its
    /// data is its clone of the store, and a backup never carries or imports it.
    func dataFolders(_ folder: URL) -> [(String, [BackupEntry])] {
        guard isPlainFolder(folder) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard ExtensionManifest.isValidName(name), name != ExtensionStore.extensionName else { return nil }
            let root = folder.appendingPathComponent(name, isDirectory: true)
            guard isPlainFolder(root) else { return nil }
            var entries: [BackupEntry] = []
            walk(root, relative: []) { relative, data in
                entries.append(
                    BackupEntry(path: "\(Backup.dataFolder)/\(name)/\(relative.joined(separator: "/"))", data: data))
            }
            return (name, entries)
        }
    }

    /// Whether `url` is a real folder (not a link to one). A link is counted as skipped; a missing folder isn't.
    private func isPlainFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            return false
        }
        if values.isSymbolicLink == true || values.isDirectory != true {
            skipped += 1
            return false
        }
        return url.resolvingSymlinksInPath().path.hasPrefix(realSupport + "/")
    }

    private func walk(_ folder: URL, relative: [String], _ visit: ([String], Data) -> Void) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() {
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
                continue
            }
            if values.isSymbolicLink != true, values.isDirectory == true {
                walk(url, relative: relative + [name], visit)
            } else if let data = file(url) {
                visit(relative + [name], data)
            }
        }
    }
}
