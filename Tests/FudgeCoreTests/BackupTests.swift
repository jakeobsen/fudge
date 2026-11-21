import Foundation
import Testing

@testable import FudgeCore

/// A throwaway support folder, removed when the test ends.
private final class Folder {
    let url: URL
    var paths: FudgePaths { FudgePaths(supportDirectory: url) }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fudge-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ text: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: url.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func json(_ path: String) -> [String: Any]? {
        (try? Data(contentsOf: url.appendingPathComponent(path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    /// Every file under the folder with its contents, for "nothing changed" checks.
    func snapshot() -> [String: Data] {
        var files: [String: Data] = [:]
        for path in (try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? [] {
            let file = url.appendingPathComponent(path)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files[path] = try? Data(contentsOf: file)
        }
        return files
    }
}

private func installed(_ name: String, title: String, version: String? = nil) throws -> InstalledExtension {
    let versionField = version.map { #","version":"\#($0)""# } ?? ""
    let json = #"{"name":"\#(name)","title":"\#(title)"\#(versionField)}"#
    return InstalledExtension(
        manifest: try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8)),
        directory: URL(fileURLWithPath: "/nonexistent/\(name)"))
}

private let now = Date(timeIntervalSince1970: 1_795_000_000)
private let password = "correct horse"

/// A support folder with every part, the Extension Store's consent, and the things a backup leaves out.
private func seeded() throws -> Folder {
    let folder = try Folder()
    try folder.write(
        "settings.json",
        #"{"hotkey":"option+space","extensionStore":true,"extensionStoreConsentAt":"2026-11-20T10:00:00Z","commands":{"alpha/run":{"alias":"ar"}}}"#
    )
    try folder.write("launch-permissions.json", #"{"alpha":{"beta":true}}"#)
    try folder.write("history.json", #"{"alpha/run":3}"#)
    try folder.write("dropdown-values.json", #"{"alpha/run/kind":"b"}"#)
    try folder.write("command-metadata.json", #"{"alpha/run":{"subtitle":"Busy"}}"#)
    try folder.write(
        "quicklinks.json",
        #"{"quicklinks":[{"id":"q1","name":"Jira","link":"https://jira.example.com/browse/{ticket}"},{"id":"q2"}]}"#)
    try folder.write("preferences/alpha.json", #"{"token":"secret"}"#)
    try folder.write("local-storage/alpha.json", #"{"count":"1"}"#)
    try folder.write("form-values/alpha.json", #"{"run":{"name":"x"}}"#)
    try folder.write("extension-data/alpha/notes/a.txt", "alpha's note")
    try folder.write("extension-data/fudge-extension-store/installed.json", #"{"alpha":{"tree":"t"}}"#)
    try folder.write("extension-data/fudge-extension-store/repo/extensions/alpha/package.json", "{}")
    // Left out of every backup:
    try folder.write("cache/alpha/cache.json", "{}")
    try folder.write("exchange-rates.json", "{}")
    try folder.write("onboarding.json", "{}")
    try folder.write("extensions/alpha/package.json", "{}")
    try folder.write("backups/before-import-old.fudgebackup", "old")
    return folder
}

// MARK: - The password

@Test func theArchiveGetsAFixedLengthStringMadeFromThePassword() throws {
    #expect(
        BackupArchive.archivePassword("correct horse")
            == "9befe618e1e188107af4b8d691bf81d7a767a69d0b201f4bc52f23cbd76caf38")
    #expect(BackupArchive.archivePassword("12345678").count == 64, "within AppleEncryptedArchive's 20–256 bytes")
    let folder = try Folder()
    let file = folder.url.appendingPathComponent("b.fudgebackup")
    try BackupArchive.write([BackupEntry(path: "manifest.json", data: Data("{}".utf8))], to: file, password: "12345678")
    #expect(BackupArchive.isEncrypted(file))
    #expect(try BackupArchive.read(from: file, password: "12345678").map(\.path) == ["manifest.json"])
}

// MARK: - Round trip

@Test func aBackupRoundTripsIntoAnEmptySupportFolder() throws {
    let source = try seeded()
    let export = Backup.collect(
        from: source.paths, installed: [try installed("alpha", title: "Alpha", version: "1.2.0")],
        fudgeVersion: "1.0", now: now)
    #expect(export.leftOut.isEmpty && export.skipped == 0)
    #expect(
        export.summary.text
            == "Settings, 1 quicklink, 1 extension's preferences, 1 extension's data, 1 installed extension listed",
        "alpha's data; the store's folder is never backed up; q2 isn't a quicklink")
    let exported = try #require(export.entries.first { $0.path == "settings.json" })
    let exportedSettings = try #require(try JSONSerialization.jsonObject(with: exported.data) as? [String: Any])
    #expect(exportedSettings["extensionStoreConsentAt"] == nil, "the consent never goes into a backup")
    #expect(exportedSettings["extensionStore"] as? Bool == true, "the switch does, for the import's summary")
    let file = source.url.appendingPathComponent("out/fudge-backup.fudgebackup")
    try BackupArchive.write(export.entries, to: file, password: password)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)

    let contents = try Backup.open(file, password: password)
    #expect(contents.manifest.format == 1 && contents.manifest.fudgeVersion == "1.0")
    #expect(
        contents.manifest.extensions == [
            Backup.Listed(name: "alpha", title: "Alpha", version: "1.2.0", source: .store, storeTree: "t")
        ])
    #expect(contents.hadExtensionStore)
    #expect(contents.summary.quicklinks == 1, "the import's summary counts them too")

    let target = try Folder()
    let result = try Backup.apply(contents, to: target.paths, installed: [], fudgeVersion: "1.0", now: now)
    #expect(result.notInstalled.map(\.name) == ["alpha"] && result.hadExtensionStore)
    let settings = try #require(target.json("settings.json"))
    #expect(settings["hotkey"] as? String == "option+space")
    #expect(settings["extensionStore"] == nil && settings["extensionStoreConsentAt"] == nil, "consent never travels")
    for path in [
        "launch-permissions.json", "history.json", "quicklinks.json", "preferences/alpha.json",
        "local-storage/alpha.json", "form-values/alpha.json", "extension-data/alpha/notes/a.txt",
    ] {
        #expect(target.read(path) == source.read(path), "\(path)")
    }
    // The keyed files are merged, so they're written again: the same entries.
    #expect(target.json("dropdown-values.json") as? [String: String] == ["alpha/run/kind": "b"])
    #expect(
        (target.json("command-metadata.json")?["alpha/run"] as? [String: String]) == ["subtitle": "Busy"])
    #expect(target.json("settings.json")?["commands"] != nil)
    for path in [
        "cache/alpha/cache.json", "exchange-rates.json", "onboarding.json", "extensions/alpha/package.json",
        "extension-data/fudge-extension-store/installed.json",
        "extension-data/fudge-extension-store/repo/extensions/alpha/package.json",
    ] {
        #expect(!target.exists(path), "\(path) is left out")
    }
}

@Test func anExtensionWhoseNameHasAnUnderscoreRoundTrips() throws {
    // Raycast allows _ in an extension's name (notion_researcher), so everything kept under that name comes back.
    let name = "notion_researcher"
    let source = try Folder()
    try source.write("settings.json", #"{"commands":{"\#(name)/ask":{"alias":"nr"}},"extensions":{"\#(name)":{}}}"#)
    try source.write("launch-permissions.json", #"{"\#(name)":{"alpha":true}}"#)
    try source.write("history.json", #"{"\#(name)/ask":2}"#)
    try source.write("dropdown-values.json", #"{"\#(name)/ask/kind":"b"}"#)
    try source.write("preferences/\(name).json", #"{"token":"t"}"#)
    try source.write("local-storage/\(name).json", #"{"k":"v"}"#)
    try source.write("form-values/\(name).json", #"{"ask":{"q":"x"}}"#)
    try source.write("extension-data/\(name)/notes.txt", "kept")
    let export = Backup.collect(
        from: source.paths, installed: [try installed(name, title: "Notion Researcher")], fudgeVersion: "1.0", now: now)
    #expect(export.leftOut.isEmpty && export.skipped == 0)
    let file = source.url.appendingPathComponent("out/b.fudgebackup")
    try BackupArchive.write(export.entries, to: file, password: password)
    let contents = try Backup.open(file, password: password)
    #expect(contents.manifest.extensions.map(\.name) == [name])

    let target = try Folder()
    _ = try Backup.apply(contents, to: target.paths, installed: [], fudgeVersion: "1.0", now: now)
    for path in [
        "launch-permissions.json", "history.json", "preferences/\(name).json", "local-storage/\(name).json",
        "form-values/\(name).json", "extension-data/\(name)/notes.txt",
    ] {
        #expect(target.read(path) == source.read(path), "\(path)")
    }
    #expect(target.json("dropdown-values.json") as? [String: String] == ["\(name)/ask/kind": "b"])
    #expect((target.json("settings.json")?["commands"] as? [String: Any])?["\(name)/ask"] != nil)
}

@Test func aWrongPasswordOrADamagedFileFailsCleanly() throws {
    let source = try seeded()
    let export = Backup.collect(from: source.paths, installed: [], fudgeVersion: "1.0", now: now)
    let file = source.url.appendingPathComponent("b.fudgebackup")
    try BackupArchive.write(export.entries, to: file, password: password)
    #expect(throws: BackupError.wrongPassword) { try Backup.open(file, password: "not the password") }

    let garbage = source.url.appendingPathComponent("garbage.fudgebackup")
    try Data("not an archive at all".utf8).write(to: garbage)
    #expect(throws: BackupError.unreadable) { try Backup.open(garbage, password: password) }
    #expect(!BackupArchive.isEncrypted(garbage))

    let whole = try Data(contentsOf: file)
    let truncated = source.url.appendingPathComponent("truncated.fudgebackup")
    try whole.prefix(whole.count / 2).write(to: truncated)
    #expect(throws: BackupError.self) { try Backup.open(truncated, password: password) }
}

@Test func aNewerFormatIsRefused() throws {
    let manifest = #"{"format":2,"fudgeVersion":"9.0","created":"2030-01-01T00:00:00Z","extensions":[]}"#
    #expect(throws: BackupError.newerFormat(2)) {
        try Backup.contents(of: [BackupEntry(path: "manifest.json", data: Data(manifest.utf8))])
    }
    let unknownShape = #"{"format":3,"something":"else"}"#
    #expect(throws: BackupError.newerFormat(3)) {
        try Backup.contents(of: [BackupEntry(path: "manifest.json", data: Data(unknownShape.utf8))])
    }
}

@Test func theCapLeavesOutTheBiggestExtensionsData() throws {
    let folder = try Folder()
    try folder.write("extension-data/big/blob", String(repeating: "x", count: 800))
    try folder.write("local-storage/small.json", String(repeating: "y", count: 150))
    try folder.write("extension-data/small/blob", String(repeating: "z", count: 150))
    let export = Backup.collect(from: folder.paths, installed: [], fudgeVersion: "1.0", now: now, dataCap: 1000)
    #expect(export.leftOut == ["big"])
    #expect(!export.entries.contains { $0.path.hasPrefix("extension-data/big/") })
    #expect(export.entries.contains { $0.path == "extension-data/small/blob" })
    #expect(export.summary.data == ["small"])
}

@Test func exportNeverFollowsLinks() throws {
    let folder = try seeded()
    let outside = try Folder()
    try outside.write("elsewhere/secret.txt", "not fudge's")
    let manager = FileManager.default
    try manager.createSymbolicLink(
        at: folder.url.appendingPathComponent("extension-data/linked"),
        withDestinationURL: outside.url.appendingPathComponent("elsewhere"))
    try manager.createSymbolicLink(
        at: folder.url.appendingPathComponent("extension-data/alpha/inner.txt"),
        withDestinationURL: outside.url.appendingPathComponent("elsewhere/secret.txt"))
    let export = Backup.collect(from: folder.paths, installed: [], fudgeVersion: "1.0", now: now)
    #expect(export.skipped == 2)
    #expect(!export.entries.contains { $0.path.contains("linked") || $0.path.contains("inner.txt") })
    #expect(export.entries.contains { $0.path == "extension-data/alpha/notes/a.txt" })
}

// MARK: - Applying an import

@Test func anImportReplacesItsPartsAndLeavesTheRestAlone() throws {
    let source = try seeded()
    let file = source.url.appendingPathComponent("b.fudgebackup")
    try BackupArchive.write(
        Backup.collect(from: source.paths, installed: [], fudgeVersion: "1.0", now: now).entries, to: file,
        password: password)

    let target = try Folder()
    try target.write("settings.json", #"{"hotkey":"cmd+space","extensionStore":true,"extensionStoreConsentAt":"here"}"#)
    try target.write("dropdown-values.json", #"{"alpha/run/kind":"a","beta/list":"keep"}"#)
    try target.write("preferences/alpha.json", #"{"token":"old"}"#)
    try target.write("preferences/beta.json", #"{"token":"beta's"}"#)
    try target.write("extension-data/alpha/stale.txt", "gone after the import")
    try target.write("extension-data/beta/b.txt", "beta's data")

    let result = try Backup.apply(
        try Backup.open(file, password: password), to: target.paths,
        installed: [try installed("alpha", title: "Alpha")],
        fudgeVersion: "1.0", now: now)
    #expect(result.notInstalled.isEmpty)

    let settings = try #require(target.json("settings.json"))
    #expect(settings["hotkey"] as? String == "option+space")
    #expect(settings["extensionStore"] as? Bool == true && settings["extensionStoreConsentAt"] as? String == "here")
    #expect(target.json("dropdown-values.json") as? [String: String] == ["alpha/run/kind": "b", "beta/list": "keep"])
    #expect(target.read("preferences/alpha.json") == #"{"token":"secret"}"#)
    #expect(target.read("preferences/beta.json") == #"{"token":"beta's"}"#)
    #expect(target.read("extension-data/alpha/notes/a.txt") == "alpha's note")
    #expect(!target.exists("extension-data/alpha/stale.txt"), "an extension's data folder is replaced whole")
    #expect(target.read("extension-data/beta/b.txt") == "beta's data")
    #expect(!target.snapshot().keys.contains { $0.contains(".import-") }, "no staging left behind")

    // The before-import backup holds what was there, unencrypted.
    #expect(result.beforeImport.deletingLastPathComponent().lastPathComponent == "backups")
    let before = try Backup.open(result.beforeImport, password: nil)
    #expect(before.root["settings.json"].flatMap { String(data: $0, encoding: .utf8) }?.contains("cmd+space") == true)
    #expect(before.data["alpha"]?["stale.txt"] == Data("gone after the import".utf8))
}

@Test func onlyTheLastThreeBeforeImportBackupsAreKeptPrivately() throws {
    let source = try seeded()
    let contents = try Backup.contents(
        of: Backup.collect(from: source.paths, installed: [], fudgeVersion: "1.0", now: now).entries)
    let target = try Folder()
    var made: [URL] = []
    for minute in 0..<5 {
        made.append(
            try Backup.apply(
                contents, to: target.paths, installed: [], fudgeVersion: "1.0",
                now: now.addingTimeInterval(Double(minute) * 60)
            ).beforeImport)
    }
    let kept = try FileManager.default.contentsOfDirectory(atPath: target.paths.backupsDirectory.path).sorted()
    #expect(kept == made.suffix(3).map(\.lastPathComponent))
    let manager = FileManager.default
    #expect(
        (try manager.attributesOfItem(atPath: target.paths.backupsDirectory.path)[.posixPermissions] as? Int) == 0o700)
    for name in kept {
        let path = target.paths.backupsDirectory.appendingPathComponent(name).path
        #expect((try manager.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
    }
}

@Test func aWriteThatFailsPartwayPutsEverythingBack() throws {
    let source = try seeded()
    try source.write("extension-data/beta/b.txt", "beta's data")
    let contents = try Backup.contents(
        of: Backup.collect(from: source.paths, installed: [], fudgeVersion: "1.0", now: now).entries)
    let target = try Folder()
    try target.write("settings.json", #"{"hotkey":"cmd+space"}"#)
    try target.write("history.json", #"{"old":1}"#)
    try target.write("extension-data/alpha/old.txt", "old data")
    let before = target.snapshot()

    // Writes 1–8 are files, 9 stages alpha's data folder, and 10 stages the store's, after alpha's swap.
    for failing in [3, 9, 10] {
        let writes = Counter()
        let writer = Backup.FileWriter { data, url in
            if writes.next() == failing { throw CocoaError(.fileWriteNoPermission) }
            try Backup.FileWriter.atomic.write(data, url)
        }
        #expect(throws: BackupError.self) {
            try Backup.apply(contents, to: target.paths, installed: [], fudgeVersion: "1.0", now: now, writer: writer)
        }
        let after = target.snapshot().filter { !$0.key.hasPrefix("backups/") }
        #expect(after == before, "write \(failing) failing leaves the folder as it was")
    }
}

private final class Counter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

// MARK: - Crafted backups: refused, with nothing written

private func crafted(_ entries: [BackupArchive.RawEntry], limits: (Int, Int)? = nil) throws -> Result<
    Backup.Contents, Error
> {
    let folder = try Folder()
    let manifest = BackupArchive.RawEntry(
        path: "manifest.json",
        data: Data(#"{"format":1,"fudgeVersion":"1.0","created":"2026-11-20T00:00:00Z","extensions":[]}"#.utf8))
    let file = folder.url.appendingPathComponent("crafted.fudgebackup")
    try BackupArchive.writeRaw([manifest] + entries, to: file, password: password)
    let support = try Folder()
    let before = support.snapshot()
    let result = Result {
        if let limits {
            try Backup.contents(
                of: BackupArchive.read(from: file, password: password, entryLimit: limits.0, totalLimit: limits.1))
        } else {
            try Backup.open(file, password: password)
        }
    }
    #expect(support.snapshot() == before && !support.exists("backups"), "nothing written")
    return result
}

private func refusal(_ result: Result<Backup.Contents, Error>) -> BackupError.Refusal? {
    if case .failure(BackupError.refused(let refusal)) = result { return refusal }
    return nil
}

private func file(_ path: String, _ text: String = "x") -> BackupArchive.RawEntry {
    BackupArchive.RawEntry(path: path, data: Data(text.utf8))
}

@Test func craftedPathsAreRefused() throws {
    // Apple Archive's own decoder refuses `..`, absolute paths and empty segments before fudge sees the entry.
    for path in ["../x", "/etc/x", "extension-data/alpha/../../x", "extension-data/alpha//x"] {
        let result = try crafted([file(path)])
        guard case .failure(let error) = result else {
            Issue.record("\(path) was read")
            continue
        }
        #expect(error as? BackupError == .unreadable, "\(path)")
        // fudge's own check refuses them too, should a decoder ever let one through.
        #expect(throws: BackupError.refused(.path(path))) { try Backup.part(of: path) }
    }
    #expect(refusal(try crafted([file("other/x.json")])) == .path("other/x.json"))
    #expect(refusal(try crafted([file("preferences/a/b.json")])) == .path("preferences/a/b.json"))
    #expect(refusal(try crafted([file("extension-data/alpha")])) == .path("extension-data/alpha"))
    // The store's folder is its clone of the store: never imported, in any case (#57 review).
    for path in [
        "extension-data/fudge-extension-store/repo/x", "extension-data/fudge-extension-store/REPO/.git/config",
        "extension-data/fudge-extension-store/installed.json",
    ] {
        #expect(refusal(try crafted([file(path)])) == .path(path))
    }
    #expect(
        refusal(try crafted([file("settings.json", "{}"), file("settings.json", "{}")])) == .duplicate("settings.json"))
}

@Test func craftedExtensionNamesAreRefused() throws {
    #expect(refusal(try crafted([file("preferences/.hidden.json")])) == .extensionName(".hidden"))
    #expect(refusal(try crafted([file("extension-data/Bad Name/x")])) == .extensionName("Bad Name"))
    for name in ["a/b", "..", ".hidden"] {
        let manifest =
            #"{"format":1,"fudgeVersion":"1.0","created":"2026-11-20T00:00:00Z","extensions":[{"name":"\#(name)","title":"T","source":"local"}]}"#
        #expect(throws: BackupError.refused(.extensionName(name))) {
            try Backup.contents(of: [BackupEntry(path: "manifest.json", data: Data(manifest.utf8))])
        }
    }
}

@Test func craftedLinksAndOtherEntriesAreRefused() throws {
    let symlink = BackupArchive.RawEntry(type: .link, path: "settings.json", link: "/etc/passwd")
    #expect(refusal(try crafted([symlink])) == .link)
    let hardLink = BackupArchive.RawEntry(path: "history.json", data: Data("{}".utf8), hardLinkCluster: 7)
    #expect(refusal(try crafted([hardLink])) == .link)
    #expect(refusal(try crafted([BackupArchive.RawEntry(type: .directory, path: "preferences")])) == .notAFile)
    #expect(refusal(try crafted([BackupArchive.RawEntry(type: .fifo, path: "history.json")])) == .notAFile)
}

@Test func craftedSizesAreRefusedWhileReading() throws {
    #expect(
        refusal(try crafted([file("history.json", String(repeating: "x", count: 200))], limits: (150, 10_000)))
            == .tooBig)
    let three = (1...3).map { file("preferences/e\($0).json", String(repeating: "x", count: 90)) }
    #expect(refusal(try crafted(three, limits: (150, 250))) == .tooBig, "too much in total")
    #expect(throws: Never.self) { try crafted([file("history.json", "{}")], limits: (150, 10_000)).get() }
}

@Test func aBackupWithoutAManifestIsRefused() throws {
    #expect(throws: BackupError.refused(.noManifest)) {
        try Backup.contents(of: [BackupEntry(path: "settings.json", data: Data("{}".utf8))])
    }
}

@Test func fudgesOwnBeforeImportBackupsAreReadWithoutTheSizeLimits() throws {
    let folder = try Folder()
    let paths = folder.paths
    let own = paths.backupsDirectory.appendingPathComponent("before-import-x.fudgebackup")
    #expect(Backup.readLimits(for: own, password: nil, paths: paths) == (Int.max, Int.max))
    let elsewhere = folder.url.appendingPathComponent("before-import-x.fudgebackup")
    #expect(
        Backup.readLimits(for: elsewhere, password: nil, paths: paths) == (
            BackupArchive.entryLimit, BackupArchive.totalLimit
        ))
    #expect(
        Backup.readLimits(for: own, password: "secret", paths: paths) == (
            BackupArchive.entryLimit, BackupArchive.totalLimit
        ))
    #expect(
        Backup.readLimits(for: own, password: nil, paths: nil) == (BackupArchive.entryLimit, BackupArchive.totalLimit))

    // A real before-import backup opens again, through the same call the Import button makes.
    let source = try seeded()
    let contents = try Backup.contents(
        of: Backup.collect(from: source.paths, installed: [], fudgeVersion: "1.0", now: now).entries)
    let target = try seeded()
    let result = try Backup.apply(contents, to: target.paths, installed: [], fudgeVersion: "1.0", now: now)
    #expect(try Backup.open(result.beforeImport, password: nil, paths: target.paths).root["settings.json"] != nil)
}

@Test func pathsAndEntriesAreCappedAndCountedWhileReading() throws {
    let long = "extension-data/alpha/" + String(repeating: "a/", count: 600) + "x"
    #expect(refusal(try crafted([file(long)])) == .path(String(long.prefix(80)) + "…"), "over 1,024 bytes")
    let wideSegment = "extension-data/alpha/" + String(repeating: "b", count: 300)
    #expect(
        refusal(try crafted([file(wideSegment)])) == .path(String(wideSegment.prefix(80)) + "…"), "a 300-byte segment")
    // Path bytes count toward the total: long valid paths with no data still run out of room.
    let paths = (1...6).map { file("extension-data/alpha/\(String(repeating: "p", count: 200))\($0)", "") }
    #expect(refusal(try crafted(paths, limits: (1_000, 1_000))) == .tooBig)

    let folder = try Folder()
    let archive = folder.url.appendingPathComponent("many.fudgebackup")
    try BackupArchive.writeRaw((1...5).map { file("extension-data/alpha/\($0)") }, to: archive, password: password)
    #expect(throws: BackupError.refused(.tooBig)) {
        try BackupArchive.read(from: archive, password: password, entryCountLimit: 4)
    }
    // Each path is checked as it's read, before the entries after it.
    let seen = Counter()
    try BackupArchive.writeRaw(
        [file("history.json", "{}"), file("../escape"), file("history.json", "{}")], to: archive, password: nil)
    #expect(throws: BackupError.self) {
        try BackupArchive.read(
            from: archive, password: nil,
            checkPath: {
                _ = seen.next()
                _ = try Backup.part(of: $0)
            })
    }
    #expect(seen.next() <= 3, "stopped at the refused path")
}

@Test func aNewerFormatIsRefusedBeforeItsPathsAreJudged() throws {
    let folder = try Folder()
    let archive = folder.url.appendingPathComponent("newer.fudgebackup")
    let manifest = file(
        "manifest.json", #"{"format":2,"fudgeVersion":"9.0","created":"2030-01-01T00:00:00Z","extensions":[]}"#)
    try BackupArchive.writeRaw([manifest, file("future/thing.json", "{}")], to: archive, password: password)
    #expect(throws: BackupError.newerFormat(2)) { try Backup.open(archive, password: password) }
}

@Test func settingsAndKeyedFilesMustBeJSONObjects() throws {
    #expect(refusal(try crafted([file("settings.json", "[1, 2]")])) == .invalidPart("settings.json"))
    #expect(refusal(try crafted([file("dropdown-values.json", "not json")])) == .invalidPart("dropdown-values.json"))
    #expect(refusal(try crafted([file("quicklinks.json", "[1, 2]")])) == .invalidPart("quicklinks.json"))
    #expect(throws: Never.self) { try crafted([file("history.json", "[1, 2]")]).get() }
}

@Test func theBeforeImportBackupJustWrittenIsKeptEvenIfTheClockWentBack() throws {
    let contents = try Backup.contents(
        of: Backup.collect(from: try seeded().paths, installed: [], fudgeVersion: "1.0", now: now).entries)
    let target = try Folder()
    for minute in 0..<3 {
        _ = try Backup.apply(
            contents, to: target.paths, installed: [], fudgeVersion: "1.0",
            now: now.addingTimeInterval(Double(minute) * 60))
    }
    let earlier = try Backup.apply(
        contents, to: target.paths, installed: [], fudgeVersion: "1.0", now: now.addingTimeInterval(-86_400))
    let kept = try FileManager.default.contentsOfDirectory(atPath: target.paths.backupsDirectory.path)
    #expect(kept.count == 3 && kept.contains(earlier.beforeImport.lastPathComponent))
}

// MARK: - What changed since the backup

/// A backup listing `extensions`, with nothing else in it.
private func listing(_ extensions: [Backup.Listed]) -> Backup.Contents {
    Backup.Contents(
        manifest: Backup.Manifest(format: 1, fudgeVersion: "1.0", created: now, extensions: extensions), root: [:],
        perExtension: [:], data: [:], hadExtensionStore: false)
}

/// A support folder whose Extension Store recorded `trees` as its installs.
private func storeFolder(_ trees: [String: String]) throws -> Folder {
    let folder = try Folder()
    let records = trees.map {
        #""\#($0.key)":{"tree":"\#($0.value)","commit":"c","installedAt":"2026-11-20T10:00:00Z"}"#
    }
    try folder.write(
        "extension-data/fudge-extension-store/installed.json", "{\(records.sorted().joined(separator: ","))}")
    return folder
}

@Test func aBackupRecordsTheStoreTreeOfTheStoresInstallsOnly() throws {
    let folder = try storeFolder(["alpha": "tree-a"])
    let export = Backup.collect(
        from: folder.paths,
        installed: [try installed("alpha", title: "Alpha"), try installed("beta", title: "Beta", version: "2.0")],
        fudgeVersion: "1.0", now: now)
    #expect(
        export.manifest.extensions == [
            Backup.Listed(name: "alpha", title: "Alpha", version: nil, source: .store, storeTree: "tree-a"),
            Backup.Listed(name: "beta", title: "Beta", version: "2.0", source: .local, storeTree: nil),
        ])
    let manifest = try #require(export.entries.first { $0.path == "manifest.json" })
    let extensions = try #require(
        (try JSONSerialization.jsonObject(with: manifest.data) as? [String: Any])?["extensions"] as? [[String: Any]])
    #expect(extensions[0]["storeTree"] as? String == "tree-a")
    #expect(extensions[1].keys.contains("storeTree") == false, "a local build has no key at all")
    #expect(export.manifest.format == 1, "the key is optional, so the format stays 1")
}

@Test func aStoreRecordWithoutATreeStillCountsAsTheStores() throws {
    let folder = try Folder()
    try folder.write(
        "extension-data/fudge-extension-store/installed.json", #"{"alpha":{"commit":"c"},"../x":{"tree":"t"}}"#)
    #expect(Backup.storeInstalls(folder.paths) == ["alpha": Backup.StoreInstall(tree: nil)])
    #expect(
        Backup.listed([try installed("alpha", title: "Alpha")], paths: folder.paths)
            == [Backup.Listed(name: "alpha", title: "Alpha", version: nil, source: .store, storeTree: nil)])
}

@Test func anOldManifestWithoutStoreTreesStillReads() throws {
    let json = #"""
        {"format":1,"fudgeVersion":"0.9","created":"2026-11-20T10:00:00Z","extensions":[
          {"name":"alpha","title":"Alpha","source":"store"},{"name":"beta","title":"Beta","version":"1.0","source":"local"}]}
        """#
    let manifest = try #require(Backup.decodeManifest(Data(json.utf8)))
    #expect(manifest.extensions.map(\.storeTree) == [nil, nil])
    let folder = try storeFolder(["alpha": "tree-now"])
    let changed = Backup.changedExtensions(
        listing(manifest.extensions),
        installed: [try installed("alpha", title: "Alpha"), try installed("beta", title: "Beta", version: "1.0")],
        paths: folder.paths)
    #expect(changed.isEmpty, "no tree in the backup, the same version: it can't tell, so nothing is flagged")
}

@Test func eachRuleFlagsAChangedExtension() throws {
    let folder = try storeFolder(["alpha": "tree-2", "beta": "tree-2", "gamma": "tree-1"])
    let backup = listing([
        // 1. Both have a version, and they differ.
        Backup.Listed(name: "alpha", title: "Alpha", version: "1.2.0", source: .store, storeTree: "tree-1"),
        // 2. The same version (or none), and both have a tree, and they differ.
        Backup.Listed(name: "beta", title: "Beta", version: nil, source: .store, storeTree: "tree-1"),
        // 3. Local then, the store's now.
        Backup.Listed(name: "gamma", title: "Gamma", version: "1.0", source: .local, storeTree: nil),
        // 3. The store's then, local now.
        Backup.Listed(name: "delta", title: "Delta", version: nil, source: .store, storeTree: "tree-1"),
        // Nothing to tell: unchanged.
        Backup.Listed(name: "epsilon", title: "Epsilon", version: "3.0", source: .local, storeTree: nil),
    ])
    let changed = Backup.changedExtensions(
        backup,
        installed: [
            try installed("alpha", title: "Alpha", version: "1.3.0"), try installed("beta", title: "Beta"),
            try installed("gamma", title: "Gamma", version: "1.0"), try installed("delta", title: "Delta"),
            try installed("epsilon", title: "Epsilon", version: "3.0"),
        ],
        paths: folder.paths)
    #expect(
        changed.map { "\($0.title) — \($0.text)" } == [
            "Alpha — version 1.2.0 in the backup, 1.3.0 now",
            "Beta — updated in the Extension Store since the backup",
            "Delta — installed from a local folder now",
            "Gamma — installed from the Extension Store now",
        ], "one line each, sorted by title")
}

@Test func theFirstRuleThatAppliesGivesTheReason() {
    func listed(_ version: String?, _ source: Backup.Listed.Source, _ tree: String?) -> Backup.Listed {
        Backup.Listed(name: "alpha", title: "Alpha", version: version, source: source, storeTree: tree)
    }
    // A version change wins over a tree and a source change.
    #expect(
        Backup.changeReason(from: listed("1", .store, "t1"), to: listed("2", .store, "t2"))
            == .version(backup: "1", now: "2"))
    #expect(
        Backup.changeReason(from: listed("1", .store, "t1"), to: listed("2", .local, nil))
            == .version(backup: "1", now: "2"))
    // The same version: the tree decides.
    #expect(Backup.changeReason(from: listed("1", .store, "t1"), to: listed("1", .store, "t2")) == .storeUpdated)
    // A version on one side only can't tell, so the tree does.
    #expect(Backup.changeReason(from: listed(nil, .store, "t1"), to: listed("2", .store, "t2")) == .storeUpdated)
    // A tree on one side only can't tell, so the source does.
    #expect(
        Backup.changeReason(from: listed(nil, .store, "t1"), to: listed(nil, .local, nil)) == .source(now: .local))
    #expect(Backup.changeReason(from: listed(nil, .store, nil), to: listed(nil, .store, "t2")) == nil)
    #expect(Backup.changeReason(from: listed("1", .local, nil), to: listed("1", .local, nil)) == nil)
}

@Test func onlyInstalledExtensionsMatchedByNameAreFlaggedWithTheirCurrentTitle() throws {
    let folder = try storeFolder(["alpha": "tree-2"])
    let backup = listing([
        Backup.Listed(name: "alpha", title: "Old Title", version: nil, source: .store, storeTree: "tree-1"),
        Backup.Listed(name: "alpha", title: "Repeated", version: "9", source: .local, storeTree: nil),
        Backup.Listed(name: "gone", title: "Gone", version: "1.0", source: .local, storeTree: nil),
        Backup.Listed(
            name: ExtensionStore.extensionName, title: "Extension Store", version: "1", source: .local, storeTree: nil),
    ])
    let changed = Backup.changedExtensions(
        backup,
        installed: [
            try installed("alpha", title: "Alpha Now"),
            try installed(ExtensionStore.extensionName, title: "Extension Store", version: "2"),
        ],
        paths: folder.paths)
    #expect(
        changed == [Backup.Changed(name: "alpha", title: "Alpha Now", reason: .storeUpdated)],
        "not-installed ones are the import's other list; the bundled store is never flagged; a name counts once")
}

@Test func aBuiltInCommandsHotkeyAliasAndEnabledSurviveABackup() throws {
    let source = try Folder()
    try source.write(
        "settings.json",
        #"{"commands":{":test-tools/first":{"hotkey":"option+l","alias":"tf"}},"extensions":{":test-tools":{"enabled":false}}}"#
    )
    let file = source.url.appendingPathComponent("b.fudgebackup")
    try BackupArchive.write(
        Backup.collect(from: source.paths, installed: [], fudgeVersion: "1.0", now: now).entries, to: file,
        password: password)
    let target = try Folder()
    _ = try Backup.apply(
        try Backup.open(file, password: password), to: target.paths, installed: [], fudgeVersion: "1.0", now: now)
    let settings = FudgeSettings.load(from: target.paths.settingsFile)
    #expect(settings.commands[":test-tools/first"]?.hotkey == "option+l")
    #expect(settings.commands[":test-tools/first"]?.alias == "tf")
    #expect(!settings.isEnabled(extension: ":test-tools"))
}

@Test func snippetsGoIntoABackupAndAreCounted() throws {
    let source = try Folder()
    try source.write(
        "snippets.json", #"{"snippets":[{"id":"a","name":"Address","text":"1 Main St","keyword":"/addr"}]}"#)
    let export = Backup.collect(from: source.paths, installed: [], fudgeVersion: "1.0", now: now)
    #expect(export.summary.snippets == 1)
    #expect(export.summary.text.contains("1 snippet"))
    let file = source.url.appendingPathComponent("b.fudgebackup")
    try BackupArchive.write(export.entries, to: file, password: password)
    let contents = try Backup.open(file, password: password)
    #expect(contents.summary.snippets == 1)
    let target = try Folder()
    _ = try Backup.apply(contents, to: target.paths, installed: [], fudgeVersion: "1.0", now: now)
    #expect(SnippetStore.load(from: target.paths.snippetsFile).snippets.map(\.keyword) == ["/addr"])
    let manifest = #"{"format":1,"fudgeVersion":"1","created":"2026-01-01T00:00:00Z","extensions":[]}"#
    #expect(throws: BackupError.self, "a snippets.json that isn't an object is refused") {
        try Backup.contents(of: [
            BackupEntry(path: "manifest.json", data: Data(manifest.utf8)),
            BackupEntry(path: "snippets.json", data: Data("[1]".utf8)),
        ])
    }
}
