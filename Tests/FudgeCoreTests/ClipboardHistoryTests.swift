import Foundation
import Testing

@testable import FudgeCore

/// Runs a mutating call outside `#expect`, which can't hold one.
private func step<T>(_ body: () -> T) -> T { body() }

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let safari = ClipboardSource(bundleId: "com.apple.Safari", name: "Safari")
private func png(_ byte: UInt8, count: Int = 64) -> Data { Data(repeating: byte, count: count) }

// MARK: - Recording

@Test func eachKindOfCopyIsKeptNewestFirst() {
    var history = ClipboardHistory()
    _ = history.record(.text("hello"), source: safari, now: start)
    _ = history.record(.link("https://example.com"), source: nil, now: start + 1)
    _ = history.record(.image(png: png(1), width: 3, height: 2), source: nil, now: start + 2)
    _ = history.record(.files(["/Users/someone/a.pdf", "/Users/someone/b.pdf"]), source: nil, now: start + 3)
    #expect(history.entries.map(\.kind) == [.files, .image, .link, .text])
    #expect(history.entries[3].text == "hello" && history.entries[3].source == safari && history.entries[3].size == 5)
    #expect(history.entries[2].text == "https://example.com")
    #expect(history.entries[1].size == 64 && history.entries[1].name == "Image (3×2)")
    #expect(history.entries[0].size == 2 && history.entries[0].name == "a.pdf")
}

@Test func emptyCopiesAreNotKept() {
    var history = ClipboardHistory()
    #expect(step { history.record(.text("  \n\t "), source: nil, now: start) } == .init())
    #expect(step { history.record(.files([]), source: nil, now: start) } == .init())
    #expect(history.entries.isEmpty)
}

@Test func aCopyTheHistoryHoldsMovesItsEntryToTheTop() {
    var history = ClipboardHistory()
    _ = history.record(.text("first"), source: nil, now: start, id: "a")
    _ = history.record(.text("second"), source: nil, now: start + 1, id: "b")
    _ = history.setPinned(true, id: "a")
    let again = step { history.record(.text("first"), source: safari, now: start + 2, id: "c") }
    #expect(again.recorded?.id == "a", "the same entry, not a new one")
    #expect(history.entries.map(\.id) == ["a", "b"])
    #expect(history.entries[0].copiedAt == start + 2 && history.entries[0].source == safari)
    #expect(history.entries[0].pinned, "a pin stays")

    _ = history.record(.image(png: png(7), width: 1, height: 1), source: nil, now: start + 3, id: "i1")
    _ = history.record(.text("between"), source: nil, now: start + 4)
    #expect(
        step { history.record(.image(png: png(7), width: 1, height: 1), source: nil, now: start + 5) }.recorded?.id
            == "i1")
    #expect(history.entries.filter { $0.kind == .image }.count == 1, "the same image is found by its digest")
}

@Test func textOver1MBIsKeptCutAndMarked() {
    var history = ClipboardHistory()
    let big = String(repeating: "é", count: ClipboardHistory.textLimit)  // 2 bytes each
    _ = history.record(.text(big), source: nil, now: start)
    let entry = history.entries[0]
    #expect(entry.truncated)
    #expect(entry.text!.utf8.count <= ClipboardHistory.textLimit)
    #expect(entry.text!.utf8.count > ClipboardHistory.textLimit - 2, "cut at a character, not in the middle of one")
    #expect(entry.json.objectValue?["truncated"] == .bool(true))

    _ = history.record(.text("small"), source: nil, now: start + 1)
    #expect(!history.entries[0].truncated)
    #expect(history.entries[0].json.objectValue?["truncated"] == nil)
}

@Test func anImageOver10MBIsNotKept() {
    var history = ClipboardHistory()
    let huge = Data(count: ClipboardHistory.imageLimit + 1)
    #expect(step { history.record(.image(png: huge, width: 1, height: 1), source: nil, now: start) }.recorded == nil)
    #expect(history.entries.isEmpty)
}

@Test func theOldestUnpinnedGoPast1000Entries() {
    var history = ClipboardHistory()
    _ = history.record(.text("pinned"), source: nil, now: start, id: "pinned")
    _ = history.setPinned(true, id: "pinned")
    _ = history.record(.text("oldest unpinned"), source: nil, now: start + 1, id: "old")
    for index in 0..<ClipboardHistory.entryLimit - 1 {
        _ = history.record(.text("copy \(index)"), source: nil, now: start + 2 + Double(index))
    }
    #expect(history.entries.count == ClipboardHistory.entryLimit)
    #expect(history.entry(id: "pinned") != nil, "pinned entries are kept")
    #expect(history.entry(id: "old") == nil)
}

@Test func imagesTogetherStayUnder500MBOldestUnpinnedFirst() {
    var history = ClipboardHistory()
    let size = 9 * 1024 * 1024
    var files: [String] = []
    _ = history.record(
        .image(png: Data(repeating: 0, count: size), width: 1, height: 1), source: nil, now: start, id: "keep")
    _ = history.setPinned(true, id: "keep")
    var removed: [String] = []
    for index in 1...60 {
        let change = history.record(
            .image(png: Data(repeating: UInt8(index), count: size), width: 1, height: 1), source: nil,
            now: start + Double(index), id: "image-\(index)")
        files.append(change.recorded!.imageFile!)
        removed += change.removedImages
    }
    let total = history.entries.filter { $0.kind == .image }.reduce(0) { $0 + $1.size }
    #expect(total <= ClipboardHistory.imagesLimit)
    #expect(history.entry(id: "keep") != nil, "pinned images are kept")
    #expect(history.entry(id: "image-1") == nil && history.entry(id: "image-60") != nil)
    #expect(removed == Array(files.prefix(removed.count)), "the dropped images' files, oldest first, for the store")
}

@Test func keepForDropsOldUnpinnedEntries() {
    var history = ClipboardHistory()
    _ = history.record(.text("old"), source: nil, now: start, id: "old")
    _ = history.record(.image(png: png(2), width: 1, height: 1), source: nil, now: start, id: "old-image")
    _ = history.record(.text("old pinned"), source: nil, now: start, id: "pinned")
    _ = history.setPinned(true, id: "pinned")
    _ = history.record(.text("recent"), source: nil, now: start + 6 * 86400, id: "recent")
    let change = step { history.prune(now: start + 7 * 86400 + 1, keepForDays: 7) }
    #expect(history.entries.map(\.id) == ["recent", "pinned"])
    #expect(change.removedImages.count == 1)
    #expect(ClipboardHistory.keepForChoices == [1, 7, 30, 90] && ClipboardHistory.defaultKeepFor == 7)
}

@Test func pinsDeletesAndClear() {
    var history = ClipboardHistory()
    _ = history.record(.text("a"), source: nil, now: start, id: "a")
    _ = history.record(.image(png: png(3), width: 1, height: 1), source: nil, now: start + 1, id: "b")
    #expect(step { history.setPinned(true, id: "a") })
    #expect(!step { history.setPinned(true, id: "missing") })
    #expect(step { history.delete(id: "b") }.removedImages.count == 1)
    #expect(history.entries.map(\.id) == ["a"])
    _ = history.record(.image(png: png(4), width: 1, height: 1), source: nil, now: start + 2)
    #expect(step { history.clear() }.removedImages.count == 1)
    #expect(history.entries.isEmpty, "Delete All takes pinned ones too")
}

@Test func offsetCountsBackFromTheNewestWhatEverIsPinned() {
    var history = ClipboardHistory()
    _ = history.record(.text("one"), source: nil, now: start, id: "1")
    _ = history.record(.text("two"), source: nil, now: start + 1, id: "2")
    _ = history.record(.text("three"), source: nil, now: start + 2, id: "3")
    _ = history.setPinned(true, id: "1")
    #expect(history.entry(offset: 0)?.id == "3")
    #expect(history.entry(offset: 1)?.id == "2")
    #expect(history.entry(offset: 2)?.id == "1")
    #expect(history.entry(offset: 3) == nil && history.entry(offset: -1) == nil)
}

@Test func theListAnswersTheContractsShape() {
    var history = ClipboardHistory()
    _ = history.record(.text("hello"), source: safari, now: Date(timeIntervalSince1970: 0), id: "t")
    #expect(
        history.listJSON(on: true)
            == .object([
                "on": .bool(true),
                "entries": .array([
                    .object([
                        "id": .string("t"), "kind": .string("text"), "text": .string("hello"),
                        "copiedAt": .object(["$date": .string("1970-01-01T00:00:00.000Z")]), "size": .number(5),
                        "pinned": .bool(false),
                        "app": .object(["bundleId": .string("com.apple.Safari"), "name": .string("Safari")]),
                    ])
                ]),
            ]))
    #expect(history.listJSON(on: false) == .object(["on": .bool(false), "entries": .array([])]), "nothing while off")
}

// MARK: - What's skipped

@Test func markedFudgesOwnAndIgnoredAppsCopiesAreSkipped() {
    func reason(_ types: Set<String>, count: Int = 5, frontmost: String? = "com.apple.TextEdit") -> ClipboardSkip? {
        ClipboardSkip.reason(
            types: types, changeCount: count, isOwn: { $0 == 9 }, frontmost: frontmost,
            ignored: ["com.agilebits.onepassword7"])
    }
    #expect(reason(["public.utf8-plain-text"]) == nil)
    #expect(reason(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]) == .marked)
    #expect(reason(["org.nspasteboard.TransientType"]) == .marked)
    #expect(reason(["org.nspasteboard.AutoGeneratedType"]) == .marked)
    #expect(reason(["public.utf8-plain-text"], count: 9) == .fudge)
    #expect(reason(["public.utf8-plain-text"], frontmost: "com.agilebits.onepassword7") == .ignoredApp)
    #expect(reason(["public.utf8-plain-text"], frontmost: nil) == nil)
}

@Test @MainActor func theTurnsRememberFudgesOwnRecentWrites() {
    let turns = PasteboardTurns()
    #expect(!turns.isBusy)
    for count in 1...40 { turns.markOwn(count) }
    #expect(turns.isOwn(40) && turns.isOwn(9))
    #expect(!turns.isOwn(8), "only the last \(PasteboardTurns.ownLimit)")
}

// MARK: - The switch and settings

@Test func theSwitchNeedsItsConsentAndTheSettingsRoundTrip() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    var settings = FudgeSettings()
    #expect(!settings.isClipboardHistoryOn)
    settings.clipboardHistory = true
    #expect(!settings.isClipboardHistoryOn, "a hand-set switch without the consent date is off")
    settings.setClipboardHistory(true, now: start)
    settings.clipboardHistoryKeepDays = 30
    settings.clipboardHistoryIgnoredApps = ["com.agilebits.onepassword7"]
    try settings.save(to: file)
    let read = FudgeSettings.load(from: file)
    #expect(read.isClipboardHistoryOn && read.clipboardHistoryKeepDays == 30)
    #expect(read.clipboardHistoryIgnoredApps == ["com.agilebits.onepassword7"])

    var off = read
    off.setClipboardHistory(false, now: start)
    try off.save(to: file)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    #expect(object?["clipboardHistory"] == nil && object?["clipboardHistoryConsentAt"] == nil)

    try Data(#"{ "clipboardHistoryKeepDays": 12 }"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file).clipboardHistoryKeepDays == 7, "only Keep For's choices")
    #expect(Backup.consentKeys.contains("clipboardHistory") && Backup.consentKeys.contains("clipboardHistoryConsentAt"))
}

// MARK: - Storage

private func store() throws -> (ClipboardHistoryStore, MemorySecretStore, FudgePaths) {
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let secrets = MemorySecretStore()
    return (ClipboardHistoryStore(paths: paths, secrets: secrets), secrets, paths)
}

@Test func theHistoryIsKeptEncryptedWithItsKeyInTheKeychain() throws {
    let (store, secrets, _) = try store()
    var history = ClipboardHistory()
    _ = history.record(.text("secret words"), source: safari, now: start)
    let image = history.record(.image(png: png(9), width: 2, height: 2), source: nil, now: start + 1).recorded!
    try store.save(history)
    try store.writeImage(png(9), file: image.imageFile!)

    #expect(try store.load() == history)
    #expect(try store.readImage(file: image.imageFile!) == png(9))
    #expect(try secrets.read(account: ClipboardHistoryStore.keyAccount)?.count == 32)

    let raw = try Data(contentsOf: store.folder.appendingPathComponent(ClipboardHistoryStore.historyFile))
    #expect(raw.range(of: Data("secret words".utf8)) == nil, "never in the clear")
    let attributes = try FileManager.default.attributesOfItem(atPath: store.folder.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o700)
    let fileAttributes = try FileManager.default.attributesOfItem(
        atPath: store.folder.appendingPathComponent(ClipboardHistoryStore.historyFile).path)
    #expect((fileAttributes[.posixPermissions] as? Int) == 0o600)

    store.deleteImages([image.imageFile!])
    #expect(throws: (any Error).self) { try store.readImage(file: image.imageFile!) }
    try store.deleteAll()
    #expect(!FileManager.default.fileExists(atPath: store.folder.path))
    #expect(try secrets.read(account: ClipboardHistoryStore.keyAccount) == nil, "Delete History takes the key too")
}

@Test func aMissingKeyOrADamagedFileStartsEmptyAndKeepsTheFileAside() throws {
    let (store, secrets, _) = try store()
    var history = ClipboardHistory()
    _ = history.record(.text("kept"), source: nil, now: start)
    try store.save(history)

    try secrets.delete(account: ClipboardHistoryStore.keyAccount)
    #expect(try store.load(now: start).entries.isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: store.folder.path)
    #expect(names.contains { $0.hasPrefix("\(ClipboardHistoryStore.historyFile).unreadable-") })
    #expect(!names.contains(ClipboardHistoryStore.historyFile))

    try store.save(history)  // a new key
    let file = store.folder.appendingPathComponent(ClipboardHistoryStore.historyFile)
    var damaged = try Data(contentsOf: file)
    damaged[damaged.count - 1] ^= 0xFF
    try damaged.write(to: file)
    #expect(try store.load(now: start + 1).entries.isEmpty)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: store.folder.path).filter { $0.contains(".unreadable-") }
            .count == 2)
}

@Test func oneSealedFileCantStandInForAnother() throws {
    let (store, _, _) = try store()
    try store.writeImage(png(1), file: "a.png")
    try store.writeImage(png(2), file: "b.png")
    let a = store.folder.appendingPathComponent("a.png.enc")
    let b = store.folder.appendingPathComponent("b.png.enc")
    try FileManager.default.removeItem(at: b)
    try FileManager.default.copyItem(at: a, to: b)
    #expect(throws: (any Error).self) { try store.readImage(file: "b.png") }
}

@Test func backupsLeaveTheHistoryOut() throws {
    let (store, _, paths) = try store()
    var history = ClipboardHistory()
    _ = history.record(.text("never exported"), source: nil, now: start)
    try store.save(history)
    try Data("{}".utf8).write(to: paths.settingsFile)
    let export = Backup.collect(from: paths, installed: [], fudgeVersion: "1.0", now: start)
    #expect(!export.entries.isEmpty, "the settings are there")
    #expect(!export.entries.contains { $0.path.hasPrefix(ClipboardHistoryStore.folderName) })
}

extension JSONValue {
    fileprivate var objectValue: [String: JSONValue]? { if case .object(let object) = self { object } else { nil } }
}

@Test func anEntryGoesBackOnThePasteboardAsItWasCopied() throws {
    var history = ClipboardHistory()
    _ = history.record(.link("https://example.com"), source: nil, now: start, id: "l")
    _ = history.record(.files(["/tmp/a b.pdf", "/tmp/c.txt"]), source: nil, now: start, id: "f")
    _ = history.record(.image(png: png(5), width: 1, height: 1), source: nil, now: start, id: "i")
    let link = try #require(history.entry(id: "l")?.contents(forPaste: false))
    #expect(link.items.map { $0.map(\.type) } == [["public.url", "public.utf8-plain-text"]])
    let files = try #require(history.entry(id: "f")?.contents(forPaste: false))
    #expect(files.items.count == 2)
    #expect(String(decoding: files.items[0][0].data, as: UTF8.self) == "file:///tmp/a%20b.pdf")
    #expect(history.entry(id: "i")?.contents(forPaste: false) == nil, "an image needs its PNG")
    let image = try #require(history.entry(id: "i")?.contents(image: png(5), forPaste: true))
    #expect(
        image.items[0].map(\.type) == [
            "public.png", PasteboardContents.transientType, PasteboardContents.autoGeneratedType,
        ])
}

@Test func snapshotEntriesReadTheListsOwnShape() {
    var history = ClipboardHistory()
    _ = history.record(.text("hello"), source: safari, now: Date(timeIntervalSince1970: 0), id: "t")
    _ = history.record(.files(["/tmp/a.pdf"]), source: nil, now: Date(timeIntervalSince1970: 0), id: "f")
    _ = history.setPinned(true, id: "f")
    for entry in history.entries {
        #expect(ClipboardEntry(json: entry.json) == entry)
    }
    #expect(ClipboardEntry(json: .object(["id": .string("x")])) == nil)
}

@Test func theListSendsLongTextsCutButKeepsThemWhole() throws {
    var history = ClipboardHistory()
    let long = String(repeating: "a", count: ClipboardHistory.listTextLimit + 5)
    _ = history.record(.text(long), source: nil, now: start, id: "long")
    guard case .object(let list) = history.listJSON(on: true), case .array(let entries) = list["entries"],
        case .object(let entry) = entries.first, case .string(let text) = entry["text"]
    else {
        Issue.record("no entry")
        return
    }
    #expect(text.count == ClipboardHistory.listTextLimit && entry["truncated"] == .bool(true))
    #expect(history.entry(id: "long")?.text == long, "Paste and Copy get it all")
}

@Test func clipboardHistoryHasASettingsPageForItsSwitch() throws {
    let resources = try Fixtures.temporaryDirectory()
    let folder = resources.appendingPathComponent("clipboard-history-extension")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest =
        #"{ "name": "fudge-clipboard-history", "title": "Clipboard History", "commands": [ { "name": "clipboard-history", "title": "Clipboard History", "mode": "view" } ] }"#
    try Data(manifest.utf8).write(to: folder.appendingPathComponent("package.json"))
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let installed = InstalledExtension.all(paths: paths, resources: resources)
    #expect(installed.map(\.manifest.name) == [ClipboardHistory.extensionName])
    #expect(InstalledExtension.settingsPages(of: installed).map(\.manifest.name) == [ClipboardHistory.extensionName])
    #expect(
        FudgeSettings().isEnabled(extension: ClipboardHistory.extensionName), "the command is there; the switch decides"
    )
}

@Test func anOffsetReadsOnlyRaycastsSixAndNeverTraps() {
    func offset(_ value: JSONValue?) -> ClipboardOffset {
        var object: [String: JSONValue] = [:]
        if let value { object["offset"] = value }
        return ClipboardOffset(params: .object(object))
    }
    #expect(offset(nil) == .current)
    #expect(offset(.number(0)) == .current)
    #expect(offset(.number(-3)) == .current)
    #expect(offset(.number(-1e300)) == .current)
    #expect(offset(.number(1)) == .previous(1))
    #expect(offset(.number(5)) == .previous(5))
    #expect(offset(.number(6)) == .none, "Raycast's maximum is 5, so nothing pages through the history")
    #expect(offset(.number(999)) == .none)
    #expect(offset(.number(1e300)) == .none, "no Int(1e300), which traps")
    #expect(offset(.number(2.5)) == .none)
    #expect(offset(.number(.nan)) == .current)
    #expect(offset(.number(.infinity)) == .none)
    #expect(offset(.string("2")) == .current)
    #expect(ClipboardOffset(params: .null) == .current)
}

@Test func onlyClipboardHistoryMayCallItsCalls() {
    #expect(ClipboardHistory.mayCall("fudge-clipboard-history"))
    for caller in [
        "fudge-file-search", "fudge-extension-store", "clipboard-history", "fudge-clipboard-history2", "", nil,
    ]
        as [String?]
    {
        #expect(!ClipboardHistory.mayCall(caller), "\(caller ?? "nil")")
    }
}

/// A Keychain that fails to read, as a locked one does.
private final class FailingSecretStore: SecretStore, @unchecked Sendable {
    struct Locked: Error {}
    let inner = MemorySecretStore()
    var failing = false
    func read(account: String) throws -> Data? {
        if failing { throw Locked() }
        return try inner.read(account: account)
    }
    func write(_ data: Data, account: String) throws { try inner.write(data, account: account) }
    func delete(account: String) throws { try inner.delete(account: account) }
    func accounts() throws -> [String] { try inner.accounts() }
}

@Test func aKeychainErrorIsntAMissingKeyAndLeavesTheHistoryWhereItIs() throws {
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let secrets = FailingSecretStore()
    let store = ClipboardHistoryStore(paths: paths, secrets: secrets)
    var history = ClipboardHistory()
    _ = history.record(.text("kept"), source: nil, now: start)
    try store.save(history)

    secrets.failing = true
    #expect(throws: ClipboardStoreError.self) { try store.load() }
    #expect(throws: (any Error).self) { try store.save(ClipboardHistory()) }
    let names = try FileManager.default.contentsOfDirectory(atPath: store.folder.path)
    #expect(names.contains(ClipboardHistoryStore.historyFile) && !names.contains { $0.contains(".unreadable-") })

    secrets.failing = false
    #expect(try store.load() == history, "readable again once the Keychain is")
}

@Test func anImageFilesNameSaysNothingAboutTheImage() {
    var history = ClipboardHistory()
    let entry = history.record(.image(png: png(8), width: 1, height: 1), source: nil, now: start).recorded!
    let digest = ClipboardHistoryStore.digest(png(8))
    #expect(entry.imageDigest == digest)
    #expect(!(entry.imageFile ?? "").contains(digest))
}

@Test func whileTheKeychainDoesntAnswerNothingReplacesTheHistory() throws {
    // The review's sequence: a pinned entry saved, the Keychain failing, a copy, the Keychain back, another copy.
    let paths = FudgePaths(supportDirectory: try Fixtures.temporaryDirectory())
    let secrets = FailingSecretStore()
    let store = ClipboardHistoryStore(paths: paths, secrets: secrets)
    var saved = ClipboardHistory()
    _ = saved.record(.text("pinned"), source: nil, now: start, id: "pinned")
    _ = saved.setPinned(true, id: "pinned")
    try store.save(saved)

    var keeper = ClipboardHistoryKeeper()
    secrets.failing = true
    #expect(!step { keeper.ensureLoaded(from: store) })
    let locked = step { keeper.change(from: store) { $0.record(.text("while locked"), source: nil, now: start + 1) } }
    #expect(locked == nil)
    #expect(!keeper.loaded && keeper.history.entries.isEmpty, "nothing recorded, so nothing to save over the file")

    secrets.failing = false
    let change = step { keeper.change(from: store) { $0.record(.text("after"), source: nil, now: start + 2) } }
    #expect(change?.recorded?.text == "after")
    try store.save(keeper.history)
    #expect(try store.load().entries.map(\.id).contains("pinned"), "the old pinned entry survives")
    #expect(keeper.history.entries.map(\.text) == ["after", "pinned"])

    keeper.reset()
    #expect(keeper.loaded && keeper.history.entries.isEmpty)
    #expect(ClipboardHistoryKeeper(fixed: saved).loaded)
}
