import AppleArchive
import CryptoKit
import Foundation
import System

/// One file in a backup: its path inside the archive and its bytes.
public struct BackupEntry: Sendable, Equatable {
    public var path: String
    public var data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

/// Why a backup couldn't be read or written. Each says so in a sentence for the Settings window.
public enum BackupError: Error, Equatable, CustomStringConvertible {
    /// Not a backup at all, or one cut short or damaged.
    case unreadable
    case wrongPassword
    /// Written by a newer fudge.
    case newerFormat(Int)
    /// Refused as untrusted input, before anything was written.
    case refused(Refusal)
    case writeFailed(String)
    /// An import failed partway, and everything it had changed was put back.
    case importFailed(String)
    /// An import failed partway, and putting things back failed too: the before-import backup has the old state.
    case restoreFailed(beforeImport: String)

    public enum Refusal: Equatable, Sendable {
        case link
        case notAFile
        case path(String)
        case extensionName(String)
        case tooBig
        case duplicate(String)
        case noManifest
        /// A `settings.json` or keyed file that isn't a JSON object.
        case invalidPart(String)
    }

    public var description: String {
        switch self {
        case .unreadable: "This file isn't a fudge backup, or it's damaged."
        case .wrongPassword: "That password doesn't open this backup."
        case .newerFormat: "This backup was made by a newer version of fudge. Update fudge to import it."
        case .refused(let refusal):
            switch refusal {
            case .link: "This backup contains a link, so it wasn't imported."
            case .notAFile: "This backup contains something that isn't a file, so it wasn't imported."
            case .path(let path): "This backup contains a file fudge doesn't write (\(path)), so it wasn't imported."
            case .extensionName(let name):
                "This backup names an extension \"\(name)\" that isn't valid, so it wasn't imported."
            case .tooBig: "This backup is bigger than fudge imports, so it wasn't imported."
            case .duplicate(let path): "This backup contains \(path) twice, so it wasn't imported."
            case .noManifest: "This file isn't a fudge backup, or it's damaged."
            case .invalidPart(let name): "This backup's \(name) isn't valid, so it wasn't imported."
            }
        case .writeFailed(let reason): "The backup couldn't be written: \(reason)"
        case .importFailed(let reason): "The import failed, and nothing was changed: \(reason)"
        case .restoreFailed(let file):
            "The import failed partway, and fudge couldn't put everything back. Your settings before the import are "
                + "in \(file)."
        }
    }
}

/// A backup file: an Apple Archive of regular files, encrypted with a password (AppleEncryptedArchive's scrypt
/// profile), or plain for the before-import backups kept in the support folder.
public enum BackupArchive {
    /// The most one entry may hold, and all of them together, counted while reading.
    public static let entryLimit = 100 * 1024 * 1024
    public static let totalLimit = 150 * 1024 * 1024

    /// The shortest password fudge asks for.
    public static let minimumPasswordLength = 8

    /// What the archive's encryption is given for a password. AppleEncryptedArchive only takes 20 to 256 bytes, so
    /// fudge gives it a fixed-length string made from the password. scrypt still runs on every guess.
    static func archivePassword(_ password: String) -> String {
        SHA256.hash(data: Data("fudge-backup-v1:\(password)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `entries` to `file` atomically, readable by the owner only. With a password it's encrypted; without
    /// one it's a plain, compressed archive.
    public static func write(_ entries: [BackupEntry], to file: URL, password: String?) throws {
        try writeRaw(entries.map { RawEntry(path: $0.path, data: $0.data) }, to: file, password: password)
    }

    /// Whether `file` is an encrypted backup, which needs a password to read.
    public static func isEncrypted(_ file: URL) -> Bool {
        guard
            let stream = ArchiveByteStream.fileStream(
                path: FilePath(file.path), mode: .readOnly, options: [], permissions: [])
        else { return false }
        defer { try? stream.close() }
        return ArchiveEncryptionContext(from: stream) != nil
    }

    /// The most entries a backup may hold, and the longest path and path segment, in bytes.
    public static let entryCountLimit = 100_000
    static let pathLimit = 1024
    static let segmentLimit = 255

    /// Reads every entry, refusing links, anything that isn't a regular file, more than `entryCountLimit` entries,
    /// a path over `pathLimit` bytes or with a segment over `segmentLimit`, and data over `entryLimit` in one entry or
    /// `totalLimit` in all, with path bytes counted too. Each path goes to `checkPath` as soon as it's read, before
    /// its data, and each whole entry to `checkEntry`, so a refusal comes before the rest is read.
    public static func read(
        from file: URL, password: String?, entryLimit: Int = entryLimit, totalLimit: Int = totalLimit,
        entryCountLimit: Int = entryCountLimit, checkPath: (String) throws -> Void = { _ in },
        checkEntry: (BackupEntry) throws -> Void = { _ in }
    ) throws -> [BackupEntry] {
        guard
            let stream = ArchiveByteStream.fileStream(
                path: FilePath(file.path), mode: .readOnly, options: [], permissions: [])
        else { throw BackupError.unreadable }
        defer { try? stream.close() }
        let plain: ArchiveByteStream
        if let password {
            guard let context = ArchiveEncryptionContext(from: stream) else { throw BackupError.unreadable }
            do { try context.setPassword(archivePassword(password)) } catch { throw BackupError.unreadable }
            guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: stream, encryptionContext: context)
            else { throw BackupError.wrongPassword }
            plain = decrypted
        } else {
            guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: stream) else {
                throw BackupError.unreadable
            }
            plain = decompressed
        }
        defer { try? plain.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: plain) else { throw BackupError.unreadable }
        defer { try? decoder.close() }

        var entries: [BackupEntry] = []
        var total: UInt64 = 0
        func count(_ bytes: UInt64) throws {
            total += bytes
            guard total <= UInt64(totalLimit) else { throw BackupError.refused(.tooBig) }
        }
        while true {
            let header: ArchiveHeader?
            do { header = try decoder.readHeader() } catch { throw BackupError.unreadable }
            guard let header else { break }
            if header.field(forKey: Key.link) != nil || header.field(forKey: Key.hardLink) != nil
                || header.entryType == .link
            {
                throw BackupError.refused(.link)
            }
            guard header.entryType == .regularFile else { throw BackupError.refused(.notAFile) }
            guard case .string(_, let path)? = header.field(forKey: Key.path) else { throw BackupError.unreadable }
            guard entries.count < entryCountLimit else { throw BackupError.refused(.tooBig) }
            guard path.utf8.count <= pathLimit,
                path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    $0.utf8.count <= segmentLimit
                })
            else { throw BackupError.refused(.path(String(path.prefix(80)) + "…")) }
            try count(UInt64(path.utf8.count))
            try checkPath(path)
            var data = Data()
            if case .blob(_, let size, _)? = header.field(forKey: Key.data) {
                guard size <= UInt64(entryLimit) else { throw BackupError.refused(.tooBig) }
                try count(size)
                data = Data(count: Int(size))
                do {
                    try data.withUnsafeMutableBytes { try decoder.readBlob(key: Key.data, into: $0) }
                } catch { throw BackupError.unreadable }
            }
            let entry = BackupEntry(path: path, data: data)
            try checkEntry(entry)
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Writing entries of any kind (tests write crafted archives with it)

    enum Key {
        static var type: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("TYP") }
        static var path: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("PAT") }
        static var link: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("LNK") }
        static var hardLink: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("HLC") }
        static var data: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("DAT") }
    }

    struct RawEntry {
        var type: ArchiveHeader.EntryType = .regularFile
        var path: String
        var data: Data? = nil
        var link: String? = nil
        var hardLinkCluster: UInt64? = nil
    }

    static func writeRaw(_ entries: [RawEntry], to file: URL, password: String?) throws {
        let directory = file.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encode(entries, to: temporary, password: password)
            let written = try FileManager.default.replaceItemAt(file, withItemAt: temporary) ?? file
            // Replacing an existing file keeps its old mode; a backup is readable by its owner only.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: written.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? BackupError { throw error }
            throw BackupError.writeFailed(error.localizedDescription)
        }
    }

    private static func encode(_ entries: [RawEntry], to file: URL, password: String?) throws {
        guard
            let output = ArchiveByteStream.fileStream(
                path: FilePath(file.path), mode: .writeOnly, options: [.create, .truncate],
                permissions: [.ownerReadWrite])
        else { throw BackupError.writeFailed("couldn't create \(file.lastPathComponent)") }
        defer { try? output.close() }
        let body: ArchiveByteStream
        if let password {
            let context = ArchiveEncryptionContext(
                profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
            try context.setPassword(archivePassword(password))
            guard let encrypted = ArchiveByteStream.encryptionStream(writingTo: output, encryptionContext: context)
            else { throw BackupError.writeFailed("couldn't start the encryption") }
            body = encrypted
        } else {
            guard let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: output) else {
                throw BackupError.writeFailed("couldn't start the compression")
            }
            body = compressed
        }
        guard let encoder = ArchiveStream.encodeStream(writingTo: body) else {
            try? body.close()
            throw BackupError.writeFailed("couldn't start the archive")
        }
        do {
            for entry in entries {
                let header = ArchiveHeader()
                header.append(.uint(key: Key.type, value: UInt64(entry.type.rawValue)))
                header.append(.string(key: Key.path, value: entry.path))
                if let link = entry.link { header.append(.string(key: Key.link, value: link)) }
                if let cluster = entry.hardLinkCluster { header.append(.uint(key: Key.hardLink, value: cluster)) }
                if let data = entry.data { header.append(.blob(key: Key.data, size: UInt64(data.count))) }
                try encoder.writeHeader(header)
                if let data = entry.data {
                    try data.withUnsafeBytes { try encoder.writeBlob(key: Key.data, from: $0) }
                }
            }
            try encoder.close()
            try body.close()
        } catch {
            try? encoder.close()
            try? body.close()
            throw error
        }
    }
}
