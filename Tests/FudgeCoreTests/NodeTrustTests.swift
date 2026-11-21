import Foundation
import Testing

@testable import FudgeCore

@Test(arguments: [
    ("v22.14.0", false), ("v22.15.0", true), ("v22.18.1", true), ("v23.7.0", false), ("v23.8.0", true),
    ("v24.0.0", true), ("v26.5.0\n", true), ("v20.19.0", false), ("v21.9.0", false), ("node", false), ("", false),
])
func theSystemCAFlagNeedsANodeThatHasIt(version: String, supported: Bool) {
    #expect(NodeTrust.supportsSystemCA(version: version) == supported, "\(version)")
}

private func cert(_ byte: UInt8, _ settings: [NodeTrust.Domain: [NodeTrust.Setting]]) -> NodeTrust.Certificate {
    NodeTrust.Certificate(der: Data([0x30, byte]), settings: settings)
}

@Test func onlyCertificatesTrustedForSSLWithNoRestrictionAreExported() {
    let ssl = NodeTrust.Setting(result: .trustRoot, policy: .ssl)
    let certificates = [
        cert(1, [.system: []]),  // a system anchor: trusted for everything
        cert(2, [.user: [ssl]]),  // trusted for SSL by the user
        cert(3, [.admin: [NodeTrust.Setting(result: .trustAsRoot)]]),  // trusted for every policy
        cert(4, [.user: [NodeTrust.Setting(result: .trustRoot, policy: .ssl, restricted: true)]]),  // one host only
        cert(5, [.user: [NodeTrust.Setting(result: .deny, policy: .ssl)], .system: []]),  // a user deny over the system
        cert(6, [.system: [NodeTrust.Setting(result: .deny)], .user: [ssl]]),  // a deny anywhere wins
        cert(7, [.user: [NodeTrust.Setting(result: .trustRoot, policy: .other)]]),  // trusted, but not for SSL
        cert(8, [.user: [NodeTrust.Setting(result: .unspecified, policy: .ssl)], .system: []]),  // the user passes
        cert(9, [.user: [NodeTrust.Setting(result: .trustRoot, policy: .other)], .system: []]),  // SSL falls to system
        cert(10, [.user: [ssl, NodeTrust.Setting(result: .trustRoot, policy: .ssl, restricted: true)]]),  // mixed
        cert(11, [:]),  // nothing said anywhere
        cert(12, [.user: [NodeTrust.Setting(result: .trustRoot, policy: .ssl, restricted: true)], .system: []]),
        cert(2, [.user: [ssl]]),  // the same certificate again
    ]
    // Only the user's and admin's trust counts (SPEC-084): 1, 8, 9 and 12's deciding trust is the system's.
    #expect(NodeTrust.exportable(certificates) == [2, 3].map { Data([0x30, $0]) })
}

@Test func aSystemDenyStillRemovesAUserTrustedCertificate() {
    let ssl = NodeTrust.Setting(result: .trustRoot, policy: .ssl)
    let denied = cert(1, [.user: [ssl], .system: [NodeTrust.Setting(result: .deny, policy: .ssl)]])
    let trusted = cert(2, [.user: [ssl], .system: []])
    #expect(NodeTrust.exportable([denied, trusted]) == [Data([0x30, 2])])
}

@Test func certificatesAreWrittenAsPEM() throws {
    let der = Data((0..<100).map { UInt8($0) })
    let pem = NodeTrust.pem([der, Data([1, 2, 3])])
    let blocks = pem.components(separatedBy: "-----END CERTIFICATE-----\n").filter { !$0.isEmpty }
    #expect(blocks.count == 2)
    let first = try #require(blocks.first)
    #expect(first.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
    let body = first.dropFirst("-----BEGIN CERTIFICATE-----\n".count).split(separator: "\n")
    #expect(body.allSatisfy { $0.count <= 64 })
    #expect(Data(base64Encoded: body.joined()) == der)
}

@Test func theHostStartsWithTheFlagOrWithTheMacsCertificatesInAFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-trust-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("trust/roots.pem")
    var asked = 0
    let mac = {
        asked += 1
        return [cert(1, [.user: []]), cert(5, [.user: [NodeTrust.Setting(result: .deny)], .system: []])]
    }

    // A Node with the flag: no file, and the Mac isn't even read.
    let flagged = NodeTrust.launch(nodeVersion: "v24.1.0", certificates: mac, rootsFile: file)
    #expect(flagged.arguments == ["--use-system-ca"] && flagged.environment.isEmpty)
    #expect(asked == 0 && !FileManager.default.fileExists(atPath: file.path))

    // An older one: the exportable certificates, in a file only the user can read.
    let older = NodeTrust.launch(nodeVersion: "v23.1.0", certificates: mac, rootsFile: file)
    #expect(older.arguments.isEmpty && older.environment == ["NODE_EXTRA_CA_CERTS": file.path])
    #expect(try String(contentsOf: file, encoding: .utf8) == NodeTrust.pem([Data([0x30, 1])]))
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    // Nothing to export, or no version: the host starts as before.
    let none = NodeTrust.launch(nodeVersion: "v23.1.0", certificates: { [] }, rootsFile: file)
    #expect(none.arguments.isEmpty && none.environment.isEmpty)
    let unknown = NodeTrust.launch(nodeVersion: nil, certificates: mac, rootsFile: file)
    #expect(unknown.environment == ["NODE_EXTRA_CA_CERTS": file.path])
}
