import Foundation

// `getSelectedText()` and `getSelectedFinderItems()`. The logic lives here; the app supplies the Accessibility API,
// key events, the pasteboard and Apple Events through the protocols below, and tests supply fakes.

/// Why reading the selection failed. `description` is the message the extension's promise rejects with.
public enum SelectionError: Error, Equatable, Sendable, CustomStringConvertible {
    case noSelectedText
    case accessibilityNeeded
    case finderNotFrontmost
    case finderAutomationDenied
    case finderTimedOut
    /// An Apple Event error other than a denial or a timeout, with its OSStatus.
    case finderFailed(Int)

    public var description: String {
        switch self {
        case .noSelectedText:
            "Unable to get selected text from frontmost application"
        case .accessibilityNeeded:
            "fudge needs Accessibility permission to read the selected text. "
                + "Allow fudge in System Settings → Privacy & Security → Accessibility."
        case .finderNotFrontmost:
            "Finder isn't the frontmost application"
        case .finderAutomationDenied:
            "fudge needs permission to control Finder. Allow it in System Settings → Privacy & Security → Automation."
        case .finderTimedOut:
            "Finder didn't answer in time"
        case .finderFailed(let status):
            "Finder couldn't give its selection (error \(status))"
        }
    }
}

/// The application the user is in. The panel doesn't activate fudge, so that's the frontmost one.
public struct FrontmostApplication: Sendable, Equatable {
    public var pid: Int32
    public var bundleIdentifier: String?

    public init(pid: Int32, bundleIdentifier: String?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
    }
}

// MARK: - Selected text

/// The Accessibility API, as far as `SelectedText` needs it.
@MainActor
public protocol AccessibilityAccess: AnyObject {
    /// Whether fudge may use the Accessibility API (and post key events). With `prompt`, macOS asks the user.
    func isTrusted(prompt: Bool) -> Bool
    /// The selected text of the focused element in the application `pid`, or nil when it has none or won't say.
    func selectedText(pid: Int32) async -> String?
}

/// The Accessibility check, with macOS's prompt shown at most once per run, whichever feature asks first: reading the
/// selected text, or pasting.
@MainActor
public final class AccessibilityGate {
    private let access: any AccessibilityAccess
    private var prompted = false

    public init(access: any AccessibilityAccess) {
        self.access = access
    }

    /// Whether fudge may use the Accessibility API and post key events. The first refusal shows macOS's prompt.
    public func isTrusted() -> Bool {
        guard access.isTrusted(prompt: !prompted) else {
            prompted = true
            return false
        }
        return true
    }
}

/// Posts the copy shortcut.
@MainActor
public protocol CopyKeyPoster: AnyObject {
    /// Posts ⌘C, key down then key up, to the application `pid`.
    func postCopy(to pid: Int32)
}

/// Everything on the pasteboard: every item with every type's data, in order.
public struct PasteboardContents: Sendable, Equatable {
    public struct Representation: Sendable, Equatable {
        public var type: String
        public var data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public var items: [[Representation]]

    public init(items: [[Representation]]) {
        self.items = items
    }

    /// The type password managers mark their copies with (nspasteboard.org).
    public static let concealedType = "org.nspasteboard.ConcealedType"

    /// Whether any item is marked concealed: a password manager's copy.
    public var isConcealed: Bool {
        items.contains { $0.contains { $0.type == Self.concealedType } }
    }

    /// Without the types whose data is over `limit` bytes, and without the items that leaves empty.
    public func dropping(typesOver limit: Int) -> PasteboardContents {
        PasteboardContents(items: items.map { $0.filter { $0.data.count <= limit } }.filter { !$0.isEmpty })
    }
}

/// The general pasteboard, as far as `SelectedText` needs it.
@MainActor
public protocol PasteboardAccess: AnyObject {
    /// Goes up whenever another app (or fudge) clears the pasteboard.
    var changeCount: Int { get }
    func contents() -> PasteboardContents
    /// Clears the pasteboard and writes `contents` back, every item with all its types.
    func replace(with contents: PasteboardContents)
    /// The plain text on the pasteboard (`public.utf8-plain-text`).
    func plainText() -> String?
}

/// Reads the selected text of the frontmost application: through the Accessibility API first, and when that gives
/// nothing, by posting ⌘C and taking the text from the pasteboard, which is restored right after (D-49).
@MainActor
public final class SelectedText {
    /// Types with more data than this aren't kept for the restore. That bounds what fudge holds; the app that copied
    /// still has to produce the data when it's read.
    public static let typeSizeLimit = 50 * 1024 * 1024

    private let accessibility: any AccessibilityAccess
    private let keys: any CopyKeyPoster
    private let pasteboard: any PasteboardAccess
    private let ownPid: Int32
    private let copyTimeout: Duration
    private let pollInterval: Duration
    /// macOS's Accessibility prompt is shown at most once per run, shared with `Paste`.
    private let gate: AccessibilityGate
    /// The fallback in progress. Fallbacks run one at a time: one taking its snapshot while another's copy is on the
    /// pasteboard would restore the copied text instead of the user's clipboard.
    private var fallback: Task<Void, Never>?

    public init(
        accessibility: any AccessibilityAccess,
        keys: any CopyKeyPoster,
        pasteboard: any PasteboardAccess,
        ownPid: Int32,
        gate: AccessibilityGate? = nil,
        copyTimeout: Duration = .milliseconds(500),
        pollInterval: Duration = .milliseconds(10)
    ) {
        self.accessibility = accessibility
        self.gate = gate ?? AccessibilityGate(access: accessibility)
        self.keys = keys
        self.pasteboard = pasteboard
        self.ownPid = ownPid
        self.copyTimeout = copyTimeout
        self.pollInterval = pollInterval
    }

    public func read(from frontmost: FrontmostApplication?) async throws -> String {
        guard let frontmost, frontmost.pid != ownPid else { throw SelectionError.noSelectedText }
        guard gate.isTrusted() else { throw SelectionError.accessibilityNeeded }
        if let text = await accessibility.selectedText(pid: frontmost.pid), !text.isEmpty { return text }
        let previous = fallback
        let copying = Task {
            await previous?.value
            return try await copy(from: frontmost.pid)
        }
        fallback = Task { _ = try? await copying.value }
        return try await copying.value
    }

    /// The ⌘C fallback. Never posts ⌘V or ⌘X.
    private func copy(from pid: Int32) async throws -> String {
        let restore = Self.restoration(of: pasteboard.contents())
        let changeCount = pasteboard.changeCount
        // Written back before the promise settles, whether or not the copy worked. When nothing touched the
        // pasteboard, it's left alone: writing it back would only add a clipboard-history entry, drop types over the
        // limit, and restart a password manager's clear timer for nothing.
        defer {
            if pasteboard.changeCount != changeCount { pasteboard.replace(with: restore) }
        }

        keys.postCopy(to: pid)
        let deadline = ContinuousClock.now + copyTimeout
        while true {
            // An app clears the pasteboard before it writes, so wait for the text itself.
            if pasteboard.changeCount != changeCount, let text = pasteboard.plainText(), !text.isEmpty {
                return text
            }
            if ContinuousClock.now >= deadline || Task.isCancelled { throw SelectionError.noSelectedText }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// What the fallback writes back: the snapshot without types over `typeSizeLimit`. A password manager's copy
    /// isn't written back at all, and the pasteboard is left empty. Written back, it would get a new `changeCount`,
    /// so the password manager would take it for something the user copied and never clear it.
    static func restoration(of snapshot: PasteboardContents) -> PasteboardContents {
        snapshot.isConcealed ? PasteboardContents(items: []) : snapshot.dropping(typesOver: typeSizeLimit)
    }
}

/// The key that types "c" with ⌘ held, so ⌘C reaches apps as ⌘C on any keyboard layout (on Dvorak, the ANSI C key
/// types "j").
public enum CopyKey {
    /// `kVK_ANSI_C`.
    public static let ansiKeyCode: UInt16 = 8

    /// `translate` gives the characters a key code types with ⌘ held in the current layout.
    public static func keyCode(translate: (UInt16) -> String?) -> UInt16 {
        CommandKey.keyCode(typing: "c", ansiKeyCode: ansiKeyCode, translate: translate)
    }
}

/// The key that types "v" with ⌘ held, for ⌘V on any keyboard layout.
public enum PasteKey {
    /// `kVK_ANSI_V`.
    public static let ansiKeyCode: UInt16 = 9

    public static func keyCode(translate: (UInt16) -> String?) -> UInt16 {
        CommandKey.keyCode(typing: "v", ansiKeyCode: ansiKeyCode, translate: translate)
    }
}

enum CommandKey {
    /// The key code that types `letter` with ⌘ held: the ANSI one if it does, else the first that does.
    static func keyCode(typing letter: String, ansiKeyCode: UInt16, translate: (UInt16) -> String?) -> UInt16 {
        func types(_ code: UInt16) -> Bool { translate(code)?.lowercased() == letter }
        if types(ansiKeyCode) { return ansiKeyCode }
        return (0..<128).first(where: types) ?? ansiKeyCode
    }
}

// MARK: - Finder items

/// Permission to send Apple Events to an application (Automation in System Settings).
@MainActor
public protocol AutomationPermission: AnyObject {
    /// `AEDeterminePermissionToAutomateTarget` for `bundleIdentifier`, asking the user if needed. Returns its
    /// OSStatus. It doesn't time out: the user may be reading the consent dialog.
    func determine(bundleIdentifier: String) async -> Int32
}

/// An Apple Event that failed, with its OSStatus.
public struct AppleEventError: Error, Equatable, Sendable {
    public var status: Int

    public init(status: Int) {
        self.status = status
    }
}

/// Finder's selection over Apple Events.
@MainActor
public protocol FinderSelectionSource: AnyObject {
    /// Sends Finder `core/getd` for its `selection` as an alias list and waits at most `timeout` for the reply.
    /// Throws `AppleEventError` when the event fails.
    func selection(timeout: Duration) async throws -> [URL]
}

public enum FinderSelection {
    public static let bundleIdentifier = "com.apple.finder"
    public static let timeout: Duration = .seconds(5)
    /// `errAEEventNotPermitted`: the user denied fudge Automation of Finder.
    static let notPermitted = -1743
    /// `errAETimeout`.
    static let timedOut = -1712

    /// The POSIX paths of the items selected in Finder, in Finder's order.
    @MainActor
    public static func read(
        from frontmost: FrontmostApplication?,
        permission: any AutomationPermission,
        source: any FinderSelectionSource
    ) async throws -> [String] {
        guard frontmost?.bundleIdentifier == bundleIdentifier else { throw SelectionError.finderNotFrontmost }
        let status = Int(await permission.determine(bundleIdentifier: bundleIdentifier))
        guard status == 0 else { throw error(for: status) }
        do {
            return paths(try await source.selection(timeout: timeout))
        } catch let failure as AppleEventError {
            throw error(for: failure.status)
        }
    }

    /// POSIX paths, folders without their trailing slash.
    public static func paths(_ urls: [URL]) -> [String] {
        urls.map { url in
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }

    static func error(for status: Int) -> SelectionError {
        switch status {
        case notPermitted: .finderAutomationDenied
        case timedOut: .finderTimedOut
        default: .finderFailed(status)
        }
    }
}
