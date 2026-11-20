import Foundation
import Testing

@testable import FudgeCore

// Fakes only: these tests never read the real selection, post key events, touch the pasteboard or send Apple Events.

@MainActor
private final class FakeAccessibility: AccessibilityAccess {
    var trusted = true
    var text: String?
    var prompts: [Bool] = []
    var asked: [Int32] = []

    func isTrusted(prompt: Bool) -> Bool {
        prompts.append(prompt)
        return trusted
    }

    func selectedText(pid: Int32) async -> String? {
        asked.append(pid)
        return text
    }
}

@MainActor
private final class FakePasteboard: PasteboardAccess {
    var changeCount = 7
    var current: PasteboardContents
    var replaced = 0

    init(_ contents: PasteboardContents) {
        current = contents
    }

    func contents() -> PasteboardContents { current }

    func replace(with contents: PasteboardContents) {
        current = contents
        changeCount += 1
        replaced += 1
    }

    func plainText() -> String? {
        current.items.first?.first { $0.type == "public.utf8-plain-text" }.map {
            String(decoding: $0.data, as: UTF8.self)
        }
    }

    /// What an app does on ⌘C: clear, then write.
    func appCopies(_ items: [[PasteboardContents.Representation]]) {
        changeCount += 1
        current = PasteboardContents(items: items)
    }
}

@MainActor
private final class FakeKeys: CopyKeyPoster {
    var posted: [Int32] = []
    var onCopy: () -> Void = {}

    func postCopy(to pid: Int32) {
        posted.append(pid)
        onCopy()
    }
}

private func text(_ string: String) -> PasteboardContents.Representation {
    .init(type: "public.utf8-plain-text", data: Data(string.utf8))
}

/// Two items, each with several types, as a rich copy leaves them.
private let userClipboard = PasteboardContents(items: [
    [
        text("first"), .init(type: "public.html", data: Data("<b>first</b>".utf8)),
        .init(type: "public.rtf", data: Data([0, 1])),
    ],
    [
        .init(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
        .init(type: "com.example.private", data: Data()),
    ],
])

private let app = FrontmostApplication(pid: 42, bundleIdentifier: "com.apple.TextEdit")
private let fudgePid: Int32 = 99

/// A copy that works ends the wait as soon as its text is there, so the long timeout only matters on a slow machine.
/// Tests that expect nothing to be copied pass a short one.
@MainActor
private func reader(
    _ accessibility: FakeAccessibility, _ keys: FakeKeys, _ pasteboard: FakePasteboard,
    copyTimeout: Duration = .seconds(5)
) -> SelectedText {
    SelectedText(
        accessibility: accessibility, keys: keys, pasteboard: pasteboard, ownPid: fudgePid,
        copyTimeout: copyTimeout, pollInterval: .milliseconds(1))
}

@Test @MainActor func selectedTextRejectsWhenFudgeIsFrontmost() async {
    let accessibility = FakeAccessibility()
    accessibility.text = "never read"
    let keys = FakeKeys()
    let selection = reader(accessibility, keys, FakePasteboard(userClipboard))

    for frontmost in [FrontmostApplication(pid: fudgePid, bundleIdentifier: "dev.fudge"), nil] {
        await #expect(throws: SelectionError.noSelectedText) { try await selection.read(from: frontmost) }
    }
    #expect(accessibility.asked.isEmpty)
    #expect(keys.posted.isEmpty)
}

@Test @MainActor func selectedTextComesFromAccessibilityWithoutTheFallback() async throws {
    let accessibility = FakeAccessibility()
    accessibility.text = "selected words"
    let keys = FakeKeys()
    let pasteboard = FakePasteboard(userClipboard)

    #expect(try await reader(accessibility, keys, pasteboard).read(from: app) == "selected words")
    #expect(accessibility.asked == [42])
    #expect(keys.posted.isEmpty)
    #expect(pasteboard.replaced == 0)
}

@Test @MainActor func fallbackCopiesAndRestoresThePasteboardExactly() async throws {
    for axText in [nil, ""] {
        let accessibility = FakeAccessibility()
        accessibility.text = axText
        let pasteboard = FakePasteboard(userClipboard)
        let keys = FakeKeys()
        keys.onCopy = { pasteboard.appCopies([[text("from chrome"), .init(type: "public.html", data: Data())]]) }

        #expect(try await reader(accessibility, keys, pasteboard).read(from: app) == "from chrome")
        #expect(keys.posted == [42])
        #expect(pasteboard.current == userClipboard)
        #expect(pasteboard.replaced == 1)
    }
}

@Test @MainActor func fallbackWaitsForTextAfterTheAppClearsThePasteboard() async throws {
    let pasteboard = FakePasteboard(userClipboard)
    let keys = FakeKeys()
    // The app clears now and writes its text a moment later.
    keys.onCopy = {
        pasteboard.appCopies([])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(5))
            pasteboard.current = PasteboardContents(items: [[text("late")]])
        }
    }

    #expect(try await reader(FakeAccessibility(), keys, pasteboard).read(from: app) == "late")
    #expect(pasteboard.current == userClipboard)
}

@Test @MainActor func overlappingFallbacksRunOneAtATime() async throws {
    let pasteboard = FakePasteboard(userClipboard)
    let keys = FakeKeys()
    // Each copy lands a moment after its ⌘C, with the text of the selection at that time.
    var copies = 0
    keys.onCopy = {
        copies += 1
        let copied = "copy \(copies)"
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(5))
            pasteboard.appCopies([[text(copied)]])
        }
    }
    let selection = reader(FakeAccessibility(), keys, pasteboard)

    async let first = selection.read(from: app)
    async let second = selection.read(from: app)
    #expect(try await [first, second].sorted() == ["copy 1", "copy 2"])
    #expect(pasteboard.current == userClipboard)
}

@Test @MainActor func fallbackThatCopiesNothingRestoresAndRejects() async {
    let pasteboard = FakePasteboard(userClipboard)
    let keys = FakeKeys()

    await #expect(throws: SelectionError.noSelectedText) {
        try await reader(FakeAccessibility(), keys, pasteboard, copyTimeout: .milliseconds(50)).read(from: app)
    }
    #expect(keys.posted == [42])
    #expect(pasteboard.current == userClipboard)
    #expect(pasteboard.replaced == 1)
}

@Test @MainActor func fallbackThatCopiesNoPlainTextRestoresAndRejects() async {
    let pasteboard = FakePasteboard(PasteboardContents(items: []))
    let keys = FakeKeys()
    keys.onCopy = { pasteboard.appCopies([[.init(type: "public.png", data: Data([1]))]]) }

    await #expect(throws: SelectionError.noSelectedText) {
        try await reader(FakeAccessibility(), keys, pasteboard, copyTimeout: .milliseconds(50)).read(from: app)
    }
    #expect(pasteboard.current == PasteboardContents(items: []))
}

@Test @MainActor func withoutAccessibilityRejectsAndPromptsOncePerRun() async {
    let accessibility = FakeAccessibility()
    accessibility.trusted = false
    let keys = FakeKeys()
    let pasteboard = FakePasteboard(userClipboard)
    let selection = reader(accessibility, keys, pasteboard)

    for _ in 0..<3 {
        await #expect(throws: SelectionError.accessibilityNeeded) { try await selection.read(from: app) }
    }
    #expect(accessibility.prompts == [true, false, false])
    #expect(accessibility.asked.isEmpty)
    #expect(keys.posted.isEmpty)
    #expect(pasteboard.replaced == 0)
}

@Test func selectionErrorsCarryTheMessagesExtensionsSee() {
    #expect(
        String(describing: SelectionError.noSelectedText) == "Unable to get selected text from frontmost application")
    #expect(
        String(describing: SelectionError.accessibilityNeeded)
            == "fudge needs Accessibility permission to read the selected text. Allow fudge in System Settings → "
            + "Privacy & Security → Accessibility.")
    #expect(String(describing: SelectionError.finderNotFrontmost) == "Finder isn't the frontmost application")
    #expect(
        String(describing: SelectionError.finderAutomationDenied)
            == "fudge needs permission to control Finder. Allow it in System Settings → Privacy & Security → Automation."
    )
    #expect(String(describing: SelectionError.finderTimedOut) == "Finder didn't answer in time")
}

@Test func copyKeyIsTheKeyThatTypesCInTheLayout() {
    let qwerty: [UInt16: String] = [8: "c", 34: "i"]
    let dvorak: [UInt16: String] = [8: "j", 34: "c"]
    #expect(CopyKey.keyCode { qwerty[$0] } == 8)
    #expect(CopyKey.keyCode { dvorak[$0] } == 34)
    #expect(CopyKey.keyCode { _ in nil } == CopyKey.ansiKeyCode)
}

// MARK: - Finder

@MainActor
private final class FakePermission: AutomationPermission {
    var status: Int32 = 0
    var asked: [String] = []

    func determine(bundleIdentifier: String) async -> Int32 {
        asked.append(bundleIdentifier)
        return status
    }
}

@MainActor
private final class FakeFinder: FinderSelectionSource {
    var result: Result<[URL], AppleEventError> = .success([])
    var timeouts: [Duration] = []

    func selection(timeout: Duration) async throws -> [URL] {
        timeouts.append(timeout)
        return try result.get()
    }
}

private let finder = FrontmostApplication(pid: 5, bundleIdentifier: "com.apple.finder")

@Test @MainActor func finderItemsRejectWhenFinderIsNotFrontmost() async {
    let permission = FakePermission()
    let source = FakeFinder()
    for frontmost in [app, nil] {
        await #expect(throws: SelectionError.finderNotFrontmost) {
            try await FinderSelection.read(from: frontmost, permission: permission, source: source)
        }
    }
    #expect(permission.asked.isEmpty)
    #expect(source.timeouts.isEmpty)
}

@Test @MainActor func finderItemsAskPermissionFirstAndRejectWhenDenied() async {
    let permission = FakePermission()
    permission.status = -1743
    let source = FakeFinder()

    await #expect(throws: SelectionError.finderAutomationDenied) {
        try await FinderSelection.read(from: finder, permission: permission, source: source)
    }
    #expect(permission.asked == ["com.apple.finder"])
    #expect(source.timeouts.isEmpty)

    // A denial can also come back from the event itself.
    permission.status = 0
    source.result = .failure(AppleEventError(status: -1743))
    await #expect(throws: SelectionError.finderAutomationDenied) {
        try await FinderSelection.read(from: finder, permission: permission, source: source)
    }
}

@Test @MainActor func finderItemsRejectWhenFinderTimesOut() async {
    let source = FakeFinder()
    source.result = .failure(AppleEventError(status: -1712))
    await #expect(throws: SelectionError.finderTimedOut) {
        try await FinderSelection.read(from: finder, permission: FakePermission(), source: source)
    }
    #expect(source.timeouts == [.seconds(5)])

    source.result = .failure(AppleEventError(status: -600))
    await #expect(throws: SelectionError.finderFailed(-600)) {
        try await FinderSelection.read(from: finder, permission: FakePermission(), source: source)
    }
}

@Test @MainActor func emptyFinderSelectionResolvesEmpty() async throws {
    #expect(try await FinderSelection.read(from: finder, permission: FakePermission(), source: FakeFinder()).isEmpty)
}

@Test @MainActor func finderItemsArePathsInFindersOrderWithoutTrailingSlashes() async throws {
    let source = FakeFinder()
    source.result = .success([
        URL(fileURLWithPath: "/Users/someone/Notes.txt"),
        URL(fileURLWithPath: "/Users/someone/Projects/", isDirectory: true),
        URL(string: "file:///Volumes/Backup%20Disk/")!,
        URL(fileURLWithPath: "/", isDirectory: true),
        URL(fileURLWithPath: "/Users/someone/a b/./ü.md"),
    ])
    #expect(
        try await FinderSelection.read(from: finder, permission: FakePermission(), source: source) == [
            "/Users/someone/Notes.txt",
            "/Users/someone/Projects",
            "/Volumes/Backup Disk",
            "/",
            "/Users/someone/a b/ü.md",
        ])
}
