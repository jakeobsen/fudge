import Foundation

/// The folder a repository's extensions are kept in, under the extensions folder (FUD-183): `raycast/extensions` for
/// Raycast's official repository, `<owner>/<repository>` for one on GitHub, `<host>/<path…>` for one on any other
/// server, and `fudgeapp/development` for the extensions built here without a repository.
///
/// The folder is worked out from an address's parts once, and the same parts always give the same folder. Parsing the
/// address is the caller's: this takes the host, the port and the path's segments. The runtime has the same rule in
/// `runtime/store-extension/src/repository-folder.ts`, and `runtime/test/fixtures/repository-folders.json` pins both to
/// the same cases.
public enum ExtensionRepositoryFolder {
    /// Raycast's official repository's folder, which holds the Extension Store's installs.
    public static let raycast = "raycast/extensions"
    /// The development folder: extensions built here without a repository. It's under the `fudgeapp` organization on
    /// GitHub, so no one else's repository has this folder.
    public static let development = "fudgeapp/development"

    /// A segment's most characters, and the whole folder's most bytes.
    static let maxSegmentLength = 100
    static let maxFolderBytes = 160
    /// The most path segments on a server other than GitHub.
    static let maxHostSegments = 6

    /// Why a repository can't have a folder. Each reason has one sentence, defined here only: adding a repository says
    /// the same words.
    public enum Refusal: String, Error, Equatable, Sendable, CaseIterable, CustomStringConvertible {
        /// A segment, an owner or a server name with a character the rule doesn't allow.
        case characters
        /// A segment over 100 characters, or a folder over 160 bytes.
        case tooLong
        /// More than six segments on a server other than GitHub.
        case tooManyParts
        /// Not two segments on GitHub, or none on another server.
        case notARepository
        /// A segment starting with `.`, which would be a hidden folder.
        case startsWithDot
        /// A server name without a dot: one word such as `localhost`, or an IPv6 address.
        case serverWithoutDot
        /// A port outside 1 to 65535.
        case port
        /// The same folder as a repository already in the list.
        case alreadyListed
        /// A folder inside another repository's, or holding one.
        case nests

        public var description: String {
            switch self {
            case .characters: "That address has characters Fudge can't use."
            case .tooLong: "That address is too long for Fudge to use."
            case .tooManyParts: "That address has too many parts. Use the repository's own address."
            case .notARepository: "Use the repository's own address, such as https://github.com/owner/repository."
            case .startsWithDot: "Fudge can't use a repository whose name starts with a dot."
            case .serverWithoutDot:
                "Fudge can only use a server whose name has a dot in it, such as git.example.org."
            case .port: "Fudge can only use a port from 1 to 65535."
            case .alreadyListed: "That repository is already in the list."
            case .nests:
                "That repository's folder would be inside another repository's, so Fudge can't keep their extensions apart."
            }
        }
    }

    /// The folder of the repository at `host`, `port` (nil when the address has none) and the path `segments` (with
    /// the trailing `/` and `.git` already dropped), or why it can't have one.
    ///
    /// On GitHub (`github.com` in any letter case, with no port or port 443) it's exactly two segments, the owner and
    /// the repository, in lowercase, since GitHub's names ignore letter case. On any other server it's the server's
    /// name in lowercase, `_` and the port when there's one other than 443, then each of one to six segments in
    /// lowercase.
    public static func folder(host: String, port: Int?, segments: [String]) -> Result<String, Refusal> {
        if let port, !(1...65535).contains(port) { return .failure(.port) }
        let folder: String
        if isGitHub(host), port == nil || port == 443 {
            guard segments.count == 2 else { return .failure(.notARepository) }
            if let refusal = ownerRefusal(segments[0]) ?? segmentRefusal(segments[1]) { return .failure(refusal) }
            folder = lowercased(segments[0]) + "/" + lowercased(segments[1])
        } else {
            if let refusal = hostRefusal(host) { return .failure(refusal) }
            guard !segments.isEmpty else { return .failure(.notARepository) }
            guard segments.count <= maxHostSegments else { return .failure(.tooManyParts) }
            if let refusal = segments.lazy.compactMap(segmentRefusal).first { return .failure(refusal) }
            let server = lowercased(host) + (port.map { $0 == 443 ? "" : "_\($0)" } ?? "")
            folder = ([server] + segments.map(lowercased)).joined(separator: "/")
        }
        guard folder.utf8.count <= maxFolderBytes else { return .failure(.tooLong) }
        return .success(folder)
    }

    /// Whether `folder` is one `folder(host:port:segments:)` gives: two lowercase segments for GitHub's owner and
    /// repository, or a lowercase server name with a dot (and `_<port>` for a port other than 443) and one to six
    /// lowercase segments; at most 160 bytes. `raycast/extensions` and `fudgeapp/development` pass.
    public static func isValid(_ folder: String) -> Bool {
        guard !folder.isEmpty, folder.utf8.count <= maxFolderBytes else { return false }
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, parts.allSatisfy({ $0 == lowercased($0) }) else { return false }
        if first.contains(".") {
            let server = first.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard hostRefusal(server[0]) == nil, (1...maxHostSegments).contains(parts.count - 1) else { return false }
            if server.count == 2 {
                guard let port = canonicalPort(server[1]), port != 443 else { return false }
            } else if isGitHub(server[0]) {
                // GitHub's folders are `<owner>/<repository>`, never under the server's name.
                return false
            }
            return parts.dropFirst().allSatisfy { segmentRefusal($0) == nil }
        }
        return parts.count == 2 && ownerRefusal(parts[0]) == nil && segmentRefusal(parts[1]) == nil
    }

    /// Why a repository whose folder is `folder` can't be added beside the repositories in `existing`: the same folder
    /// as one of them, or a folder inside one of theirs, or holding one; letter case ignored. Nil when it can.
    public static func conflict(_ folder: String, with existing: [String]) -> Refusal? {
        let new = lowercased(folder)
        var nests = false
        for other in existing.map(lowercased) {
            if other == new { return .alreadyListed }
            if new.hasPrefix(other + "/") || other.hasPrefix(new + "/") { nests = true }
        }
        return nests ? .nests : nil
    }

    // MARK: The parts' rules, in ASCII only, so a letter outside ASCII never reaches a lowercase conversion.

    static func isGitHub(_ host: String) -> Bool { lowercased(host) == "github.com" }

    /// A GitHub owner: letters, digits and hyphens, never starting or ending with a hyphen, and no dot.
    static func ownerRefusal(_ owner: String) -> Refusal? {
        guard !owner.isEmpty else { return .notARepository }
        let bytes = Array(owner.utf8)
        guard bytes.allSatisfy({ isLetterOrDigit($0) || $0 == UInt8(ascii: "-") }),
            bytes.first != UInt8(ascii: "-"), bytes.last != UInt8(ascii: "-")
        else { return .characters }
        return bytes.count > maxSegmentLength ? .tooLong : nil
    }

    /// A path segment: letters, digits, `.`, `_`, `~` and `-`, never starting with `.`, at most 100 characters.
    static func segmentRefusal(_ segment: String) -> Refusal? {
        guard !segment.isEmpty else { return .notARepository }
        let bytes = Array(segment.utf8)
        let allowed: Set<UInt8> = [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "-")]
        guard bytes.allSatisfy({ isLetterOrDigit($0) || allowed.contains($0) }) else { return .characters }
        if bytes.first == UInt8(ascii: ".") { return .startsWithDot }
        return bytes.count > maxSegmentLength ? .tooLong : nil
    }

    /// A server's name: letters, digits, `-` and dots, with at least one dot, never at either end or two in a row. An
    /// IPv4 address has that shape; an IPv6 address and a one-word name don't.
    static func hostRefusal(_ host: String) -> Refusal? {
        let bytes = Array(host.utf8)
        let dot = UInt8(ascii: ".")
        guard bytes.contains(dot), !bytes.contains(UInt8(ascii: ":")) else { return .serverWithoutDot }
        guard bytes.allSatisfy({ isLetterOrDigit($0) || $0 == dot || $0 == UInt8(ascii: "-") }),
            bytes.first != dot, bytes.last != dot, !host.contains("..")
        else { return .characters }
        return nil
    }

    /// A port as a folder writes it: digits with no leading zero, from 1 to 65535.
    static func canonicalPort(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 5, text.utf8.allSatisfy({ (48...57).contains($0) }),
            !text.hasPrefix("0"), let port = Int(text), (1...65535).contains(port)
        else { return nil }
        return port
    }

    static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// ASCII letters in lowercase, everything else as it is.
    static func lowercased(_ text: String) -> String {
        String(decoding: text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
}
