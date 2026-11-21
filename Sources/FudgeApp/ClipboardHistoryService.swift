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
    private var history = ClipboardHistory()
    private var loaded = false
    private var settings = FudgeSettings()
    private var watching: Task<Void, Never>?
    private var pruning: Timer?
    /// Decrypted image copies for the command's detail pane, in a private folder deleted when it's done with them.
    private var previews: URL?
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
        if let fixed {
            history = fixed
            loaded = true
        }
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

    private func loadIfNeeded() {
        guard !loaded else { return }
        history = store.load()
        loaded = true
    }

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
        let source = frontmost.flatMap { app in
            app.bundleIdentifier.map { ClipboardSource(bundleId: $0, name: app.localizedName) }
        }
        record(copy, source: source)
    }

    private func record(_ copy: ClipboardCopy, source: ClipboardSource?) {
        loadIfNeeded()
        let change = history.record(copy, source: source, now: Date())
        if case .image(let png, _, _) = copy, let entry = change.recorded, let file = entry.imageFile,
            !FileManager.default.fileExists(
                atPath: store.folder.appendingPathComponent(file + ".enc").path)
        {
            try? store.writeImage(png, file: file)
        }
        settle(change)
    }

    /// Deletes what a change dropped and saves the history.
    private func settle(_ change: ClipboardHistory.Change) {
        guard !fixed else { return }
        store.deleteImages(change.removedImages)
        do {
            try store.save(history)
        } catch {
            FileHandle.standardError.write(Data("fudge: clipboard history: \(error)\n".utf8))
        }
    }

    private func prune() {
        guard loaded else { return }
        let before = history.entries.count
        let change = history.prune(now: Date(), keepForDays: settings.clipboardHistoryKeepDays)
        if history.entries.count != before { settle(change) }
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
        guard caller == ClipboardHistory.extensionName else {
            throw ClipboardHistoryError(ClipboardHistory.notClipboardHistory)
        }
        if method == "clipboardHistory.list" {
            if isOn { loadIfNeeded() }
            return history.listJSON(on: isOn)
        }
        guard isOn else { throw ClipboardHistoryError("Clipboard history is off.") }
        loadIfNeeded()
        let values: [String: JSONValue] = if case .object(let object) = params { object } else { [:] }
        if method == "clipboardHistory.clear" {
            settle(history.clear())
            return .null
        }
        guard case .string(let id) = values["id"], let entry = history.entry(id: id) else {
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
            _ = history.setPinned(values["pinned"] != .bool(false), id: id)
            settle(ClipboardHistory.Change())
        case "clipboardHistory.delete":
            settle(history.delete(id: id))
        default:
            throw ClipboardHistoryError("Unknown call \(method)")
        }
        return .null
    }

    /// `Clipboard.read({ offset })` and `readText` for an offset above 0: the nth previous copy, as `clipboard.read`
    /// answers the current one, or null while history is off or there's no such copy.
    func read(offset: Int) -> JSONValue {
        guard isOn else { return .null }
        loadIfNeeded()
        guard let entry = history.entry(offset: offset) else { return .null }
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
                "fudge-clipboard-\(UUID().uuidString)", isDirectory: true)
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
        history = ClipboardHistory()
        clearPreviews()
        do {
            try store.deleteAll()
        } catch {
            FileHandle.standardError.write(Data("fudge: clipboard history: \(error)\n".utf8))
        }
    }
}

struct ClipboardHistoryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
