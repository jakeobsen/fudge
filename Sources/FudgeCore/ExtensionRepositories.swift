import CryptoKit
import Foundation

/// A repository of extensions in the Extension Store's list (FUD-182), Raycast's official repository as much as any
/// other (SPEC-176): one list, one rule, and the same row on the Settings page.
///
/// An address is parsed by hand, the same way here and in the Extension Store's `repository-address.ts`, never with
/// `URL` or the runtime's `new URL`, which disagree on `..`, `\`, tabs, `:443` and hosts outside ASCII.
/// `runtime/test/fixtures/repository-addresses.json` pins both to the same cases.
public struct ExtensionRepository: Sendable, Equatable {
    /// The address as typed, without the spaces around it.
    public let address: String
    /// The branch to follow; nil for the repository's default branch.
    public let branch: String?
    /// The repository's identity: `https://`, the server in lowercase (and a port other than 443), and the path
    /// without a trailing `/` and `.git`; on GitHub the path is in lowercase too, since GitHub's names ignore case.
    public let identity: String
    /// The first 16 hex digits of the identity's SHA-256, which names the Extension Store's copy of the repository.
    public let copyId: String
    /// `owner/repository` on GitHub, as typed; on any other server, the identity without `https://`.
    public let name: String
    /// The folder its extensions are installed in (`ExtensionRepositoryFolder`).
    public let folder: String

    /// The most repositories in the list, every one counted, Raycast's official repository too.
    public static let maxListed = 12
    /// Raycast's copy id, and the only one that isn't 16 hex digits.
    public static let raycastCopyId = "raycast"
    public static let raycastIdentity = "https://github.com/raycast/extensions"
    /// The address the Extension Store clones Raycast's repository from (`repositoryURL` in its `git.ts`).
    public static let raycastAddress = "https://github.com/raycast/extensions.git"
    /// The identity of the repository whose folder holds the extensions built here, which can't be added.
    public static let developmentIdentity = "https://github.com/fudgeapp/development"

    /// Why an address can't be added. Each has one sentence; those shared with the folder rule are its own.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// Not an `https://` address with a server.
        case https
        /// A user name or password in the address.
        case credentials
        /// The development folder's repository.
        case development
        /// A branch name that isn't a plain one.
        case branch
        /// Already `maxListed` repositories in the list.
        case tooMany
        /// A branch typed with Raycast's official repository's address, which always follows its default branch.
        case raycastBranch
        /// One of the folder rule's refusals, characters and ports included.
        case folder(ExtensionRepositoryFolder.Refusal)

        /// The name `repository-addresses.json` gives it.
        public var key: String {
            switch self {
            case .https: "https"
            case .credentials: "credentials"
            case .development: "development"
            case .branch: "branch"
            case .tooMany: "tooMany"
            case .raycastBranch: "raycastBranch"
            case .folder(let refusal): refusal.rawValue
            }
        }

        public var description: String {
            switch self {
            case .https: "Use an https:// address, such as https://github.com/owner/repository."
            case .credentials: "Leave the user name and password out of the address."
            case .development: "Fudge keeps your own builds in that repository's folder, so it can't be added."
            case .branch: "That branch name can't be used."
            case .tooMany: "You can have up to 12 repositories in the list."
            case .raycastBranch: "Raycast's official repository always follows its default branch."
            case .folder(let refusal): refusal.description
            }
        }
    }

    /// The repository at `address` on `branch` (empty or nil for the default branch), when it can be added beside
    /// `existing`, the repositories already in the list; else why not. The checks run in this order, as in the
    /// runtime, so both give the same refusal for an address with more than one problem.
    ///
    /// Raycast's official repository's address goes through every check any address does, and gives Raycast's own
    /// entry, which differs from any other only in its copy id (`raycast`), so its copy stays where it is.
    public static func parse(
        address: String, branch: String? = nil, existing: [ExtensionRepository] = []
    ) -> Result<ExtensionRepository, Refusal> {
        let text = trimmed(address)
        // Every step works on the UTF-8 bytes, never on Swift's characters: a `/` or an `@` followed by a combining
        // mark is one character to Swift, but the runtime finds the `/` or `@` in it.
        let bytes = Array(text.utf8)
        // The scheme, `https` in any letter case.
        guard let schemeEnd = index(of: Array("://".utf8), in: bytes),
            ExtensionRepositoryFolder.lowercased(String(decoding: bytes[..<schemeEnd], as: UTF8.self)).utf8
                .elementsEqual("https".utf8)
        else { return .failure(.https) }
        let rest = bytes[(schemeEnd + 3)...]
        let slash = rest.firstIndex(of: UInt8(ascii: "/"))
        let authority = rest[..<(slash ?? rest.endIndex)]
        var path = slash.map { rest[($0 + 1)...] } ?? []
        guard !authority.contains(UInt8(ascii: "@")) else { return .failure(.credentials) }
        guard authority.allSatisfy(isAuthorityByte), path.allSatisfy(isPathByte) else {
            return .failure(.folder(.characters))
        }
        // The server and its port, split at the first `:`.
        var hostBytes = authority
        var port: Int?
        if let colon = authority.firstIndex(of: UInt8(ascii: ":")) {
            hostBytes = authority[..<colon]
            guard let number = ExtensionRepositoryFolder.canonicalPort(ascii(authority[(colon + 1)...])) else {
                return .failure(.folder(.port))
            }
            port = number
        }
        guard !hostBytes.isEmpty else { return .failure(.https) }
        let host = ascii(hostBytes)
        // The path without one trailing `/`, then one trailing `.git`.
        if path.last == UInt8(ascii: "/") { path = path.dropLast() }
        if path.count >= 4, ascii(path.suffix(4)) == ".git" { path = path.dropLast(4) }
        let pathText = ascii(path)
        let segments =
            path.isEmpty ? [] : path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map(ascii)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return .failure(.folder(.characters)) }

        let gitHub = ExtensionRepositoryFolder.isGitHub(host) && (port == nil || port == 443)
        let server = ExtensionRepositoryFolder.lowercased(host) + (port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
        let identityPath = gitHub ? ExtensionRepositoryFolder.lowercased(pathText) : pathText
        let identity = "https://" + server + (pathText.isEmpty ? "" : "/" + identityPath)
        if identity == developmentIdentity { return .failure(.development) }

        let folder: String
        switch ExtensionRepositoryFolder.folder(host: host, port: port, segments: segments) {
        case .success(let value): folder = value
        case .failure(let refusal): return .failure(.folder(refusal))
        }
        let branchName = branch.map(trimmed) ?? ""
        // Raycast's official repository always follows its default branch: the store clones it from its own address.
        if !branchName.isEmpty, identity == raycastIdentity { return .failure(.raycastBranch) }
        guard branchName.isEmpty || isValidBranch(branchName) else { return .failure(.branch) }
        guard existing.count < maxListed else { return .failure(.tooMany) }
        guard !existing.contains(where: { $0.identity == identity }) else { return .failure(.folder(.alreadyListed)) }
        if let refusal = ExtensionRepositoryFolder.conflict(folder, with: existing.map(\.folder)) {
            return .failure(.folder(refusal))
        }
        // A second guard, last: only github.com with no port or port 443 gives these folders. The development
        // folder's identity is refused above, before the branch and the list are looked at.
        if folder == ExtensionRepositoryFolder.development { return .failure(.development) }
        return .success(
            ExtensionRepository(
                address: text, branch: branchName.isEmpty ? nil : branchName, identity: identity,
                copyId: folder == ExtensionRepositoryFolder.raycast ? raycastCopyId : copyId(of: identity),
                name: gitHub ? segments.joined(separator: "/") : String(identity.dropFirst(8)),
                folder: folder))
    }

    /// Raycast's official repository as its add button and a list from before SPEC-176 have it: its identity as the
    /// address, no branch, called `raycast/extensions` while it has no name.
    public static let raycast: ExtensionRepository = {
        guard case .success(let repository) = parse(address: raycastIdentity) else {
            preconditionFailure("Raycast's official repository's address is refused")
        }
        return repository
    }()

    /// The copy id of a repository with `identity`: the first 16 hex digits of its SHA-256.
    public static func copyId(of identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `copyId` is one Fudge gives: `raycast`, or 16 lowercase hex digits.
    public static func isValidCopyId(_ copyId: String) -> Bool {
        copyId == raycastCopyId
            || (copyId.utf8.count == 16
                && copyId.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    }

    /// Whether `name` is a plain branch name, as the Extension Store's `isValidBranch` (`git.ts`) has it: letters,
    /// digits and `._/+-`, starting with a letter, a digit or `_`, with no `..`, not ending with `.`, and no part
    /// that's empty, starts with `.` or ends with `.lock`.
    public static func isValidBranch(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        let allowed: Set<UInt8> = [
            UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "/"), UInt8(ascii: "+"),
            UInt8(ascii: "-"),
        ]
        guard let first = bytes.first, ExtensionRepositoryFolder.isLetterOrDigit(first) || first == UInt8(ascii: "_"),
            bytes.allSatisfy({ ExtensionRepositoryFolder.isLetterOrDigit($0) || allowed.contains($0) }),
            !name.contains(".."), !name.hasSuffix(".")
        else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }

    /// `text` without the ASCII spaces, tabs and line breaks around it; nothing else counts as a space, so both sides
    /// trim the same characters.
    static func trimmed(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let isSpace: (UInt8) -> Bool = { $0 == 32 || (9...13).contains($0) }
        guard let start = bytes.firstIndex(where: { !isSpace($0) }), let end = bytes.lastIndex(where: { !isSpace($0) })
        else { return "" }
        return String(decoding: bytes[start...end], as: UTF8.self)
    }

    /// Where `needle` first starts in `bytes`.
    static func index(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        return (0...(bytes.count - needle.count)).first { bytes[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    /// Bytes already checked to be ASCII, as text.
    static func ascii<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> String {
        String(decoding: Array(bytes), as: UTF8.self)
    }

    /// A server and port's characters: letters, digits, `.`, `-` and `:`.
    static func isAuthorityByte(_ byte: UInt8) -> Bool {
        ExtensionRepositoryFolder.isLetterOrDigit(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: ":")
    }

    /// A path's characters: letters, digits, `.`, `_`, `~`, `-` and `/`.
    static func isPathByte(_ byte: UInt8) -> Bool {
        ExtensionRepositoryFolder.isLetterOrDigit(byte)
            || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "-"), UInt8(ascii: "/")]
                .contains(byte)
    }
}

/// A repository in the Extension Store's list, as `settings.json` keeps it (`FudgeSettings.extensionRepositories`).
public struct ListedRepository: Sendable, Equatable {
    public var repository: ExtensionRepository
    /// Switched on; one that's off keeps its copy, but its rows leave the Extension Store and it isn't refreshed.
    public var on: Bool
    /// Its name (SPEC-174 B), given when it's added (`name` in `settings.json`), or nil for none; then it's called by
    /// `repository.name`.
    public var label: String?

    public init(repository: ExtensionRepository, on: Bool = true, label: String? = nil) {
        self.repository = repository
        self.on = on
        self.label = label
    }
}

/// Raycast's official repository's state in a `settings.json` from before SPEC-176 (`raycastRepository`, SPEC-160): in
/// the list and on, in the list and switched off, or removed from the list. Read only to move such a file's list into
/// `repositories` (`FudgeSettings.migratedRepositories`); nothing writes it any more.
public enum RaycastRepositoryState: String, Sendable, Equatable, CaseIterable {
    case on, off, removed

    /// The setting's value: absent is on, `"off"` is off, as is a JSON `false` (what Fudge wrote before), and
    /// `"removed"` is removed; anything else reads as on.
    init(settingsValue value: Any?) {
        if FudgeSettings.isJSONFalse(value) {
            self = .off
        } else if let text = value as? String, let state = RaycastRepositoryState(rawValue: text), state != .on {
            self = state
        } else {
            self = .on
        }
    }
}

/// The **Add Repository** window's fields and its reason line (SPEC-160). The Settings page keeps one in its own state
/// while the window is open, made new each time it opens, as the Quicklinks page keeps its sheet's `QuicklinkDraft`.
public struct ExtensionRepositoryDraft: Sendable, Equatable {
    public var address = ""
    public var branch = ""
    /// The Name field (SPEC-174 B1): optional, checked after the address (`RepositoryNames.check`).
    public var label = ""
    /// Why the last Add was refused, or why saving failed, shown in red in the window until the next Add.
    public private(set) var reason: String?

    public init() {}

    /// Add can be pressed once the address isn't blank.
    public var canAdd: Bool { !address.allSatisfy(\.isWhitespace) }

    /// **Add**: the address and branch checked against `existing`, the list as it is at that moment, then the name
    /// against the names there. Returns what to save, the repository with its name, and clears the reason; or keeps
    /// what was typed, sets the reason and returns nil. Raycast's official repository's address is checked as any is,
    /// and takes the name typed with it.
    public mutating func add(existing: [ListedRepository]) -> ListedRepository? {
        let repository: ExtensionRepository
        switch ExtensionRepository.parse(address: address, branch: branch, existing: existing.map(\.repository)) {
        case .success(let parsed): repository = parsed
        case .failure(let refusal):
            reason = refusal.description
            return nil
        }
        let name: String?
        switch RepositoryNames.check(label, others: existing.compactMap(\.label)) {
        case .success(let checked): name = checked
        case .failure(let refusal):
            reason = refusal.description
            return nil
        }
        reason = nil
        return ListedRepository(repository: repository, label: name)
    }

    /// Saving what Add accepted failed (`settings.json` can't be written): the window stays open with what was typed,
    /// and `problem` as its reason.
    public mutating func saveFailed(_ problem: String) {
        reason = problem
    }

    /// **Cancel** or Esc: the window closes with every field empty and no reason, as a new one opens.
    public func cancelled() -> ExtensionRepositoryDraft {
        ExtensionRepositoryDraft()
    }
}

extension FudgeSettings {
    /// Saves what the add window or an add button accepted (`ExtensionRepositoryDraft.add`,
    /// `RepositoryButton.entry(beside:)`): the repository, on, with its name, at the end of the list.
    public mutating func addRepository(_ listed: ListedRepository) {
        extensionRepositories.append(ListedRepository(repository: listed.repository, label: listed.label))
    }
}

/// An add button on the Extension Store's Settings page (SPEC-176): a repository's address, the name a press saves it
/// with, and the button's title. The table `all` is the only code that names a repository; everything else follows
/// the one rule.
public struct RepositoryButton: Sendable, Equatable {
    public let address: String
    public let name: String
    public let title: String

    public static let raycast = RepositoryButton(
        address: ExtensionRepository.raycastIdentity, name: "Raycast", title: "Add Raycast's Repository")
    public static let fudge = RepositoryButton(
        address: "https://github.com/fudgeapp/extensions", name: "Fudge", title: "Add Fudge's Repository")
    /// Every button, in the order the page shows them and a new install's list has them (`seed`).
    public static let all = [raycast, fudge]

    /// What the page shows for a button.
    public enum State: Sendable, Equatable {
        /// A listed repository has the button's address's identity.
        case hidden
        case enabled
        /// The add window's checks refuse it, for this reason (the button's help).
        case disabled(String)
    }

    /// Why a press saves nothing: the sentence of the add window's check that refused it.
    public struct Refused: Error, Sendable, Equatable {
        public let reason: String
    }

    /// The identity of the button's address (`ExtensionRepository.identity`).
    public var identity: String? {
        try? ExtensionRepository.parse(address: address).get().identity
    }

    /// The entry a press saves beside `list`, the list as it is at that moment: the add window's checks, in their
    /// order (`ExtensionRepositoryDraft.add`), with the button's address, no branch and its name. Accepted, it's on,
    /// with the name; refused, the reason is that check's sentence, such as a full list or a name another repository
    /// already has.
    public func entry(beside list: [ListedRepository]) -> Result<ListedRepository, Refused> {
        var draft = ExtensionRepositoryDraft()
        draft.address = address
        draft.label = name
        guard let listed = draft.add(existing: list) else { return .failure(Refused(reason: draft.reason ?? "")) }
        return .success(listed)
    }

    /// Hidden while a listed repository has the button's address's identity, by the duplicate rule, never by
    /// comparing text; else enabled while `entry(beside:)` accepts, or disabled with its reason.
    public func state(in list: [ListedRepository]) -> State {
        if let identity, list.contains(where: { $0.repository.identity == identity }) { return .hidden }
        switch entry(beside: list) {
        case .success: return .enabled
        case .failure(let refused): return .disabled(refused.reason)
        }
    }

    /// A new install's list: every button pressed in order, from an empty list (`FudgeSettings.writeRepositoryListOnce`).
    public static var seed: [ListedRepository] {
        all.reduce(into: []) { list, button in
            if case .success(let listed) = button.entry(beside: list) { list.append(listed) }
        }
    }
}

extension ExtensionRepository {
    /// The answer to the Extension Store's `extensionRepositories()` (`store.repositories`): every repository in the
    /// list, in its order, from `settings`, which the caller reads afresh for each call, each entry made the same way.
    /// `FudgeSettings.load` has already parsed each entry again and left out any the rule refuses. The Extension Store
    /// clones Raycast's official repository from its own `repositoryURL`, never from this answer.
    public static func storeAnswer(settings: FudgeSettings) -> JSONValue {
        .array(
            settings.extensionRepositories.map { listed in
                let repository = listed.repository
                var entry: [String: JSONValue] = [
                    "copyId": .string(repository.copyId), "folder": .string(repository.folder),
                    "address": .string(repository.address), "name": .string(repository.name),
                    "on": .bool(listed.on),
                ]
                if let branch = repository.branch { entry["branch"] = .string(branch) }
                // SPEC-174 B6: the Extension Store doesn't read it yet.
                if let label = listed.label { entry["label"] = .string(label) }
                return .object(entry)
            })
    }
}

/// What the Extension Store last found in a repository's copy (FUD-182), read from the status file it writes after each
/// try: Raycast's at `repo-status.json`, an added one's at `repositories/<copyId>/status.json`. Any extension running
/// in the host could write that file, so Settings shows only its own sentences, never text from it.
public enum ExtensionRepositoryStatus: Equatable, Sendable {
    /// No status file yet.
    case notChecked
    /// How many extensions the copy lists.
    case extensions(Int)
    /// What went wrong the last time.
    case problem(Problem)

    /// Why a copy couldn't be read, the same kinds as the Extension Store's.
    public enum Problem: String, CaseIterable, Sendable {
        case unreachable, noBranch, noExtensionsFolder, empty, tooMany, noPartialClone, failed

        /// Its sentence, the same as the Extension Store's; `branch` is the one `settings.json` names.
        public func sentence(branch: String?) -> String {
            switch self {
            case .unreachable: "Couldn't reach this repository. It may be private, or the address may be wrong."
            case .noBranch: "This repository has no branch called \(branch ?? "")."
            case .noExtensionsFolder: "This repository has no extensions folder."
            case .empty: "This repository has no extensions Fudge can list."
            case .tooMany: "This repository has more than 5,000 extensions."
            case .noPartialClone: "This repository's server can't send only the files the Extension Store needs."
            case .failed: "Something went wrong with this repository."
            }
        }
    }

    /// The most bytes read from a status file; a bigger one counts as `failed`.
    public static let maxBytes = 4096
    /// The most extensions a copy may list.
    public static let maxExtensions = 5000

    /// The status in `file`: `{ "checkedAt", "branch"?, "extensions" }` or `{ "checkedAt", "branch"?, "problem" }`.
    /// A file over 4 KB, one that isn't a JSON object, a `checkedAt` that isn't an ISO 8601 date, a count that isn't a
    /// whole number from 0 to 5,000, or a kind it doesn't know reads as `failed`; no file reads as not checked.
    /// Only a regular file counts: a link, a FIFO or a device in its place reads as `failed`, without waiting on it, since
    /// Settings reads it on the main thread.
    public static func read(_ file: URL) -> ExtensionRepositoryStatus {
        guard let data = RegularFile.read(file, maxBytes: maxBytes) else {
            var info = stat()
            return lstat(file.path, &info) == 0 ? .problem(.failed) : .notChecked
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let checkedAt = object["checkedAt"] as? String, isISO8601(checkedAt)
        else { return .problem(.failed) }
        if let kind = object["problem"] {
            return .problem((kind as? String).flatMap(Problem.init(rawValue:)) ?? .failed)
        }
        guard let number = object["extensions"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let count = Int(exactly: number.doubleValue), (0...maxExtensions).contains(count)
        else { return .problem(.failed) }
        return .extensions(count)
    }

    /// The line under the repository's row on the Settings page.
    public func sentence(branch: String?) -> String {
        switch self {
        case .notChecked: "Not checked yet"
        case .extensions(1): "1 extension"
        case .extensions(let count): "\(count) extensions"
        case .problem(let problem): problem.sentence(branch: branch)
        }
    }

    public var isProblem: Bool {
        if case .problem = self { true } else { false }
    }

    /// An ISO 8601 date and time, with or without fractions of a second, as JavaScript's `toISOString()` writes it.
    static func isISO8601(_ text: String) -> Bool {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) != nil || fractional.date(from: text) != nil
    }
}

/// The words of the Extension Store page's **Extension Repositories** section and its two sheets (FUD-182).
public enum ExtensionRepositoryText {
    public static let section = "Extension Repositories"
    public static let addRepositoryButton = "Add Repository…"
    public static let removeHelp = "Remove this repository"

    /// An added repository's secondary text: its address, and its branch when it follows one.
    public static func detail(_ repository: ExtensionRepository) -> String {
        repository.address + (repository.branch.map { ", branch \($0)" } ?? "")
    }

    /// The **Add Repository** window, which is the warning: shown once per repository added, and nothing warns later.
    public static let addWindowTitle = "Add Repository"
    public static let addressLabel = "Address"
    public static let addressPrompt = "https://github.com/owner/repository"
    public static let branchLabel = "Branch"
    public static let branchPrompt = "Default branch"
    public static let nameLabel = "Name"
    public static let namePrompt = "Optional"
    public static let nameHelp =
        "Fudge shows the name after an extension's name when two installed extensions have the same name."
    public static let addWarning =
        "Extensions from a repository run their own code on your Mac, like any app you install. Fudge checks "
        + "where their packages come from, not what their code does, so only add a repository you trust."
    public static let add = "Add"

    /// A repository's row's first line: its name, else its `owner/repository` as typed.
    public static func rowName(_ listed: ListedRepository) -> String {
        listed.label ?? listed.repository.name
    }

    /// The sheet before removing a repository, named as its row is.
    public static func removeTitle(_ name: String) -> String { "Remove \(name)?" }
    /// The sheet's message; for a repository with an add button, found by identity (`RepositoryButton.all`), it also
    /// says how to add it back.
    public static func removeMessage(for repository: ExtensionRepository) -> String {
        let button = RepositoryButton.all.first { $0.identity == repository.identity }
        return "Extensions you installed from it stay installed, but get no more updates. You can still uninstall them "
            + "in the Extension Store. Its downloaded list is deleted."
            + (button.map { " You can add it back with \($0.title)." } ?? "")
    }
    public static let remove = "Remove"
    public static let cancel = "Cancel"
}
