import Darwin
import Foundation

/// What `fudge build --outcome <folder>` writes as it ends (SPEC-156 A.3): `<folder>/<its pid>.ended.json`, holding
/// `{ "pid": <pid>, "status": <exit status>, "endedAt": "<ISO 8601, UTC, milliseconds>" }`. The Extension Store passes
/// its `installing/` folder, so the outcome sits beside the build's record, where the app and a reopened store read it.
public struct BuildOutcomeFile: Sendable, Equatable {
    public var pid: Int32
    public var status: Int32
    public var endedAt: Date

    public init(pid: Int32, status: Int32, endedAt: Date) {
        self.pid = pid
        self.status = status
        self.endedAt = endedAt
    }

    /// `<pid>.ended.json`.
    public static func fileName(pid: Int32) -> String { "\(pid).ended.json" }

    /// The file's text: one JSON object, the time as JavaScript's `toISOString()` writes it.
    public var text: String {
        "{ \"pid\": \(pid), \"status\": \(status), \"endedAt\": \"\(Self.time(endedAt))\" }\n"
    }

    /// The outcome in `data`, read from the file `fileName`, by the store reader's rules (`parseBuildOutcome`): the name
    /// is `<pid>.ended.json`, `pid` is that number, `status` an integer from 0 to 255 and `endedAt` a time written exactly
    /// as `toISOString()` writes it. `runtime/test/fixtures/build-outcome.json` pins both readers.
    public static func parse(fileName: String, data: Data) -> BuildOutcomeFile? {
        guard let pid = pid(ofCompanion: fileName, suffix: ".ended.json"),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let filePID = StoreBuildRecord.integer(object["pid"]), filePID == Int(pid),
            let status = StoreBuildRecord.integer(object["status"]), (0...255).contains(status),
            let endedAt = StoreBuildRecord.time(object["endedAt"])
        else { return nil }
        return BuildOutcomeFile(pid: pid, status: Int32(status), endedAt: endedAt)
    }

    /// The pid in a name `<pid><suffix>`, where the pid has no leading zero and at most ten digits, as the store's
    /// reader takes it.
    static func pid(ofCompanion name: String, suffix: String) -> Int32? {
        guard name.hasSuffix(suffix) else { return nil }
        let digits = name.dropLast(suffix.count)
        guard (1...10).contains(digits.count), digits.first != "0", digits.allSatisfy({ ("0"..."9").contains($0) }),
            let value = Int64(digits), value <= Int64(Int32.max)
        else { return nil }
        return Int32(value)
    }

    /// The line `fudge build` prints when the outcome can't be written; the exit status stays what it was.
    public static func saveFailure(folder: URL, reason: String) -> String {
        "fudge: couldn't save the build's outcome in \(folder.path): \(reason)"
    }

    /// Writes the outcome into `folder` atomically: a temporary file whose name starts with a dot, which the store's
    /// reader skips, then `rename`. Throws an error whose description is the reason.
    public func write(in folder: URL) throws {
        let temporary = folder.appendingPathComponent(".\(pid).\(UUID().uuidString.prefix(8)).ended.tmp")
        let target = folder.appendingPathComponent(Self.fileName(pid: pid))
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw OutcomeError(errno: errno) }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let writeError = written == bytes.count ? 0 : (written < 0 ? errno : EIO)
        Darwin.close(descriptor)
        guard writeError == 0, Darwin.rename(temporary.path, target.path) == 0 else {
            let error = OutcomeError(errno: writeError == 0 ? errno : writeError)
            Darwin.unlink(temporary.path)
            throw error
        }
    }

    struct OutcomeError: Error, CustomStringConvertible {
        let errno: Int32
        var description: String { String(cString: strerror(errno)) }
    }

    /// The time as JavaScript's `toISOString()` writes it: UTC with milliseconds.
    static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Writes `fudge build`'s outcome once, at whichever exit comes first: the normal one or the signal path
/// (`ChildProcesses.endChildrenOnSignals`), which runs on another queue. Nothing is written until `folder` is set.
public final class BuildOutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var folder: URL?
    private var written = false
    private let pid: Int32
    private let now: @Sendable () -> Date
    private let report: @Sendable (String) -> Void

    public init(
        pid: Int32 = getpid(), now: @escaping @Sendable () -> Date = { Date() },
        report: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.pid = pid
        self.now = now
        self.report = report
    }

    public func record(into folder: URL) {
        lock.withLock { self.folder = folder }
    }

    /// Writes `<folder>/<pid>.ended.json` with `status`, the first time it's called once a folder is set. A failure is
    /// reported on stderr and changes nothing else.
    public func ended(status: Int32) {
        lock.withLock {
            guard let folder, !written else { return }
            written = true
            do {
                try BuildOutcomeFile(pid: pid, status: status, endedAt: now()).write(in: folder)
            } catch {
                report(BuildOutcomeFile.saveFailure(folder: folder, reason: String(describing: error)))
            }
        }
    }
}
