import Foundation

/// How much goes into the log files (SPEC-124): each level records its own lines and every level above it. The
/// `logLevel` setting, Errors by default.
public enum LogLevel: String, Sendable, CaseIterable, Codable {
    case error, warning, info, debug

    public static let `default`: LogLevel = .error

    /// The Log level picker's titles.
    public var title: String {
        switch self {
        case .error: "Errors"
        case .warning: "Warnings"
        case .info: "Info"
        case .debug: "Debug"
        }
    }

    /// `logLevel` in `settings.json`; anything else reads as the default.
    public init(settingsValue value: Any?) {
        self = (value as? String).flatMap(Self.init(rawValue:)) ?? .default
    }

    /// The `settings.json` value: nil for the default, which isn't written.
    public var settingsValue: String? { self == .default ? nil : rawValue }

    /// Whether a line at `line` goes into the files while this is the setting.
    public func records(_ line: LogLevel) -> Bool {
        Self.allCases.firstIndex(of: line)! <= Self.allCases.firstIndex(of: self)!
    }
}

/// A log file: Fudge's own, or one extension's, by its manifest `name`.
public enum LogFile: Hashable, Sendable {
    case fudge
    case extensionNamed(String)

    /// `Fudge.log`, or `Extensions/<name>.log`; nil for a name that isn't a valid extension name, which never names
    /// a file.
    public func url(in folder: URL) -> URL? {
        switch self {
        case .fudge:
            folder.appendingPathComponent("Fudge.log")
        case .extensionNamed(let name):
            ExtensionManifest.isValidName(name)
                ? folder.appendingPathComponent("Extensions", isDirectory: true).appendingPathComponent("\(name).log")
                : nil
        }
    }

    /// Past this size the file becomes `<name>.old.log` and a new one starts.
    public var cap: Int {
        switch self {
        case .fudge: 5_000_000
        case .extensionNamed: 1_000_000
        }
    }

    /// `<name>.old.log` beside `file`.
    static func old(_ file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("old.log")
    }
}

/// One line of a log file: a local timestamp with its offset (ISO 8601, milliseconds), the level, the command's name
/// for an extension's line, and the message, its further lines indented under the first.
public enum LogLine {
    public static func format(
        date: Date, level: LogLevel, command: String? = nil, message: String, timeZone: TimeZone = .current
    ) -> String {
        var text = message
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        let rest = lines.dropFirst().map { "    \($0)" }
        let named = command.map { "[\($0)] " } ?? ""
        return ([timestamp(date, timeZone: timeZone) + " \(level.rawValue) \(named)\(first)"] + rest)
            .joined(separator: "\n") + "\n"
    }

    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

/// Writes log lines to their files, never on the caller's thread (SPEC-124 §4).
///
/// Lines wait in a bounded buffer per file and are written in the order they came, on a serial queue of the
/// writer's own. A file whose buffer is full drops further lines and counts them, and one `… N lines dropped` line
/// follows when the buffer drains; other files are unaffected. Past its cap a file becomes `<name>.old.log`
/// (replacing the last one) and a new one starts. A failed write never reaches the user: the next line tries again,
/// and only stderr gets a note. Only the app writes these files.
public final class LogWriter: @unchecked Sendable {
    /// The folder the files are in (`FudgePaths.logsDirectory`).
    public let folder: URL
    private let header: String?
    private let pendingLimit: Int
    private let caps: [LogFile: Int]
    private let timeZone: TimeZone
    /// Where the files are written; tests pass a suspended queue to stand in for a slow disk.
    private let queue: DispatchQueue
    private let lock = NSLock()

    private struct Entry {
        let date: Date
        let level: LogLevel
        let command: String?
        let message: String
    }

    /// Guarded by `lock`: what waits to be written, what was dropped, and whether a drain is on its way.
    private var pending: [LogFile: [Entry]] = [:]
    private var order: [LogFile] = []
    private var dropped: [LogFile: Int] = [:]
    private var draining = false
    /// On `queue`: the files this run has written to, which got the header first.
    private var started: Set<LogFile> = []
    private var sizes: [LogFile: Int] = [:]

    /// `header` goes before the first line each file gets in this run (Fudge's version and commit). `pendingLimit`
    /// lines wait per file at most: two seconds of the host's 1,000 lines a second per command. `caps` overrides `LogFile.cap`, for tests.
    public init(
        folder: URL, header: String?, pendingLimit: Int = 2000, caps: [LogFile: Int] = [:],
        timeZone: TimeZone = .current, queue: DispatchQueue = DispatchQueue(label: "io.github.jakeobsen.fudge.logs")
    ) {
        self.queue = queue
        self.folder = folder
        self.header = header
        self.pendingLimit = pendingLimit
        self.caps = caps
        self.timeZone = timeZone
    }

    /// Queues a line for `file`, stamped now.
    public func write(_ level: LogLevel, _ message: String, command: String? = nil, to file: LogFile) {
        let entry = Entry(date: Date(), level: level, command: command, message: message)
        let startDrain = lock.withLock {
            if pending[file] == nil { order.append(file) }
            if pending[file, default: []].count >= pendingLimit {
                dropped[file, default: 0] += 1
            } else {
                pending[file, default: []].append(entry)
            }
            defer { draining = true }
            return !draining
        }
        if startDrain { queue.async { self.drain() } }
    }

    /// Waits until every line queued so far has been written: for tests, and quitting.
    public func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            let batch: [(LogFile, [Entry], Int)] = lock.withLock {
                let batch = order.map { ($0, pending[$0] ?? [], dropped[$0] ?? 0) }
                pending = [:]
                order = []
                dropped = [:]
                if batch.isEmpty { draining = false }
                return batch
            }
            if batch.isEmpty { return }
            for (file, entries, droppedCount) in batch {
                var text = entries.map {
                    LogLine.format(
                        date: $0.date, level: $0.level, command: $0.command, message: $0.message, timeZone: timeZone)
                }
                if droppedCount > 0 {
                    let noun = droppedCount == 1 ? "line" : "lines"
                    text.append(
                        LogLine.format(
                            date: Date(), level: .warning, message: "… \(droppedCount) \(noun) dropped",
                            timeZone: timeZone))
                }
                append(text.joined(), to: file)
            }
        }
    }

    /// On `queue`.
    private func append(_ text: String, to file: LogFile) {
        guard let url = file.url(in: folder) else { return }
        var text = text
        if !started.contains(file), let header {
            text = LogLine.format(date: Date(), level: .info, message: header, timeZone: timeZone) + text
        }
        let data = Data(text.utf8)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var size = try sizes[file] ?? currentSize(of: url)
            if size > 0, size + data.count > caps[file] ?? file.cap {
                let old = LogFile.old(url)
                try? manager.removeItem(at: old)
                try manager.moveItem(at: url, to: old)
                size = 0
            }
            if !manager.fileExists(atPath: url.path) {
                guard manager.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            size = Int(try handle.seekToEnd())
            try handle.write(contentsOf: data)
            sizes[file] = size + data.count
            started.insert(file)
        } catch {
            sizes[file] = nil
            FileHandle.standardError.write(Data("fudge: couldn't write \(url.path): \(error)\n".utf8))
        }
    }

    private func currentSize(of url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

/// Fudge's own log lines, and the one place they're written (SPEC-124 §2): stderr, as before, so `make run` from a
/// terminal still shows them, and `Fudge.log` once the app has started the writer. Errors and warnings always go to
/// stderr; the file, and stderr for info and debug, follow the Log level. With no writer (tests, the `fudge` tool),
/// nothing is written to any file.
///
/// Never log what the user types, clipboard or snippet contents, password preferences, tokens, OAuth codes or
/// secrets.
public enum FudgeLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var writer: LogWriter?
    nonisolated(unsafe) private static var setting: LogLevel = .default

    /// The app, at launch: the writer, and the Log level from `settings.json`. Tests pass nil afterwards.
    public static func start(writer: LogWriter?, level: LogLevel) {
        lock.withLock {
            self.writer = writer
            setting = level
        }
    }

    /// The Log level setting changed.
    public static func setLevel(_ level: LogLevel) {
        lock.withLock { setting = level }
    }

    public static var level: LogLevel { lock.withLock { setting } }

    /// Waits until every line so far is in its file: at quit.
    public static func flush() {
        lock.withLock { writer }?.flush()
    }

    public static func error(_ message: String) { write(.error, message) }
    public static func warning(_ message: String) { write(.warning, message) }
    public static func info(_ message: String) { write(.info, message) }
    public static func debug(_ message: String) { write(.debug, message) }

    /// A line of Fudge's own, for `Fudge.log`.
    public static func write(_ level: LogLevel, _ message: String) {
        let (writer, setting) = lock.withLock { (self.writer, self.setting) }
        let recorded = setting.records(level)
        if recorded || level == .error || level == .warning {
            FileHandle.standardError.write(Data("fudge: \(message)\n".utf8))
        }
        if recorded { writer?.write(level, message, to: .fudge) }
    }

    /// A line about a running command, for its extension's file only (never `Fudge.log`), and stderr as
    /// `[session] level: message`. The host has already left out lines below the Log level.
    public static func command(
        _ level: LogLevel, _ message: String, session: String, extensionName: String?, command: String?
    ) {
        let (writer, setting) = lock.withLock { (self.writer, self.setting) }
        FileHandle.standardError.write(Data("[\(session)] \(level.rawValue): \(message)\n".utf8))
        guard setting.records(level), let extensionName else { return }
        writer?.write(level, message, command: command, to: .extensionNamed(extensionName))
    }
}

/// What `Fudge.log` says about installed extensions changing between two reads of the extensions folder (SPEC-124
/// §2): installs, updates and removals, by the store or `fudge build`, as the app sees them. A build replaces the
/// extension's folder, so a new folder is an update even at the same version.
public struct InstallStamp: Sendable, Equatable {
    public let version: String?
    /// The folder's creation date.
    public let created: Date?

    public init(version: String?, created: Date?) {
        self.version = version
        self.created = created
    }

    /// The stamp of each extension the user installed (not the bundled ones), by name.
    public static func of(_ installed: [InstalledExtension], bundled: URL?) -> [String: InstallStamp] {
        var stamps: [String: InstallStamp] = [:]
        for item in installed where bundled.map({ !item.directory.path.hasPrefix($0.path) }) ?? true {
            let created = try? item.directory.resourceValues(forKeys: [.creationDateKey]).creationDate
            stamps[item.manifest.name] = InstallStamp(version: item.manifest.version, created: created)
        }
        return stamps
    }

    /// One line per change, by name.
    public static func changes(from before: [String: InstallStamp], to after: [String: InstallStamp]) -> [String] {
        let version = { (stamp: InstallStamp) in stamp.version.map { " \($0)" } ?? "" }
        return Set(before.keys).union(after.keys).sorted().compactMap { name in
            switch (before[name], after[name]) {
            case (nil, let new?): "installed \(name)\(version(new))"
            case (_?, nil): "removed \(name)"
            case (let old?, let new?) where old != new:
                old.version != new.version && old.version != nil && new.version != nil
                    ? "updated \(name) from \(old.version!) to \(new.version!)" : "updated \(name)\(version(new))"
            default: nil
            }
        }
    }
}
