import AppKit
import FudgeCore

/// Clipboard history in the app (SPEC-077): while it's on, it watches the pasteboard and records each copy
/// (`ClipboardHistory`, core), keeps the history encrypted (`ClipboardHistoryStore`), prunes it by **Keep For** at
/// start and hourly, and answers the bundled Clipboard History's `clipboardHistory.*` calls and any extension's
/// `Clipboard.read({ offset })`.
@MainActor
final class ClipboardHistoryService {
    private let paths: FudgePaths
    private let store: ClipboardHistoryStore
    private let turns: PasteboardTurns
    /// The history, changed only once it has been read (`ClipboardHistoryKeeper`).
    private var keeper: ClipboardHistoryKeeper
    private var settings = FudgeSettings()
    private var watching: Task<Void, Never>?
    private var pruning: Timer?
    /// Decrypted image copies for the command's detail pane, in a private folder deleted when it's done with them.
    private var previews: URL?
    /// Saves, image writes and deletions run in order, off the main thread.
    private let saving = DispatchQueue(label: "Clipboard History saving", qos: .utility)
    private var swept = false
    /// The change count last looked at.
    private var lastChange = NSPasteboard.general.changeCount
    /// A snapshot run's fixed history, which counts as on and is never saved or watched.
    private let fixed: Bool

    /// Snapshot runs give fixed entries, never the real clipboard (`--clipboard-entries`).
    init(paths: FudgePaths, secrets: any SecretStore, turns: PasteboardTurns, fixed: ClipboardHistory? = nil) {
        self.paths = paths
        self.store = ClipboardHistoryStore(paths: paths, secrets: secrets)
        self.turns = turns
        self.fixed = fixed != nil
        self.keeper = ClipboardHistoryKeeper(fixed: fixed)
    }

    var isOn: Bool { fixed || settings.isClipboardHistoryOn }

    /// Snapshot runs' made-up history: a JSON array of `clipboardHistory.list` entries.
    static func fixedHistory(from file: URL) -> ClipboardHistory {
        guard let data = try? Data(contentsOf: file), case .array(let entries) = try? JSONValue.parse(data) else {
            return ClipboardHistory()
        }
        return ClipboardHistory(fixed: entries.compactMap(ClipboardEntry.init(json:)))
    }

    /// Reads the settings again and starts or stops watching to match. Called at launch and whenever Settings
    /// changes something.
    func apply(_ settings: FudgeSettings, watch: Bool = true) {
        self.settings = settings
        guard settings.isClipboardHistoryOn, watch, !fixed else {
            stopWatching()
            return
        }
        loadIfNeeded()
        prune()
        sweepStalePreviews()
        guard watching == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                // Cheap enough to read each time; the copy itself is read only when this moves.
                let count = await Self.changeCount()
                if count != self.lastChange { self.changed(to: count) }
            }
        }
        pruning = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    private func stopWatching() {
        watching?.cancel()
        watching = nil
        pruning?.invalidate()
        pruning = nil
    }

    /// The pasteboard's change count, read off the main thread.
    nonisolated private static func changeCount() async -> Int {
        await Task.detached(priority: .utility) { NSPasteboard.general.changeCount }.value
    }

    /// Reads the history if it hasn't been read. False while the Keychain doesn't answer: then nothing is recorded,
    /// changed or saved, and the read is tried again next time.
    @discardableResult
    private func loadIfNeeded() -> Bool { keeper.ensureLoaded(from: store) }

    private static let unreadable = ClipboardHistoryError(
        "The clipboard history can't be read until the Keychain answers. Try again in a moment.")

    // MARK: - Recording

    private func changed(to count: Int) {
        // A paste or the ⌘C fallback is mid-way, or a paste's restore is still to come: look again next time.
        guard !turns.isBusy else { return }
        lastChange = count
        let pasteboard = NSPasteboard.general
        let types = Set((pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        let frontmost = NSWorkspace.shared.frontmostApplication
        let skip = ClipboardSkip.reason(
            types: types, changeCount: count, isOwn: turns.isOwn, frontmost: frontmost?.bundleIdentifier,
            ignored: Set(settings.clipboardHistoryIgnoredApps))
        guard skip == nil, let copy = Self.copy(from: pasteboard) else { return }
        // Changed again while it was read: the next poll records the newer copy instead.
        guard pasteboard.changeCount == count else { return }
        let source = frontmost.flatMap { app in
            app.bundleIdentifier.map { ClipboardSource(bundleId: $0, name: app.localizedName) }
        }
        record(copy, source: source)
    }

    private func record(_ copy: ClipboardCopy, source: ClipboardSource?) {
        guard let change = keeper.change(from: store, { $0.record(copy, source: source, now: Date()) }) else { return }
        if case .image(let png, _, _) = copy, let entry = change.recorded, let file = entry.imageFile {
            let store = store
            saving.async {
                guard !FileManager.default.fileExists(atPath: store.folder.appendingPathComponent(file + ".enc").path)
                else { return }
                try? store.writeImage(png, file: file)
            }
        }
        settle(change)
    }

    /// Deletes what a change dropped and saves the history.
    private func settle(_ change: ClipboardHistory.Change) {
        guard !fixed else { return }
        let (store, history, removed) = (store, keeper.history, change.removedImages)
        saving.async {
            store.deleteImages(removed)
            do {
                try store.save(history)
            } catch {
                FileHandle.standardError.write(Data("fudge: clipboard history: \(error)\n".utf8))
            }
        }
    }

    /// Decrypted image copies a run that ended without cleaning up left in the temporary folder.
    private func sweepStalePreviews() {
        guard !swept else { return }
        swept = true
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix(Self.previewPrefix) && temporary.appendingPathComponent(name) != previews
        {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }

    private static let previewPrefix = "fudge-clipboard-"

    private func prune() {
        guard keeper.loaded else { return }
        let before = keeper.history.entries.count
        let days = settings.clipboardHistoryKeepDays
        guard let change = keeper.change(from: store, { $0.prune(now: Date(), keepForDays: days) }) else { return }
        if keeper.history.entries.count != before { settle(change) }
    }

    /// Reads a copy: files first (Finder's copies also carry their names and icons), then text (an app's copy of
    /// text may carry a picture of it too), then an image. Nil for anything else.
    static func copy(from pasteboard: NSPasteboard) -> ClipboardCopy? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty
        {
            return .files(urls.map(\.path))
        }
        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if pasteboard.types?.contains(.URL) == true || Self.isLink(trimmed) { return .link(trimmed) }
            return .text(text)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), data.count <= ClipboardHistory.imageLimit * 4,
                let image = NSBitmapImageRep(data: data),
                let png = type == .png ? data : image.representation(using: .png, properties: [:])
            else { continue }
            return .image(png: png, width: image.pixelsWide, height: image.pixelsHigh)
        }
        return nil
    }

    /// A single web or mail link, with nothing around it.
    private static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https", "mailto"].contains(scheme) && (scheme == "mailto" || url.host != nil)
    }

    // MARK: - Calls

    /// Answers `clipboardHistory.*`, only for Clipboard History's own sessions.
    func handle(
        _ method: String, _ params: JSONValue, caller: String?, origin: CallOrigin, hideWindow: () async -> Void
    ) async throws -> JSONValue {
        guard ClipboardHistory.mayCall(caller) else {
            throw ClipboardHistoryError(ClipboardHistory.notClipboardHistory)
        }
        if method == "clipboardHistory.list" {
            if isOn, !loadIfNeeded() { throw Self.unreadable }
            return keeper.history.listJSON(on: isOn)
        }
        guard isOn else { throw ClipboardHistoryError("Clipboard history is off.") }
        guard loadIfNeeded() else { throw Self.unreadable }
        let values: [String: JSONValue] = if case .object(let object) = params { object } else { [:] }
        if method == "clipboardHistory.clear" {
            if let change = keeper.change(from: store, { $0.clear() }) { settle(change) }
            return .null
        }
        guard case .string(let id) = values["id"], let entry = keeper.history.entry(id: id) else {
            throw ClipboardHistoryError("That copy isn't in the history any more.")
        }
        switch method {
        case "clipboardHistory.image":
            return .object(["path": .string(try preview(of: entry).path)])
        case "clipboardHistory.paste":
            try await SystemCalls.paste(try contents(of: entry, forPaste: true), origin: origin, hideWindow: hideWindow)
        case "clipboardHistory.copy":
            SystemCalls.write(try contents(of: entry, forPaste: false))
        case "clipboardHistory.pin":
            let pinned = values["pinned"] != .bool(false)
            if let change = keeper.change(
                from: store,
                { history in
                    _ = history.setPinned(pinned, id: id)
                    return ClipboardHistory.Change()
                })
            {
                settle(change)
            }
        case "clipboardHistory.delete":
            if let change = keeper.change(from: store, { $0.delete(id: id) }) { settle(change) }
        default:
            throw ClipboardHistoryError("Unknown call \(method)")
        }
        return .null
    }

    /// `Clipboard.read({ offset })` and `readText` for an offset above 0: the nth previous copy, as `clipboard.read`
    /// answers the current one, or null while history is off or there's no such copy.
    func read(offset: Int) -> JSONValue {
        guard isOn, loadIfNeeded(), let entry = keeper.history.entry(offset: offset) else { return .null }
        switch entry.kind {
        case .text, .link: return .object(["text": .string(entry.text ?? "")])
        case .files:
            guard let file = entry.files?.first else { return .null }
            return .object(["text": .string(file), "file": .string(file)])
        case .image: return .null
        }
    }

    private func contents(of entry: ClipboardEntry, forPaste: Bool) throws -> PasteboardContents {
        let image = try entry.imageFile.map { try store.readImage(file: $0) }
        guard let contents = entry.contents(image: image, forPaste: forPaste) else {
            throw ClipboardHistoryError("That copy can't be put back.")
        }
        return contents
    }

    /// A decrypted copy of an image entry, 0600 in a 0700 folder of its own.
    private func preview(of entry: ClipboardEntry) throws -> URL {
        guard entry.kind == .image, let file = entry.imageFile else {
            throw ClipboardHistoryError("That copy isn't an image.")
        }
        let folder =
            previews
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "\(Self.previewPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        previews = folder
        let url = folder.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard
                FileManager.default.createFile(
                    atPath: url.path, contents: try store.readImage(file: file), attributes: [.posixPermissions: 0o600])
            else { throw ClipboardHistoryError("Couldn't show the image.") }
        }
        return url
    }

    /// Deletes the decrypted image copies: when Clipboard History's session ends, and when Fudge quits.
    func clearPreviews() {
        guard let previews else { return }
        try? FileManager.default.removeItem(at: previews)
        self.previews = nil
    }

    // MARK: - Settings

    /// **Clear History…** and **Delete History**: every entry, pinned ones too, and the key.
    func deleteAll() {
        keeper.reset()
        clearPreviews()
        let store = store
        // After any save still waiting, so nothing writes the folder again.
        saving.async {
            do {
                try store.deleteAll()
            } catch {
                FileHandle.standardError.write(Data("fudge: clipboard history: \(error)\n".utf8))
            }
        }
    }
}

struct ClipboardHistoryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
