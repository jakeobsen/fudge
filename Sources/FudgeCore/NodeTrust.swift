import Foundation
import Security

/// How the extension host comes to trust the certificates the Mac trusts (SPEC-081). Node ignores the macOS trust
/// store, so a server behind a company's own CA would fail TLS in extensions though Safari trusts it.
///
/// A Node with `--use-system-ca` gets that flag. Otherwise the certificates the Mac trusts for SSL, with no
/// restriction, are written as PEM to `trust/roots.pem` and handed to Node in `NODE_EXTRA_CA_CERTS`. Nothing ever
/// turns verification off, and nothing is exported that would make Node trust more than the Mac does.
public enum NodeTrust {
    public static let systemCAFlag = "--use-system-ca"
    public static let extraCertsVariable = "NODE_EXTRA_CA_CERTS"

    /// Whether a Node of this version (`node --version`'s output, e.g. `v22.15.0`) has `--use-system-ca`: 22.15 and
    /// later 22s, 23.8 and later 23s, and every version from 24.
    public static func supportsSystemCA(version: String) -> Bool {
        let digits = version.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" }
        let parts = digits.split(separator: ".").prefix(2).map { Int($0) }
        guard parts.count == 2, let major = parts[0], let minor = parts[1] else { return false }
        switch major {
        case 22: return minor >= 15
        case 23: return minor >= 8
        default: return major >= 24
        }
    }

    /// Where a trust setting comes from, most specific first: the user's, the admin's, the system's.
    public enum Domain: CaseIterable, Sendable {
        case user, admin, system
    }

    /// One entry of a certificate's trust settings in a domain (`SecTrustSettingsCopyTrustSettings`).
    public struct Setting: Equatable, Sendable {
        public enum Result: Equatable, Sendable {
            case trustRoot, trustAsRoot, deny, unspecified
        }

        public var result: Result
        /// The policy it's for: SSL, another one, or every policy (`nil`).
        public var policy: Policy?
        /// Whether it carries anything that narrows it: a host (`kSecTrustSettingsPolicyString`), an application,
        /// allowed errors or key usage.
        public var restricted: Bool

        public enum Policy: Equatable, Sendable {
            case ssl, other
        }

        public init(result: Result = .trustRoot, policy: Policy? = nil, restricted: Bool = false) {
            self.result = result
            self.policy = policy
            self.restricted = restricted
        }

        /// Whether it says anything about a server's certificate.
        var appliesToSSL: Bool { policy != .other }
    }

    /// A certificate the Mac knows: its DER bytes and its trust settings in each domain that has any. An empty list
    /// means "trusted as a root for everything", as Apple documents.
    public struct Certificate: Sendable {
        public var der: Data
        public var settings: [Domain: [Setting]]

        public init(der: Data, settings: [Domain: [Setting]]) {
            self.der = der
            self.settings = settings
        }
    }

    /// The certificates Node can be told to trust for every server, beyond its own bundle.
    ///
    /// - Only a trust from the user's or the admin's domain counts: the system's roots are Apple's, and Node ships its
    ///   own (SPEC-084).
    /// - A deny for SSL in any domain, the system's included, leaves a certificate out, whatever another domain says.
    /// - Otherwise the most specific domain that says anything about SSL decides: the certificate goes in only if
    ///   that domain trusts it as a root, for SSL or every policy, with nothing that narrows it. A trust for one host
    ///   would become a trust for every host in Node, so a restricted one leaves the certificate out.
    public static func exportable(_ certificates: [Certificate]) -> [Data] {
        var seen = Set<Data>()
        return certificates.compactMap { certificate in
            guard !seen.contains(certificate.der), isExportable(certificate) else { return nil }
            seen.insert(certificate.der)
            return certificate.der
        }
    }

    static func isExportable(_ certificate: Certificate) -> Bool {
        let all = Domain.allCases.compactMap { certificate.settings[$0] }
        if all.contains(where: { $0.contains { $0.appliesToSSL && $0.result == .deny } }) { return false }
        for domain in Domain.allCases {
            guard let settings = certificate.settings[domain] else { continue }
            // Only the user's and admin's trust goes in: the system's roots are Apple's, and Node has its own bundle.
            guard domain != .system else { return false }
            if settings.isEmpty { return true }
            let ssl = settings.filter { $0.appliesToSSL && $0.result != .unspecified }
            guard !ssl.isEmpty else { continue }
            return ssl.allSatisfy { ($0.result == .trustRoot || $0.result == .trustAsRoot) && !$0.restricted }
        }
        return false
    }

    /// Certificates as PEM, one after another.
    public static func pem(_ certificates: [Data]) -> String {
        certificates.map { der in
            let lines = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            return "-----BEGIN CERTIFICATE-----\n\(lines)\n-----END CERTIFICATE-----\n"
        }.joined()
    }

    /// What the host starts with: `--use-system-ca` when the Node has it, an inherited `NODE_EXTRA_CA_CERTS` passing
    /// through unchanged; otherwise `NODE_EXTRA_CA_CERTS` naming `rootsFile`, written afresh from `certificates` (folder
    /// 0700, file 0600), followed by the certificates of an inherited `NODE_EXTRA_CA_CERTS` file, so one set for Fudge
    /// (by the user or a profile) is never dropped. Node stops reading the file at the first block it can't load, so the
    /// Mac's come first, and only blocks macOS reads as certificates are taken from the inherited file
    /// (`pemCertificates`). With nothing of the Mac's to add, or an inherited file that can't be read, the environment
    /// stays as it is.
    public static func launch(
        nodeVersion: String?, certificates: () -> [Certificate], rootsFile: URL,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> (arguments: [String], environment: [String: String]) {
        if let nodeVersion, supportsSystemCA(version: nodeVersion) { return ([systemCAFlag], [:]) }
        var theirs = ""
        if let path = inherited[extraCertsVariable], !path.isEmpty, path != rootsFile.path {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return ([], [:]) }
            theirs = pemCertificates(in: String(decoding: data, as: UTF8.self)).joined()
        }
        let roots = exportable(certificates())
        guard !roots.isEmpty else { return ([], [:]) }
        do {
            let files = FileManager.default
            let folder = rootsFile.deletingLastPathComponent()
            try files.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data((pem(roots) + theirs).utf8).write(to: rootsFile, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rootsFile.path)
        } catch {
            return ([], [:])
        }
        return ([], [extraCertsVariable: rootsFile.path])
    }

    /// The PEM certificate blocks in `text` that macOS reads as certificates (`SecCertificateCreateWithData`), each as
    /// one block ending in a newline. Base64 that decodes isn't enough: Node drops everything after a block it can't
    /// load.
    static func pemCertificates(in text: String) -> [String] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var blocks: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: begin), let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex)
        {
            let body = rest[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if !body.isEmpty, let der = Data(base64Encoded: String(body)), isCertificate(der) {
                blocks.append(pem([der]))
            }
            rest = rest[stop.upperBound...]
        }
        return blocks
    }

    /// Whether `der` is an X.509 certificate, as the Security framework parses one. Only parses: no Keychain.
    static func isCertificate(_ der: Data) -> Bool {
        !der.isEmpty && SecCertificateCreateWithData(nil, der as CFData) != nil
    }

    /// `node --version`, read when the host starts; nil if it doesn't answer within 5 seconds.
    public static func version(of node: URL) -> String? {
        let process = Process()
        process.executableURL = node
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// `node --version` per Node binary, for the run (SPEC-084): read once, off the main actor, and again only when the
/// binary changes. It's keyed by the resolved binary (Homebrew's `node` is a link) and its modification date.
public final class NodeVersionCache: @unchecked Sendable {
    public enum Lookup: Equatable, Sendable {
        case known(String?)
        case unknown
    }

    private let lock = NSLock()
    private var entries: [String: (stamp: Date?, version: String?)] = [:]
    private let read: @Sendable (URL) -> String?
    private let stamp: @Sendable (URL) -> Date?

    public init(
        read: @escaping @Sendable (URL) -> String? = { NodeTrust.version(of: $0) },
        stamp: @escaping @Sendable (URL) -> Date? = NodeVersionCache.modificationDate
    ) {
        self.read = read
        self.stamp = stamp
    }

    public static func modificationDate(of node: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: node.resolvingSymlinksInPath().path))?[.modificationDate]
            as? Date
    }

    private static func key(_ node: URL) -> String { node.resolvingSymlinksInPath().path }

    /// The version, when it's known for the binary as it is now. Never reads it, so the main actor can ask.
    public func cached(_ node: URL) -> Lookup {
        let now = stamp(node)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[Self.key(node)], entry.stamp == now else { return .unknown }
        return .known(entry.version)
    }

    /// The version, read now unless it's known; this blocks, so call it off the main actor.
    @discardableResult
    public func load(_ node: URL) -> String? {
        if case .known(let version) = cached(node) { return version }
        let now = stamp(node)
        let version = read(node)
        lock.lock()
        entries[Self.key(node)] = (now, version)
        lock.unlock()
        return version
    }

    /// The binary refused `--use-system-ca` (a version manager's shim can switch Node without changing): it counts
    /// as having none until it changes.
    public func refuseSystemCA(_ node: URL) {
        let now = stamp(node)
        lock.lock()
        entries[Self.key(node)] = (now, nil)
        lock.unlock()
    }
}
