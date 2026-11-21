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
    let flagged = NodeTrust.launch(nodeVersion: "v24.1.0", certificates: mac, rootsFile: file, inherited: [:])
    #expect(flagged.arguments == ["--use-system-ca"] && flagged.environment.isEmpty)
    #expect(asked == 0 && !FileManager.default.fileExists(atPath: file.path))

    // An older one: the exportable certificates, in a file only the user can read.
    let older = NodeTrust.launch(nodeVersion: "v23.1.0", certificates: mac, rootsFile: file, inherited: [:])
    #expect(older.arguments.isEmpty && older.environment == ["NODE_EXTRA_CA_CERTS": file.path])
    #expect(try String(contentsOf: file, encoding: .utf8) == NodeTrust.pem([Data([0x30, 1])]))
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    // Nothing to export, or no version: the host starts as before.
    let none = NodeTrust.launch(nodeVersion: "v23.1.0", certificates: { [] }, rootsFile: file, inherited: [:])
    #expect(none.arguments.isEmpty && none.environment.isEmpty)
    let unknown = NodeTrust.launch(nodeVersion: nil, certificates: mac, rootsFile: file, inherited: [:])
    #expect(unknown.environment == ["NODE_EXTRA_CA_CERTS": file.path])
}

/// Two made-up, self-signed test roots ("Fudge Test Root A" and "B"), for the inherited `NODE_EXTRA_CA_CERTS` file:
/// real certificates, since only what macOS reads as one is kept. Their keys were thrown away.
private let testRootA = """
    -----BEGIN CERTIFICATE-----
    MIIBbjCCARSgAwIBAgIUPu7HqSJ9133lY/fre7hkDLH8hgowCgYIKoZIzj0EAwIw
    HDEaMBgGA1UEAwwRRnVkZ2UgVGVzdCBSb290IEEwIBcNMjYxMTIxMTMwMDU3WhgP
    MjEyNjEwMjgxMzAwNTdaMBwxGjAYBgNVBAMMEUZ1ZGdlIFRlc3QgUm9vdCBBMFkw
    EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEnLFQACWIgwQB7VDF/ouYRs5ITvZtgkGz
    vlTU+DbXrHBZ3KC6BSz9QAgcSqLdWZQd4ymTvyk1UfkLpLo1W7rIMqMyMDAwHQYD
    VR0OBBYEFHmgg9A+Z1cnbypKcYzSUFwPdsyGMA8GA1UdEwEB/wQFMAMBAf8wCgYI
    KoZIzj0EAwIDSAAwRQIgduckcFCkXOcW0ezqZ0a7vQ7+K6PDMEXQTJplNejrhCMC
    IQDTsKriNFK2fU5hcYM+r7NZsEVf6t6Z2MIl/7jz2+5paw==
    -----END CERTIFICATE-----
    """ + "\n"
private let testRootB = """
    -----BEGIN CERTIFICATE-----
    MIIBbjCCARSgAwIBAgIUKDDPRiLlvuCXEDJHVat5Xp7V2xIwCgYIKoZIzj0EAwIw
    HDEaMBgGA1UEAwwRRnVkZ2UgVGVzdCBSb290IEIwIBcNMjYxMTIxMTMwMDU3WhgP
    MjEyNjEwMjgxMzAwNTdaMBwxGjAYBgNVBAMMEUZ1ZGdlIFRlc3QgUm9vdCBCMFkw
    EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/GryLMx8tevAWicX4Awyj5S2lOBw+j49
    F+/nIc3CvFlAIcz67nJ0t/O4O3iabMIGjkpmG0UuFmqWajx6z4CCEaMyMDAwHQYD
    VR0OBBYEFNTA0DM6XUfFdiJEjnJC39wcIKf0MA8GA1UdEwEB/wQFMAMBAf8wCgYI
    KoZIzj0EAwIDSAAwRQIgIjy1kC04GiffwWTbZ8y5ExOJmG9XUDzFj1jdbzmk35wC
    IQC1BoqwyiqAcurUh4Pl/jW5qbf22VMaVrLhEKGpSJLJHQ==
    -----END CERTIFICATE-----
    """ + "\n"
/// Base64 that decodes, but isn't a certificate: Node would stop reading the file at it.
private let notACertificate =
    "-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydGlmaWNhdGUsIGp1c3QgYmFzZTY0\n-----END CERTIFICATE-----\n"

@Test func anInheritedExtraCertsFileIsKeptNeverDropped() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-trust-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("trust/roots.pem")
    let theirs = folder.appendingPathComponent("company.pem")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let malformed = "-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----\n"
    try Data(("junk before\n" + testRootA + notACertificate + testRootB + malformed).utf8).write(to: theirs)
    let mac = { [cert(1, [.user: []])] }
    let inherited = ["NODE_EXTRA_CA_CERTS": theirs.path]

    // With the flag, theirs passes through as it is: Fudge sets nothing.
    let flagged = NodeTrust.launch(nodeVersion: "v24.1.0", certificates: mac, rootsFile: file, inherited: inherited)
    #expect(flagged.arguments == ["--use-system-ca"] && flagged.environment.isEmpty)

    // Without it, our file holds the Mac's first, then their certificates: only the blocks macOS reads as one, so
    // Node, which stops at the first block it can't load, loses nothing.
    let merged = NodeTrust.launch(nodeVersion: "v23.1.0", certificates: mac, rootsFile: file, inherited: inherited)
    #expect(merged.environment == ["NODE_EXTRA_CA_CERTS": file.path])
    let written = try String(contentsOf: file, encoding: .utf8)
    #expect(written == NodeTrust.pem([Data([0x30, 1])]) + testRootA + testRootB)
    #expect(written.hasPrefix(NodeTrust.pem([Data([0x30, 1])])), "the Mac's come first")

    // Nothing of the Mac's to add, or a file that can't be read: theirs passes through, untouched.
    let nothing = NodeTrust.launch(nodeVersion: "v23.1.0", certificates: { [] }, rootsFile: file, inherited: inherited)
    #expect(nothing.environment.isEmpty)
    let missing = ["NODE_EXTRA_CA_CERTS": folder.appendingPathComponent("gone.pem").path]
    let unread = NodeTrust.launch(nodeVersion: "v23.1.0", certificates: mac, rootsFile: file, inherited: missing)
    #expect(unread.arguments.isEmpty && unread.environment.isEmpty)
}

@Test func onlyBlocksMacOSReadsAsCertificatesAreTakenFromTheInheritedFile() {
    #expect(NodeTrust.pemCertificates(in: testRootA + notACertificate + testRootB) == [testRootA, testRootB])
    #expect(NodeTrust.pemCertificates(in: notACertificate).isEmpty, "base64 that decodes isn't a certificate")
    #expect(NodeTrust.isCertificate(Data()) == false)
    let der = Data(base64Encoded: testRootA.split(separator: "\n").dropFirst().dropLast().joined())
    #expect(der.map(NodeTrust.isCertificate) == true)
}

@Test func theNodeVersionIsReadOncePerBinaryAndAgainWhenItChanges() throws {
    final class Reads: @unchecked Sendable {
        var count = 0
        var stamp = Date(timeIntervalSince1970: 1)
    }
    let reads = Reads()
    let cache = NodeVersionCache(
        read: { _ in
            reads.count += 1
            return "v24.\(reads.count).0"
        }, stamp: { _ in reads.stamp })
    let node = URL(fileURLWithPath: "/opt/fake/bin/node")

    #expect(cache.cached(node) == .unknown, "never read on asking")
    #expect(cache.load(node) == "v24.1.0")
    #expect(cache.load(node) == "v24.1.0" && reads.count == 1, "a second start with the same binary doesn't read")
    #expect(cache.cached(node) == .known("v24.1.0"))

    reads.stamp = Date(timeIntervalSince1970: 2)  // a new modification date: a new Node
    #expect(cache.cached(node) == .unknown)
    #expect(cache.load(node) == "v24.2.0" && reads.count == 2)

    cache.refuseSystemCA(node)  // the binary refused the flag
    #expect(cache.cached(node) == .known(nil))
}

@Test func theVersionIsKeyedByTheResolvedBinary() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fudge-node-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let real = folder.appendingPathComponent("node-24")
    try Data("#!/bin/sh\n".utf8).write(to: real)
    let link = folder.appendingPathComponent("node")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let cache = NodeVersionCache(read: { _ in "v24.0.0" })
    cache.load(link)
    #expect(cache.cached(real) == .known("v24.0.0"), "a link and its target are one binary")
    #expect(NodeVersionCache.modificationDate(of: link) == NodeVersionCache.modificationDate(of: real))
}
