import Foundation

/// What one copy holds, as clipboard history keeps it (SPEC-077 §2): text, a link (kept as text), an image (as PNG),
/// or files (their paths). The app reads it from the pasteboard.
public enum ClipboardCopy: Sendable, Equatable {
    case text(String)
    case link(String)
    case image(png: Data, width: Int, height: Int)
    case files([String])
}

/// The app a copy came from: the frontmost one when it was made.
public struct ClipboardSource: Sendable, Equatable, Codable {
    public var bundleId: String
    public var name: String?

    public init(bundleId: String, name: String? = nil) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// One entry of the history. An image's PNG is a file of its own (`imageFile`), kept by `ClipboardHistoryStore`.
public struct ClipboardEntry: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case text, link, image, files }

    public var id: String
    public var kind: Kind
    public var text: String?
    /// The text was over `ClipboardHistory.textLimit` and is kept cut to it.
    public var truncated: Bool
    public var files: [String]?
    /// The image's file name in the store.
    public var imageFile: String?
    /// The image's PNG digest, so the same image is found again. It's only in the sealed history, never a file name.
    public var imageDigest: String?
    public var width: Int?
    public var height: Int?
    public var source: ClipboardSource?
    public var copiedAt: Date
    /// Bytes: the text's UTF-8, or the image's PNG. For files, how many.
    public var size: Int
    public var pinned: Bool

    /// What the command lists, by name: an image's dimensions, or the first file's name.
    public var name: String? {
        switch kind {
        case .image: width.flatMap { w in height.map { h in "Image (\(w)×\(h))" } } ?? "Image"
        case .files: files?.first.map { ($0 as NSString).lastPathComponent }
        case .text, .link: nil
        }
    }

    /// The `clipboardHistory.list` entry (SPEC-077's contract): dates as `{ "$date": iso }`.
    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "kind": .string(kind.rawValue), "copiedAt": FormDates.json(copiedAt),
            "size": .number(Double(size)), "pinned": .bool(pinned),
        ]
        if let text { object["text"] = .string(text) }
        if truncated { object["truncated"] = .bool(true) }
        if let files { object["files"] = .array(files.map(JSONValue.string)) }
        if let name { object["name"] = .string(name) }
        if let width, let height {
            object["width"] = .number(Double(width))
            object["height"] = .number(Double(height))
        }
        if let source {
            var app: [String: JSONValue] = ["bundleId": .string(source.bundleId)]
            if let name = source.name { app["name"] = .string(name) }
            object["app"] = .object(app)
        }
        return .object(object)
    }

    /// Whether `copy` holds the same thing, so recording it again moves this entry to the top.
    func holds(_ copy: ClipboardCopy, imageDigest: String?) -> Bool {
        switch copy {
        case .text(let value): kind == .text && text == ClipboardHistory.capped(value).text
        case .link(let value): kind == .link && text == value
        case .files(let paths): kind == .files && files == paths
        case .image: kind == .image && imageDigest != nil && self.imageDigest == imageDigest
        }
    }
}

/// The clipboard history (SPEC-077): entries newest first, with its limits. The app records copies into it, and
/// `ClipboardHistoryStore` keeps it encrypted on disk. Pinned entries are kept whatever **Keep For** says.
public struct ClipboardHistory: Sendable, Equatable, Codable {
    /// What turning it on means, said the same way on the consent sheet and in onboarding.
    public static let consentMessage =
        "Fudge will keep what you copy, encrypted on this Mac. Copies password managers mark as private are skipped. "
        + "Extensions can read it, as in Raycast."

    /// The bundled extension whose sessions may call `clipboardHistory.*`.
    public static let extensionName = "fudge-clipboard-history"
    /// Its id, the key its settings and data are kept under.
    public static let id = ExtensionID.bundled(extensionName)
    /// What any other caller gets.
    public static let notClipboardHistory = "clipboardHistory calls are only for Fudge's Clipboard History."
    /// At most this many entries; the oldest unpinned go first.
    public static let entryLimit = 1000
    /// A text copy over this many UTF-8 bytes is kept cut to it, and marked truncated.
    public static let textLimit = 1024 * 1024
    /// An image over this many bytes of PNG isn't kept.
    public static let imageLimit = 10 * 1024 * 1024
    /// All images together are kept under this; the oldest unpinned images go first.
    public static let imagesLimit = 500 * 1024 * 1024
    /// **Keep For**'s choices, in days.
    public static let keepForChoices = [1, 7, 30, 90]
    public static let defaultKeepFor = 7

    public private(set) var entries: [ClipboardEntry]

    public init(entries: [ClipboardEntry] = []) {
        self.entries = entries
    }

    /// What a change did, for the store: image files no entry uses any more.
    public struct Change: Equatable, Sendable {
        public var recorded: ClipboardEntry?
        public var removedImages: [String] = []

        public init(recorded: ClipboardEntry? = nil, removedImages: [String] = []) {
            self.recorded = recorded
            self.removedImages = removedImages
        }
    }

    /// Records a copy made at `now` in `source`. An empty text and an image over `imageLimit` aren't kept. A copy the
    /// history already holds moves that entry to the top, as the newest; an image is found by its PNG's digest.
    /// `imageFile` names a new image's file, which the store writes: random, so a name says nothing about the image.
    public mutating func record(
        _ copy: ClipboardCopy, source: ClipboardSource?, now: Date, id: String = UUID().uuidString,
        imageFile: () -> String = { "\(UUID().uuidString).png" }
    ) -> Change {
        var digest: String?
        if case .image(let png, _, _) = copy { digest = ClipboardHistoryStore.digest(png) }
        if let index = entries.firstIndex(where: { $0.holds(copy, imageDigest: digest) }) {
            var entry = entries.remove(at: index)
            entry.copiedAt = now
            entry.source = source ?? entry.source
            entries.insert(entry, at: 0)
            return Change(recorded: entry)
        }
        var entry = ClipboardEntry(
            id: id, kind: .text, text: nil, truncated: false, files: nil, imageFile: nil, width: nil, height: nil,
            source: source, copiedAt: now, size: 0, pinned: false)
        switch copy {
        case .text(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Change() }
            let capped = Self.capped(value)
            entry.text = capped.text
            entry.truncated = capped.truncated
            entry.size = capped.text.utf8.count
        case .link(let value):
            entry.kind = .link
            entry.text = value
            entry.size = value.utf8.count
        case .image(let png, let width, let height):
            guard png.count <= Self.imageLimit, let digest else { return Change() }
            entry.kind = .image
            entry.imageFile = imageFile()
            entry.imageDigest = digest
            entry.width = width
            entry.height = height
            entry.size = png.count
        case .files(let paths):
            guard !paths.isEmpty else { return Change() }
            entry.kind = .files
            entry.files = paths
            entry.size = paths.count
        }
        entries.insert(entry, at: 0)
        var change = Change(recorded: entry)
        change.removedImages = enforceLimits()
        return change
    }

    /// `text`, cut to `textLimit` UTF-8 bytes at a character boundary.
    static func capped(_ text: String) -> (text: String, truncated: Bool) {
        guard text.utf8.count > textLimit else { return (text, false) }
        var cut = ""
        var bytes = 0
        for character in text {
            let length = String(character).utf8.count
            if bytes + length > textLimit { break }
            cut.append(character)
            bytes += length
        }
        return (cut, true)
    }

    /// Drops the oldest unpinned entries past `entryLimit`, and the oldest unpinned images while all images are over
    /// `imagesLimit`. Returns the image files dropped.
    private mutating func enforceLimits() -> [String] {
        var removed: [String] = []
        while entries.count > Self.entryLimit, let index = entries.lastIndex(where: { !$0.pinned }) {
            if let file = entries.remove(at: index).imageFile { removed.append(file) }
        }
        var imageBytes = entries.filter { $0.kind == .image }.reduce(0) { $0 + $1.size }
        while imageBytes > Self.imagesLimit,
            let index = entries.lastIndex(where: { $0.kind == .image && !$0.pinned })
        {
            let entry = entries.remove(at: index)
            imageBytes -= entry.size
            if let file = entry.imageFile { removed.append(file) }
        }
        return removed
    }

    /// Drops unpinned entries copied more than `days` days before `now`.
    public mutating func prune(now: Date, keepForDays days: Int) -> Change {
        let oldest = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        return remove { !$0.pinned && $0.copiedAt < oldest }
    }

    public mutating func setPinned(_ pinned: Bool, id: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[index].pinned = pinned
        return true
    }

    public mutating func delete(id: String) -> Change { remove { $0.id == id } }

    /// Deletes every entry, pinned ones too.
    public mutating func clear() -> Change { remove { _ in true } }

    private mutating func remove(where shouldRemove: (ClipboardEntry) -> Bool) -> Change {
        var change = Change()
        change.removedImages = entries.filter(shouldRemove).compactMap(\.imageFile)
        entries.removeAll(where: shouldRemove)
        return change
    }

    public func entry(id: String) -> ClipboardEntry? { entries.first { $0.id == id } }

    /// Raycast's `offset`: 0 is the newest entry, `n` the nth before it. Pins don't change the order.
    public func entry(offset: Int) -> ClipboardEntry? {
        guard offset >= 0 else { return nil }
        let byTime = entries.enumerated().sorted { first, second in
            first.element.copiedAt != second.element.copiedAt
                ? first.element.copiedAt > second.element.copiedAt : first.offset < second.offset
        }
        return offset < byTime.count ? byTime[offset].element : nil
    }

    /// The most of an entry's text `clipboardHistory.list` sends, so a long history stays quick to load; Paste and
    /// Copy use the whole text.
    public static let listTextLimit = 20_000

    /// The `clipboardHistory.list` answer. A text longer than `listTextLimit` characters is sent cut, marked
    /// `truncated`.
    public func listJSON(on: Bool) -> JSONValue {
        let listed = entries.map { entry in
            guard let text = entry.text, text.count > Self.listTextLimit else { return entry.json }
            var cut = entry
            cut.text = String(text.prefix(Self.listTextLimit))
            cut.truncated = true
            return cut.json
        }
        return .object(["on": .bool(on), "entries": .array(on ? listed : [])])
    }
}

/// Which copies clipboard history leaves out (SPEC-077 §2).
public enum ClipboardSkip: Equatable, Sendable {
    /// Marked private by a password manager or a Fudge extension (`org.nspasteboard.ConcealedType`), or as transient
    /// or generated (`TransientType`, `AutoGeneratedType`).
    case marked
    /// Written by Fudge itself: a paste, its restore, or the ⌘C fallback (`PasteboardTurns.isOwn`).
    case fudge
    /// Copied while an app in **Ignore Apps** was frontmost.
    case ignoredApp

    public static let markerTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
    ]

    /// Why the change to `changeCount`, whose items carry `types`, isn't recorded, or nil when it is.
    public static func reason(
        types: Set<String>, changeCount: Int, isOwn: (Int) -> Bool, frontmost: String?, ignored: Set<String>
    ) -> ClipboardSkip? {
        if isOwn(changeCount) { return .fudge }
        if !types.isDisjoint(with: markerTypes) { return .marked }
        if let frontmost, ignored.contains(frontmost) { return .ignoredApp }
        return nil
    }
}

extension ClipboardEntry {
    /// What Paste and Copy put back on the pasteboard: the entry as it was recorded (text; a link as a URL and text;
    /// the image as PNG, which `image` holds; each file as a file URL). For a paste, the first item is also marked
    /// transient and auto-generated, as `Clipboard.paste`'s content is.
    public func contents(image: Data? = nil, forPaste: Bool) -> PasteboardContents? {
        typealias Representation = PasteboardContents.Representation
        func string(_ type: String, _ value: String) -> Representation {
            Representation(type: type, data: Data(value.utf8))
        }
        var items: [[Representation]]
        switch kind {
        case .text:
            guard let text else { return nil }
            items = [[string("public.utf8-plain-text", text)]]
        case .link:
            guard let text else { return nil }
            items = [[string("public.url", text), string("public.utf8-plain-text", text)]]
        case .image:
            guard let image else { return nil }
            items = [[Representation(type: "public.png", data: image)]]
        case .files:
            guard let files, !files.isEmpty else { return nil }
            items = files.map { [string("public.file-url", URL(fileURLWithPath: $0).absoluteString)] }
        }
        if forPaste {
            items[0] += [
                string(PasteboardContents.transientType, ""), string(PasteboardContents.autoGeneratedType, ""),
            ]
        }
        return PasteboardContents(items: items)
    }
}

extension ClipboardEntry {
    /// Reads an entry written as `json` writes it: snapshot runs' made-up entries (`--clipboard-entries`).
    public init?(json: JSONValue) {
        guard case .object(let object) = json, case .string(let id) = object["id"],
            case .string(let kindName) = object["kind"], let kind = Kind(rawValue: kindName),
            let copiedAt = FormDates.date(object["copiedAt"])
        else { return nil }
        func string(_ key: String) -> String? { if case .string(let value) = object[key] { value } else { nil } }
        func int(_ key: String) -> Int? {
            if case .number(let value) = object[key], value.isFinite { Int(value) } else { nil }
        }
        var source: ClipboardSource?
        if case .object(let app) = object["app"], case .string(let bundleId) = app["bundleId"] {
            let name: String? = if case .string(let name) = app["name"] { name } else { nil }
            source = ClipboardSource(bundleId: bundleId, name: name)
        }
        var files: [String]?
        if case .array(let list) = object["files"] {
            files = list.compactMap { if case .string(let path) = $0 { path } else { nil } }
        }
        let text = string("text")
        self.init(
            id: id, kind: kind, text: text, truncated: object["truncated"] == .bool(true), files: files,
            imageFile: nil, width: int("width"), height: int("height"), source: source, copiedAt: copiedAt,
            size: int("size") ?? text?.utf8.count ?? files?.count ?? 0, pinned: object["pinned"] == .bool(true))
    }
}

extension ClipboardHistory {
    /// A history of made-up entries, newest first as given: snapshot runs only.
    public init(fixed entries: [ClipboardEntry]) {
        self.entries = entries
    }
}

/// Raycast's `Clipboard.read({ offset })` and `readText({ offset })`: "Minimum value is 0, maximum value is 5." Any
/// extension can ask, so only those six are read, and an offset can never crash Fudge or page through the history.
public enum ClipboardOffset: Equatable, Sendable {
    /// Raycast's documented maximum.
    public static let maximum = 5

    /// The clipboard as it is now: no offset, 0, or a negative one (the runtime sends 0 for those).
    case current
    /// The nth copy before it, 1 to `maximum`.
    case previous(Int)
    /// Above `maximum`, or not a whole number: no such copy.
    case none

    public init(params: JSONValue) {
        guard case .object(let object) = params, case .number(let offset) = object["offset"], offset > 0 else {
            self = .current
            return
        }
        guard offset <= Double(Self.maximum), let whole = Int(exactly: offset) else {
            self = .none
            return
        }
        self = .previous(whole)
    }
}

extension ClipboardHistory {
    /// Whether a session of `caller` may make `clipboardHistory.*` calls: Clipboard History's own only.
    public static func mayCall(_ caller: String?) -> Bool { caller == extensionName }
}
