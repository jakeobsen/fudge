import CryptoKit
import Foundation

/// Where clipboard history is kept (SPEC-077 §3): `clipboard-history/` in the support folder (0700), holding
/// `history.enc`, the entries, and one `<file>.enc` per image (each 0600). Everything is sealed with AES-GCM under a
/// 256-bit key kept in the Keychain (`SecretStore`, service `keychainService`), with the file's name as additional
/// data, so one file can't stand in for another. A history that can't be read, its key gone or its file damaged,
/// starts empty, and the file is kept aside as `<name>.unreadable-<time>`. The folder is never in a backup (`Backup`
/// takes only the parts it knows).
public final class ClipboardHistoryStore: @unchecked Sendable {
    public static let folderName = "clipboard-history"
    public static let keychainService = "io.github.jakeobsen.fudge.clipboard-history"
    static let keyAccount = "history-key"
    static let historyFile = "history.enc"

    public let folder: URL
    private let secrets: SecretStore
    private let lock = NSLock()

    public init(paths: FudgePaths, secrets: SecretStore) {
        folder = paths.supportDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        self.secrets = secrets
    }

    /// The first 16 hex digits of `data`'s SHA-256: an image file's name starts with it, so the same image is found.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the history. A missing file is an empty history; an unreadable one is set aside, and the history starts
    /// empty. Never throws.
    public func load(now: Date = Date()) -> ClipboardHistory {
        lock.withLock {
            let file = folder.appendingPathComponent(Self.historyFile)
            guard let sealed = try? Data(contentsOf: file) else { return ClipboardHistory() }
            guard let key = try? existingKey(),
                let data = try? open(sealed, name: Self.historyFile, key: key),
                let history = try? JSONDecoder().decode(ClipboardHistory.self, from: data)
            else {
                setAside(file, now: now)
                return ClipboardHistory()
            }
            return history
        }
    }

    public func save(_ history: ClipboardHistory) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(history)
            try write(try seal(data, name: Self.historyFile, key: try key()), name: Self.historyFile)
        }
    }

    public func writeImage(_ png: Data, file: String) throws {
        try lock.withLock { try write(try seal(png, name: file, key: try key()), name: file + ".enc") }
    }

    public func readImage(file: String) throws -> Data {
        try lock.withLock {
            let sealed = try Data(contentsOf: folder.appendingPathComponent(file + ".enc"))
            guard let key = try existingKey() else { throw ClipboardStoreError.noKey }
            return try open(sealed, name: file, key: key)
        }
    }

    /// Deletes the image files a change dropped. A file that's already gone is fine.
    public func deleteImages(_ files: [String]) {
        lock.withLock {
            for file in files { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file + ".enc")) }
        }
    }

    /// Deletes the whole history and its key (**Delete History**).
    public func deleteAll() throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try secrets.delete(account: Self.keyAccount)
        }
    }

    // MARK: - Sealing

    private func existingKey() throws -> SymmetricKey? {
        try secrets.read(account: Self.keyAccount).flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
    }

    /// The key, made and kept the first time it's needed.
    private func key() throws -> SymmetricKey {
        if let key = try existingKey() { return key }
        let key = SymmetricKey(size: .bits256)
        try secrets.write(key.withUnsafeBytes { Data($0) }, account: Self.keyAccount)
        return key
    }

    private func seal(_ data: Data, name: String, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(name.utf8)).combined else {
            throw ClipboardStoreError.sealing
        }
        return combined
    }

    private func open(_ sealed: Data, name: String, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(name.utf8))
    }

    // MARK: - Files

    /// Writes `data` as `name` in the folder: created 0700, the file 0600, replaced in one step.
    private func write(_ data: Data, name: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let temporary = folder.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ClipboardStoreError.writing(name)
        }
        guard rename(temporary.path, folder.appendingPathComponent(name).path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw ClipboardStoreError.writing(name)
        }
    }

    private func setAside(_ file: URL, now: Date) {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let aside = file.deletingLastPathComponent().appendingPathComponent(
            "\(file.lastPathComponent).unreadable-\(stamp)")
        try? FileManager.default.moveItem(at: file, to: aside)
    }
}

public enum ClipboardStoreError: Error, Equatable, CustomStringConvertible {
    case noKey
    case sealing
    case writing(String)

    public var description: String {
        switch self {
        case .noKey: "The clipboard history's key isn't in the Keychain."
        case .sealing: "The clipboard history couldn't be encrypted."
        case .writing(let name): "Couldn't save the clipboard history (\(name))."
        }
    }
}
