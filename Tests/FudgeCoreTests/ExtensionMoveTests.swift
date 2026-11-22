import Darwin
import Foundation
import Testing

@testable import FudgeCore

/// The names in `folder`, sorted.
private func names(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

private func inode(_ url: URL) -> UInt64? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
}

/// The move into the layout (FUD-183): every install at the top level goes into Raycast's folder by its manifest
/// name, whether the Extension Store recorded it or not.
@Test func everyInstallFromBeforeIsFiledWithRaycastsAndKeepsItsName() throws {
    let support = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let extensions = support.appendingPathComponent("extensions")
    try Layout.install("github", at: "github", in: extensions)
    try Layout.install("weather", at: "my-weather", in: extensions)
    // The store recorded github and not weather; the move reads no record.
    try Data(#"{"github":{"tree":"1","commit":"2","installedAt":"2026-01-01T00:00:00Z","dir":"github"}}"#.utf8)
        .write(to: support.appendingPathComponent("installed.json"))

    let report = try ExtensionLayout.moveIntoRepositories(extensions: extensions, waitingAtMost: .seconds(5))
    #expect(report == ExtensionLayout.MoveReport(moved: ["github", "my-weather"], left: []))
    #expect(try names(in: extensions) == [".move.lock", "raycast"])
    #expect(try names(in: extensions.appendingPathComponent("raycast/extensions")) == ["github", "weather"])
    #expect(!FileManager.default.fileExists(atPath: Development.folder(in: extensions).path), "nothing moved there")
    #expect(
        Layout.loaded(extensions) == [
            "github raycast raycast/extensions/github", "weather raycast raycast/extensions/weather",
        ])
}

@Test func aTargetThatsThereAndAnUnreadableManifestAreLeftWithALine() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    let moved = try Layout.install("github", at: "raycast/extensions/github", in: extensions, title: "Moved")
    let old = try Layout.install("github", at: "github", in: extensions, title: "Old")
    let broken = extensions.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: broken.appendingPathComponent("package.json"))
    try Layout.install("Bad Name", at: "bad", in: extensions)

    let report = ExtensionLayout.moveIntoRepositories(extensions: extensions)
    #expect(report.moved == [])
    #expect(
        report.left == [
            "left bad where it is: its extension's name isn't valid",
            "left broken where it is: its package.json can't be read",
            "left github where it is: raycast/extensions/github is there already",
        ])
    #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("package.json").path))
    #expect(try ExtensionManifest.load(from: moved.appendingPathComponent("package.json")).title == "Moved")
    #expect(Layout.loaded(extensions) == ["github raycast raycast/extensions/github"], "the moved one wins")
}

/// A legacy install named `raycast` would land inside itself, so it waits under `.move-raycast` while
/// `raycast/extensions/` is made; a `.move-raycast` a stop left is finished first.
@Test func aLegacyRaycastInstallGoesThroughItsHiddenName() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    let legacy = try Layout.install("raycast", at: "raycast", in: extensions)
    let folderInode = inode(legacy)

    var renames: [(String, String)] = []
    let report = ExtensionLayout.moveIntoRepositories(extensions: extensions) { from, to in
        renames.append(
            (String(from.dropFirst(extensions.path.count + 1)), String(to.dropFirst(extensions.path.count + 1))))
        return renamex_np(from, to, UInt32(RENAME_EXCL))
    }
    #expect(report == ExtensionLayout.MoveReport(moved: ["raycast"], left: []))
    #expect(renames.map(\.0) == ["raycast", ".move-raycast"])
    #expect(renames.map(\.1) == [".move-raycast", "raycast/extensions/raycast"])
    let moved = extensions.appendingPathComponent("raycast/extensions/raycast")
    #expect(inode(moved) == folderInode)
    #expect(Layout.loaded(extensions) == ["raycast raycast raycast/extensions/raycast"])

    // A stop between the two renames left it hidden: the next move finishes it before anything else.
    let again = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: again) }
    try Layout.install("raycast", at: ".move-raycast", in: again)
    try Layout.install("github", at: "github", in: again)
    #expect(
        ExtensionLayout.moveIntoRepositories(extensions: again)
            == ExtensionLayout.MoveReport(moved: [".move-raycast", "github"], left: []))
    #expect(try names(in: again.appendingPathComponent("raycast/extensions")) == ["github", "raycast"])
    #expect(try names(in: again) == ["raycast"])
}

@Test func legacyFudgeappAndDevelopmentInstallsMoveLikeAnyOther() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("fudgeapp", at: "fudgeapp", in: extensions)
    try Layout.install("development", at: "development", in: extensions)
    #expect(
        ExtensionLayout.moveIntoRepositories(extensions: extensions)
            == ExtensionLayout.MoveReport(moved: ["development", "fudgeapp"], left: []))
    #expect(try names(in: extensions) == ["raycast"])
    #expect(
        Layout.loaded(extensions) == [
            "development raycast raycast/extensions/development", "fudgeapp raycast raycast/extensions/fudgeapp",
        ])
}

/// One rename, never a copy: the folder and what's in it keep their inodes, so the store's adoption, which reads the
/// folder's creation time, works unchanged.
@Test func theMovedFolderAndItsFilesKeepTheirInodes() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    let folder = try Layout.install("github", at: "github", in: extensions)
    let file = folder.appendingPathComponent("package.json")
    let before = (inode(folder), inode(file))
    let created = try folder.resourceValues(forKeys: [.creationDateKey]).creationDate
    #expect(ExtensionLayout.moveIntoRepositories(extensions: extensions).moved == ["github"])
    let moved = extensions.appendingPathComponent("raycast/extensions/github")
    #expect(inode(moved) == before.0 && inode(moved.appendingPathComponent("package.json")) == before.1)
    #expect(try moved.resourceValues(forKeys: [.creationDateKey]).creationDate == created)
}

/// Stopped halfway (here the second install's rename fails on purpose), some installs have moved and some haven't:
/// both kinds load, and the next move finishes; one more finds nothing to move.
@Test func aMoveStoppedHalfwayLoadsBothKindsAndTheNextOneFinishes() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    for name in ["alpha", "beta", "gamma"] { try Layout.install(name, at: name, in: extensions) }
    let first = ExtensionLayout.moveIntoRepositories(extensions: extensions) { from, to in
        guard !from.hasSuffix("/beta") else {
            errno = EIO
            return -1
        }
        return renamex_np(from, to, UInt32(RENAME_EXCL))
    }
    #expect(first.moved == ["alpha", "gamma"])
    #expect(first.left == ["left beta where it is: moving it into raycast/extensions failed: Input/output error"])
    #expect(
        Layout.loaded(extensions) == [
            "alpha raycast raycast/extensions/alpha", "beta raycast beta", "gamma raycast raycast/extensions/gamma",
        ])
    #expect(ExtensionLayout.moveIntoRepositories(extensions: extensions).moved == ["beta"])
    #expect(ExtensionLayout.moveIntoRepositories(extensions: extensions) == ExtensionLayout.MoveReport())
    #expect(try names(in: extensions.appendingPathComponent("raycast/extensions")) == ["alpha", "beta", "gamma"])
}

/// How many moves are renaming at once, and the most there ever were.
private final class Overlap: @unchecked Sendable {
    // @unchecked: both counts are behind `lock`.
    private let lock = NSLock()
    private var now = 0
    private var most = 0
    var highest: Int { lock.withLock { most } }
    func enter() {
        lock.withLock {
            now += 1
            most = max(most, now)
        }
    }
    func leave() { lock.withLock { now -= 1 } }
}

/// The app's move and `fudge build`'s never run at once: the second waits for the lock, then finds nothing to move.
@Test func twoMovesNeverRunAtOnceAndTheSecondWaits() async throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    for name in ["alpha", "beta", "gamma"] { try Layout.install(name, at: name, in: extensions) }
    let overlap = Overlap()
    let renaming = DispatchSemaphore(value: 0)
    @Sendable func slow(_ from: String, _ to: String) -> Int32 {
        overlap.enter()
        defer { overlap.leave() }
        renaming.signal()
        usleep(150_000)
        return renamex_np(from, to, UInt32(RENAME_EXCL))
    }
    let first = Task {
        try await OffThePool.run(within: Tool.noHang) {
            try ExtensionLayout.moveLocked(extensions: extensions, waitingAtMost: .seconds(30), rename: slow)
        }
    }
    let second = try await OffThePool.run(within: Tool.noHang) { () -> (ExtensionLayout.MoveReport, Duration) in
        renaming.wait()
        let clock = ContinuousClock()
        let started = clock.now
        let report = try ExtensionLayout.moveLocked(extensions: extensions, waitingAtMost: .seconds(30), rename: slow)
        return (report, clock.now - started)
    }
    let (report, waited) = try #require(second, "the second move hung")
    #expect(try await first.value?.moved == ["alpha", "beta", "gamma"])
    #expect(report == ExtensionLayout.MoveReport(), "nothing was left to move")
    #expect(overlap.highest == 1, "one rename at a time")
    // The first had two renames of 150 ms each still to do when the second began to wait.
    #expect(waited >= .milliseconds(250), "\(waited)")
}

/// Another Fudge holding the lock past the bound: the wait gives up, and nothing moves.
@Test func aMoveGivesUpAtItsBound() async throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "github", in: extensions)
    let held = try ExtensionLayout.lockMove(in: extensions, waitingAtMost: .zero, every: .milliseconds(100))
    defer { ExtensionLayout.unlockMove(held) }
    let outcome = try await OffThePool.run(within: Tool.noHang) { () -> (String, Duration) in
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let report = try ExtensionLayout.moveIntoRepositories(
                extensions: extensions, waitingAtMost: .milliseconds(300))
            return ("moved \(report.moved)", clock.now - started)
        } catch {
            return ("\(error)", clock.now - started)
        }
    }
    let (result, waited) = try #require(outcome, "the wait didn't end at its bound")
    #expect(
        result
            == "\(ExtensionLayout.MoveLockFailure.timedOut(path: extensions.appendingPathComponent(".move.lock").path))"
    )
    #expect(waited >= .milliseconds(300), "\(waited)")
    #expect(try names(in: extensions) == [".move.lock", "github"], "nothing moved")
}

/// A lock given back within the bound is taken, and the move runs.
@Test func aMoveWaitsForALockGivenBackWithinItsBound() async throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "github", in: extensions)
    let held = try ExtensionLayout.lockMove(in: extensions, waitingAtMost: .zero, every: .milliseconds(100))
    OffThePool.after(.milliseconds(300)) { ExtensionLayout.unlockMove(held) }
    let report = try await OffThePool.run(within: Tool.noHang) {
        try ExtensionLayout.moveIntoRepositories(extensions: extensions, waitingAtMost: .seconds(20))
    }
    #expect(report?.moved == ["github"])
}

/// The app at launch: past its bound it skips the move, writes one line and loads the extensions as they are.
@Test func theAppSkipsTheMoveWithOneLineWhenTheLockIsHeld() async throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "github", in: extensions)
    let held = try ExtensionLayout.lockMove(in: extensions, waitingAtMost: .zero, every: .milliseconds(100))
    defer { ExtensionLayout.unlockMove(held) }
    let lines = LockedLines()
    let report = try await OffThePool.run(within: Tool.noHang) {
        ExtensionLayout.moveAtLaunch(extensions: extensions, waitingAtMost: .milliseconds(200)) { level, line in
            lines.append("\(level.rawValue): \(line)")
        }
    }
    #expect(report == .some(nil), "no move ran")
    #expect(
        lines.lines == [
            "warning: didn't move the installed extensions into their repositories' folders: another Fudge was still "
                + "moving them, so they load as they are"
        ])
    #expect(Layout.loaded(extensions) == ["github raycast github"], "loaded as it is")
}

@Test func theAppsMoveLogsWhatItMovedAndLeft() throws {
    let extensions = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: extensions) }
    try Layout.install("github", at: "github", in: extensions)
    try Layout.install("weather", at: "weather", in: extensions)
    try Layout.install("weather", at: "raycast/extensions/weather", in: extensions)
    let lines = LockedLines()
    let report = ExtensionLayout.moveAtLaunch(extensions: extensions) { level, line in
        lines.append("\(level.rawValue): \(line)")
    }
    #expect(report?.moved == ["github"])
    #expect(
        lines.lines == [
            "info: moved 1 installed extension into raycast/extensions",
            "warning: left weather where it is: raycast/extensions/weather is there already",
        ])
    #expect(
        ExtensionLayout.moveAtLaunch(extensions: extensions.appendingPathComponent("missing")) { _, _ in }
            == ExtensionLayout.MoveReport(), "no extensions folder, nothing to move")
}

/// `raycast` (or `raycast/extensions`) that's an install's folder or a link never takes the moved installs.
@Test func aRaycastFolderThatIsntOneTakesNothing() throws {
    let extensions = try Fixtures.temporaryDirectory()
    let elsewhere = try Fixtures.temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: extensions)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    try FileManager.default.createDirectory(
        at: extensions.appendingPathComponent("raycast"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: extensions.appendingPathComponent("raycast/extensions"), withDestinationURL: elsewhere)
    try Layout.install("github", at: "github", in: extensions)
    let report = ExtensionLayout.moveIntoRepositories(extensions: extensions)
    #expect(report.moved == [])
    #expect(report.left == ["left github where it is: raycast/extensions isn't a folder Fudge can move installs into"])
    #expect(try names(in: elsewhere) == [])
}
