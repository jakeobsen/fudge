import Foundation
import Testing

@testable import FudgeCore

/// A recording stand-in for `SystemInstallNotifications`: a set answer, the posts and the questions, never macOS.
private final class RecordingNotifications: InstallNotifications, @unchecked Sendable {
    private let lock = NSLock()
    private var _permission: NotificationPermission
    private var _posted: [InstallNotice] = []
    private var _requests = 0
    private var _refuses = false

    init(_ permission: NotificationPermission = .allowed) { _permission = permission }

    var posted: [InstallNotice] { lock.withLock { _posted } }
    var requests: Int { lock.withLock { _requests } }
    func set(_ permission: NotificationPermission) { lock.withLock { _permission = permission } }
    func refusePosts() { lock.withLock { _refuses = true } }

    func permission() async -> NotificationPermission { lock.withLock { _permission } }
    func requestPermission() async { lock.withLock { _requests += 1 } }
    func post(_ notice: InstallNotice) async throws {
        try lock.withLock {
            if _refuses { throw CocoaError(.featureUnsupported) }
            _posted.append(notice)
        }
    }
}

private let bothOn = InstallNotificationSwitches(finished: true, failed: true)

private func end(
    pid: Int32? = 4242, startedAt: String = "2026-11-22T17:00:00.000Z", name: String = "github",
    title: String = "GitHub",
    updating: Bool = false, _ outcome: InstallEnd.Outcome = .installed
) -> InstallEnd {
    InstallEnd(
        build: pid.map { InstallBuild(pid: $0, startedAt: startedAt) }, name: name, dir: name, title: title,
        updating: updating, outcome: outcome)
}

@MainActor
private func center(
    _ notifications: RecordingNotifications, switches: InstallNotificationSwitches = bothOn
) -> InstallNoticeCenter {
    InstallNoticeCenter(notifications: notifications, switches: { switches })
}

// MARK: - InstallNotices: the decision

@Test func aStoreOnScreenGetsNoNotification() {
    var notices = InstallNotices()
    for outcome in [InstallEnd.Outcome.installed, .failed] {
        let (answer, notice) = notices.decide(
            end(pid: nil, outcome), onScreen: true, switches: bothOn, permission: .allowed)
        #expect(answer == InstallAnswer(onScreen: true, notified: false) && notice == nil)
    }
}

@Test func eachSwitchDecidesItsOwnNotification() {
    for finished in [true, false] {
        for failed in [true, false] {
            let switches = InstallNotificationSwitches(finished: finished, failed: failed)
            var notices = InstallNotices()
            let installed = notices.decide(
                end(pid: 1, .installed), onScreen: false, switches: switches, permission: .allowed)
            let broke = notices.decide(end(pid: 2, .failed), onScreen: false, switches: switches, permission: .allowed)
            #expect((installed.notice != nil) == finished && installed.answer.notified == finished)
            #expect((broke.notice != nil) == failed && broke.answer.notified == failed)
            #expect(!installed.answer.onScreen && !broke.answer.onScreen)
        }
    }
}

@Test func onlyAnAllowingAnswerFromMacOSPosts() {
    for permission in NotificationPermission.allCases {
        var notices = InstallNotices()
        let (answer, notice) = notices.decide(end(pid: 1), onScreen: false, switches: bothOn, permission: permission)
        let posts = permission == .allowed || permission == .quiet
        #expect((notice != nil) == posts && answer.notified == posts, "\(permission)")
        #expect(permission.mayPost == posts)
    }
}

@Test func anotherBuildOfItRunningSaysNothingWhateverElse() {
    for onScreen in [true, false] {
        for permission in NotificationPermission.allCases {
            var notices = InstallNotices()
            let (answer, notice) = notices.decide(
                end(pid: 1, .alreadyBuilding), onScreen: onScreen, switches: bothOn, permission: permission)
            #expect(notice == nil && !answer.notified)
        }
    }
    #expect(InstallNotice(end(.alreadyBuilding)) == nil)
}

@Test func anEndWithNoBuildIsDecidedOnItsOwnEachTime() {
    var notices = InstallNotices()
    let refusal = end(pid: nil, .failed)
    #expect(notices.decide(refusal, onScreen: false, switches: bothOn, permission: .allowed).notice != nil)
    #expect(notices.decide(refusal, onScreen: false, switches: bothOn, permission: .allowed).notice != nil)
    #expect(notices.answer(for: nil) == nil)
}

@Test func aBuildIsKnownByItsPidAndStartTime() {
    var notices = InstallNotices()
    let first = notices.decide(end(pid: 7, .installed), onScreen: false, switches: bothOn, permission: .allowed)
    #expect(first.notice != nil)
    // The same build again, now on screen: the first answer, nothing posted.
    let again = notices.decide(end(pid: 7, .installed), onScreen: true, switches: bothOn, permission: .allowed)
    #expect(again.answer == first.answer && again.notice == nil)
    // A later build under the same pid is decided afresh.
    let later = notices.decide(
        end(pid: 7, startedAt: "2026-11-22T17:05:00.000Z", .failed), onScreen: true, switches: bothOn,
        permission: .allowed)
    #expect(later.answer == InstallAnswer(onScreen: true, notified: false))
}

@Test func theLast256BuildsAreRemembered() {
    var notices = InstallNotices()
    for pid in 1...Int32(InstallNotices.memory + 1) {
        _ = notices.decide(end(pid: pid), onScreen: false, switches: bothOn, permission: .allowed)
    }
    #expect(notices.answer(for: InstallBuild(pid: 1, startedAt: "2026-11-22T17:00:00.000Z")) == nil, "the oldest went")
    #expect(notices.answer(for: InstallBuild(pid: 2, startedAt: "2026-11-22T17:00:00.000Z")) != nil)
    #expect(notices.answer(for: InstallBuild(pid: 257, startedAt: "2026-11-22T17:00:00.000Z")) != nil)
    // Decided again, the forgotten one posts again.
    #expect(notices.decide(end(pid: 1), onScreen: false, switches: bothOn, permission: .allowed).notice != nil)
}

// MARK: - The center: its inputs (R1, R3) and macOS's question

@Test @MainActor func aLoadedStoresOwnReportsDecideAndItsOutcomesDontR1() async {
    let system = RecordingNotifications()
    let center = center(system)
    // The store is loaded: an outcome decides nothing, a hidden store's build that exits 1 with the Swift-parts
    // question among them (the store asks its question and reports nothing).
    await center.outcomes([end(pid: 10, .failed), end(pid: 11, .installed)], storeLoaded: true)
    #expect(system.posted.isEmpty)
    // Its run removes the record, so the session's end finds nothing to decide.
    await center.sessionEnded([], onScreen: false)
    #expect(system.posted.isEmpty)
    // Its report of a build does decide.
    let answer = await center.report(end(pid: 12, .installed), onScreen: false)
    #expect(answer == InstallAnswer(onScreen: false, notified: true))
    #expect(system.posted.map(\.title) == ["GitHub is installed"])
}

@Test @MainActor func withNoStoreLoadedTheOutcomeDecides() async {
    let system = RecordingNotifications()
    let center = center(system)
    await center.outcomes([end(pid: 10, .failed)], storeLoaded: false)
    #expect(system.posted.map(\.title) == ["Couldn't install GitHub"])
    await center.outcomes([end(pid: 10, .failed)], storeLoaded: false)
    #expect(system.posted.count == 1, "once per build")
}

@Test @MainActor func aSessionsEndDecidesWhatItLeftOnce() async {
    let system = RecordingNotifications()
    let center = center(system)
    // The session reported pid 20, not 21, before it went.
    _ = await center.report(end(pid: 20, name: "jira", title: "Jira", .installed), onScreen: false)
    #expect(system.posted.count == 1)
    let left = [end(pid: 20, name: "jira", title: "Jira", .installed), end(pid: 21, .failed)]
    await center.sessionEnded(left, onScreen: false)
    #expect(system.posted.map(\.title) == ["Jira is installed", "Couldn't install GitHub"])
    await center.sessionEnded(left, onScreen: false)
    await center.outcomes(left, storeLoaded: false)
    #expect(system.posted.count == 2, "each decided once")
}

@Test @MainActor func aSecondReportOfOneBuildGetsTheFirstAnswerR3() async {
    let system = RecordingNotifications()
    let center = center(system)
    let first = await center.report(end(pid: 30, .installed), onScreen: false)
    let second = await center.report(end(pid: 30, .installed), onScreen: true)
    #expect(first == InstallAnswer(onScreen: false, notified: true) && second == first)
    // The same pid, another start: a new build.
    let newer = await center.report(end(pid: 30, startedAt: "2026-11-22T17:09:00.000Z", .installed), onScreen: true)
    #expect(newer == InstallAnswer(onScreen: true, notified: false))
    #expect(system.posted.count == 1)
}

@Test @MainActor func outcomesFoundAtLaunchPostNothing() async {
    let system = RecordingNotifications()
    let center = center(system)
    let found = [end(pid: 40, .installed), end(pid: 41, .failed)]
    center.foundAtLaunch(found.compactMap(\.build))
    await center.outcomes(found, storeLoaded: false)
    await center.sessionEnded(found, onScreen: false)
    #expect(system.posted.isEmpty)
    await center.outcomes([end(pid: 42, .installed)], storeLoaded: false)
    #expect(system.posted.count == 1, "a later build still posts")
}

@Test @MainActor func aPostMacOSRefusesCountsAsNotNotified() async {
    let system = RecordingNotifications()
    system.refusePosts()
    let center = center(system)
    let answer = await center.report(end(pid: 50, .failed), onScreen: false)
    #expect(answer == InstallAnswer(onScreen: false, notified: false))
    #expect(await center.report(end(pid: 50, .failed), onScreen: false) == answer)
}

@Test @MainActor func theSwitchesAreReadAtEachDecision() async {
    let system = RecordingNotifications()
    final class Box { var switches = InstallNotificationSwitches(finished: false, failed: true) }
    let box = Box()
    let center = InstallNoticeCenter(notifications: system, switches: { box.switches })
    #expect(await center.report(end(pid: 60, .installed), onScreen: false).notified == false)
    box.switches.finished = true
    #expect(await center.report(end(pid: 61, .installed), onScreen: false).notified == true)
    box.switches.failed = false
    #expect(await center.report(end(pid: 62, .failed), onScreen: false).notified == false)
}

@Test @MainActor func macOSIsAskedOncePerRunAndOnlyWhileNotAsked() async {
    let system = RecordingNotifications(.notAsked)
    let off = InstallNotificationSwitches(finished: false, failed: false)
    let quiet = InstallNoticeCenter(notifications: system, switches: { off })
    await quiet.ask(needsSwitch: true)
    #expect(system.requests == 0, "a confirmed install with both switches off asks nothing")
    await quiet.ask(needsSwitch: false)
    #expect(system.requests == 1, "Ask Now asks whatever the switches")
    await quiet.ask(needsSwitch: false)
    #expect(system.requests == 1, "once per run")

    for permission in NotificationPermission.allCases where permission != .notAsked {
        let answered = RecordingNotifications(permission)
        await center(answered).ask(needsSwitch: true)
        #expect(answered.requests == 0, "\(permission): macOS already answered")
    }
    let fresh = RecordingNotifications(.notAsked)
    await center(fresh).ask(needsSwitch: true)
    #expect(fresh.requests == 1)
}

@Test @MainActor func nothingIsAskedAtABuildsEnd() async {
    let system = RecordingNotifications(.notAsked)
    let center = center(system)
    #expect(await center.report(end(pid: 70, .installed), onScreen: false).notified == false)
    await center.outcomes([end(pid: 71, .failed)], storeLoaded: false)
    #expect(system.requests == 0 && system.posted.isEmpty)
}

// MARK: - The notification

@Test func theNotificationsWords() throws {
    let installed = try #require(InstallNotice(end(.installed)))
    #expect(installed.title == "GitHub is installed" && installed.body == nil)
    let updated = try #require(InstallNotice(end(updating: true, .installed)))
    #expect(updated.title == "GitHub is updated" && updated.body == nil)
    let failed = try #require(InstallNotice(end(.failed)))
    #expect(failed.title == "Couldn't install GitHub" && failed.body == "Click to see what went wrong.")
    let notUpdated = try #require(InstallNotice(end(updating: true, .failed)))
    #expect(notUpdated.title == "Couldn't update GitHub" && notUpdated.body == "Click to see what went wrong.")
    for notice in [installed, updated, failed, notUpdated] {
        #expect(notice.identifier == "store:github")
        #expect(!notice.title.contains("\u{2014}") && !notice.title.contains("\u{2013}"))
    }
    #expect(installed.target == NoticeTarget(name: "github", dir: "github", failed: false))
    #expect(failed.target.failed)
    let info = failed.target.userInfo
    #expect(info.count == 3 && info["name"] as? String == "github" && info["dir"] as? String == "github")
    #expect(info["failed"] as? Bool == true)
}

@Test func theTitleIsPlainTextCutTo100Characters() throws {
    let long = String(repeating: "e\u{301}", count: 150)
    let notice = try #require(InstallNotice(end(title: long, .installed)))
    #expect(
        notice.title == String(repeating: "e\u{301}", count: 100) + " is installed", "a letter and its mark are one")
    #expect(InstallNotice.plain("Git\nHub\u{2028}\t") == "Git Hub")
    #expect(InstallNotice.plain("  ") == "An extension")
}

// MARK: - The click's userInfo

@Test func aClicksUserInfoIsCheckedBeforeAnything() {
    let good: [AnyHashable: Any] = ["name": "github", "dir": "github", "failed": true]
    #expect(NoticeTarget(userInfo: good) == NoticeTarget(name: "github", dir: "github", failed: true))
    let bad: [[AnyHashable: Any]] = [
        ["name": "Git Hub", "dir": "github", "failed": true],
        ["name": "github", "dir": "../github", "failed": true],
        ["name": "github", "dir": "/Users/someone/github", "failed": true],
        ["name": "github", "dir": "a/b", "failed": false],
        ["name": "github", "dir": "github"],
        ["name": "github", "dir": "github", "failed": NSNumber(value: 1)],
        ["name": "github", "dir": "github", "failed": "true"],
        ["name": "github", "dir": "github", "failed": true, "repository": 3],
        ["dir": "github", "failed": true],
    ]
    for info in bad { #expect(NoticeTarget(userInfo: info) == nil, "\(info)") }
}

@Test func aRepositoryIsPassedOnUntouched() throws {
    let info: [AnyHashable: Any] = [
        "name": "github", "dir": "github", "failed": false, "repository": "raycast/extensions",
    ]
    let target = try #require(NoticeTarget(userInfo: info))
    #expect(target.repository == "raycast/extensions")
    #expect(target.userInfo["repository"] as? String == "raycast/extensions")
    #expect(
        target.launchContext
            == .object([
                "storeNotification": .object([
                    "name": .string("github"), "dir": .string("github"), "failed": .bool(false),
                    "repository": .string("raycast/extensions"),
                ])
            ]))
    #expect(NoticeTarget(name: "a", dir: "a", failed: true).userInfo["repository"] == nil)
}

// MARK: - The click's route

@Test func aClickGoesToTheLoadedStoreOrLaunchesIt() {
    var clicks = NotificationClicks<Int>()
    let target = NoticeTarget(name: "github", dir: "github", failed: true)
    // No store session: a launch with the target.
    guard case .launch(let launched) = clicks.click(target, loadedSession: nil) else {
        Issue.record("expected a launch")
        return
    }
    #expect(launched == target)
    // A waiting call is answered.
    #expect(clicks.wait(session: "s1", call: 1).now == nil)
    guard case .answer(let call, let answered) = clicks.click(target, loadedSession: "s1") else {
        Issue.record("expected the waiting call answered")
        return
    }
    #expect(call == 1 && answered == target)
    // No call waits: kept for the next one, which is answered at once.
    guard case .kept = clicks.click(target, loadedSession: "s1") else {
        Issue.record("expected the click kept")
        return
    }
    let next = clicks.wait(session: "s1", call: 2)
    #expect(next.now == target && next.replaced == nil)
}

@Test func onlyAStoreSessionStillRunningTakesAClick() {
    let running: (String) -> Bool = { $0 == "s1" }
    let store = ExtensionStore.id
    #expect(ExtensionStore.sessionOnScreen("s1", extension: store, isRunning: running) == "s1")
    #expect(ExtensionStore.sessionOnScreen("s2", extension: store, isRunning: running) == nil, "its host stopped")
    #expect(
        ExtensionStore.sessionOnScreen("s1", extension: ExtensionID(stored: "github")!, isRunning: running) == nil,
        "another's")
    #expect(ExtensionStore.sessionOnScreen(nil, extension: nil, isRunning: running) == nil, "no command on screen")
    // A click with a stopped store on the screen launches the store with its target.
    var clicks = NotificationClicks<Int>()
    _ = clicks.wait(session: "s2", call: 1)
    let target = NoticeTarget(name: "github", dir: "github", failed: false)
    let loaded = ExtensionStore.sessionOnScreen("s2", extension: store, isRunning: running)
    guard case .launch(let launched) = clicks.click(target, loadedSession: loaded) else {
        Issue.record("expected a launch")
        return
    }
    #expect(launched == target)
}

@Test func aSessionThatEndsDropsItsCallAndItsKeptClick() {
    var clicks = NotificationClicks<Int>()
    let target = NoticeTarget(name: "github", dir: "github", failed: false)
    _ = clicks.wait(session: "s1", call: 1)
    #expect(clicks.wait(session: "s1", call: 2).replaced == 1, "a newer call replaces the older one")
    #expect(clicks.ended(session: "s1") == 2)
    #expect(clicks.ended(session: "s1") == nil)
    // A click kept for a session that ended isn't given to the next one.
    guard case .kept = clicks.click(target, loadedSession: "s2") else {
        Issue.record("expected the click kept")
        return
    }
    _ = clicks.ended(session: "s2")
    #expect(clicks.wait(session: "s3", call: 3).now == nil)
    // Another session's call isn't answered with a click for this one.
    guard case .kept = clicks.click(target, loadedSession: "s4") else {
        Issue.record("expected the click kept for s4")
        return
    }
}

// MARK: - The page

@Test func thePagesLineForEachAnswer() {
    let lines = Dictionary(uniqueKeysWithValues: NotificationPermission.allCases.map { ($0, $0.statusLine) })
    #expect(
        lines[.notAsked]
            == "macOS asks whether Fudge may show notifications when you first install or update an extension.")
    #expect(lines[.allowed] == "macOS shows Fudge's notifications.")
    #expect(lines[.quiet] == "macOS keeps Fudge's notifications in Notification Center without showing them.")
    #expect(lines[.off] == "Notifications for Fudge are off in macOS. Turn them on in System Settings to see these.")
    #expect(lines[.unknown] == "macOS didn't say whether Fudge may show notifications.")
    for permission in NotificationPermission.allCases {
        #expect(permission.buttonTitle == (permission == .notAsked ? "Ask Now" : "Open Notification Settings"))
        #expect(!permission.statusLine.contains("\u{2014}"))
    }
    #expect(
        NotificationPermission.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.notifications")
}

@Test func snapshotRunsTakeAFixedAnswer() async {
    #expect(await FixedInstallNotifications(arguments: ["--snapshot", "x"]).permission() == .notAsked)
    for permission in NotificationPermission.allCases {
        let fixed = FixedInstallNotifications(arguments: [
            "--settings", ":notifications", "--notifications", permission.rawValue,
        ])
        #expect(await fixed.permission() == permission)
    }
    #expect(await FixedInstallNotifications(arguments: ["--notifications", "yes"]).permission() == .notAsked)
    #expect(await FixedInstallNotifications(arguments: ["--notifications"]).permission() == .notAsked)
}

@Test func aSnapshotRunNeverMakesTheSystemsNotifications() async {
    var made = 0
    let system = RecordingNotifications(.allowed)
    let snapshot = FixedInstallNotifications.pick(snapshot: true, arguments: ["--snapshot", "--notifications", "off"]) {
        made += 1
        return system
    }
    #expect(made == 0 && snapshot is FixedInstallNotifications)
    #expect(await snapshot.permission() == .off)
    let real = FixedInstallNotifications.pick(snapshot: false, arguments: []) {
        made += 1
        return system
    }
    #expect(made == 1 && real is RecordingNotifications)
}

@Test func theSwitchesAreOnUnlessFalseAndOnlyFalseIsWritten() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(#"{"someoneElses": 1}"#.utf8).write(to: file)
    var settings = FudgeSettings.load(from: file)
    #expect(settings.notifyInstallFinished && settings.notifyInstallFailed)
    #expect(InstallNotificationSwitches(settings) == bothOn)
    try settings.save(to: file)
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["notifyInstallFinished"] == nil && object["notifyInstallFailed"] == nil)
    settings.notifyInstallFinished = false
    try settings.save(to: file)
    object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["notifyInstallFinished"] as? Bool == false && object["notifyInstallFailed"] == nil)
    #expect(object["someoneElses"] as? Int == 1, "keys Fudge doesn't know are kept")
    settings = FudgeSettings.load(from: file)
    #expect(!settings.notifyInstallFinished && settings.notifyInstallFailed)
    #expect(InstallNotificationSwitches(settings) == InstallNotificationSwitches(finished: false, failed: true))
    settings.notifyInstallFinished = true
    try settings.save(to: file)
    object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["notifyInstallFinished"] == nil, "turning it back on removes the key")
    try Data(#"{"notifyInstallFinished": "no", "notifyInstallFailed": null}"#.utf8).write(to: file)
    settings = FudgeSettings.load(from: file)
    #expect(settings.notifyInstallFinished && settings.notifyInstallFailed, "only false turns one off")
    try Data(#"{"notifyInstallFinished": 0, "notifyInstallFailed": 0.0}"#.utf8).write(to: file)
    settings = FudgeSettings.load(from: file)
    #expect(settings.notifyInstallFinished && settings.notifyInstallFailed, "a number isn't false")
}

// MARK: - The folder the watcher reads

@Test func theWatcherReadsOutcomesThatHaveTheirRecords() throws {
    let folder = try Fixtures.temporaryDirectory()
    func record(_ pid: Int32, name: String, updating: Bool = false) -> String {
        """
        {"pid": \(pid), "name": "\(name)", "dir": "\(name)", "title": "Title \(name)", "commit": "abc", \
        "updating": \(updating), "startedAt": "2026-11-22T17:00:00.000Z", "deadline": "2026-11-22T17:10:00.000Z", \
        "command": ["fudge", "build"]}
        """
    }
    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }
    try write("101.json", record(101, name: "jira"))
    try write("101.ended.json", BuildOutcomeFile(pid: 101, status: 0, endedAt: Date()).text)
    try write("102.json", record(102, name: "zoom", updating: true))
    try write("102.ended.json", BuildOutcomeFile(pid: 102, status: 1, endedAt: Date()).text)
    try write("103.ended.json", BuildOutcomeFile(pid: 103, status: 0, endedAt: Date()).text)  // its record is gone
    try write("104.json", record(104, name: "linear"))
    try write("104.ended.json", #"{"pid": 104, "status": 300, "endedAt": "2026-11-22T17:00:00.000Z"}"#)
    try write("105.json", record(105, name: "slack"))
    try write("105.ended.json", BuildOutcomeFile(pid: 105, status: 75, endedAt: Date()).text)
    try write(".ab12.ended.json", "{}")
    let ends = InstallOutcomeFolder.ends(in: folder)
    #expect(ends.map(\.name) == ["jira", "zoom", "slack"])
    #expect(ends.map(\.outcome) == [.installed, .failed, .alreadyBuilding])
    #expect(ends[1].updating && ends[1].title == "Title zoom" && ends[1].dir == "zoom")
    #expect(ends[0].build == InstallBuild(pid: 101, startedAt: "2026-11-22T17:00:00.000Z"))
    #expect(InstallOutcomeFolder.ends(in: folder.appendingPathComponent("missing")).isEmpty)
    #expect(InstallOutcomeFolder.isOutcome("12.ended.json"))
    for name in ["12.json", "12.out", ".x.ended.json", "012.ended.json", "a.ended.json"] {
        #expect(!InstallOutcomeFolder.isOutcome(name), "\(name)")
    }
}

@Test func theWatcherReadsOnlyRegularFilesWithinTheirLimits() throws {
    let folder = try Fixtures.temporaryDirectory()
    let elsewhere = try Fixtures.temporaryDirectory()
    func record(_ pid: Int32, name: String) -> String {
        """
        {"pid": \(pid), "name": "\(name)", "dir": "\(name)", "title": "\(name)", "commit": "abc", "updating": false, \
        "startedAt": "2026-11-22T17:00:00.000Z", "deadline": "2026-11-22T17:10:00.000Z", "command": ["fudge", "build"]}
        """
    }
    func write(_ name: String, _ text: String, in place: URL? = nil) throws {
        try Data(text.utf8).write(to: (place ?? folder).appendingPathComponent(name))
    }
    try write("101.json", record(101, name: "jira"))
    try write("101.ended.json", BuildOutcomeFile(pid: 101, status: 0, endedAt: Date()).text)
    // A FIFO in an outcome's place: never waited on.
    try write("102.json", record(102, name: "zoom"))
    #expect(mkfifo(folder.appendingPathComponent("102.ended.json").path, 0o600) == 0)
    // An outcome through a link, and a record through a link.
    try write("103.json", record(103, name: "slack"))
    try write("103.ended.json", BuildOutcomeFile(pid: 103, status: 0, endedAt: Date()).text, in: elsewhere)
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("103.ended.json"),
        withDestinationURL: elsewhere.appendingPathComponent("103.ended.json"))
    try write("104.json", record(104, name: "linear"), in: elsewhere)
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("104.json"), withDestinationURL: elsewhere.appendingPathComponent("104.json"))
    try write("104.ended.json", BuildOutcomeFile(pid: 104, status: 0, endedAt: Date()).text)
    // An outcome over 4 KiB.
    try write("105.json", record(105, name: "notion"))
    let padded = #"{"pid": 105, "status": 0, "endedAt": "2026-11-22T17:00:00.000Z"}"#
    try write("105.ended.json", padded + String(repeating: " ", count: 4 * 1024))
    #expect(InstallOutcomeFolder.ends(in: folder).map(\.name) == ["jira"])
}

@Test func aBuildsStatusNamesItsEnd() {
    let record = StoreBuildRecord(
        pid: 9, name: "github", dir: "github", title: "GitHub", updating: true, startedAt: "2026-11-22T17:00:00.000Z")
    #expect(InstallEnd(record: record, status: 0).outcome == .installed)
    #expect(InstallEnd(record: record, status: 75).outcome == .alreadyBuilding)
    for status: Int32 in [1, 2, 143, 255] { #expect(InstallEnd(record: record, status: status).outcome == .failed) }
    let end = InstallEnd(record: record, status: 0)
    #expect(end.build == record.build && end.updating && end.title == "GitHub")
}

// MARK: - The watcher

/// A store record for the watcher's tests.
private func writeRecord(_ pid: Int32, name: String, in folder: URL) throws {
    let text = """
        {"pid": \(pid), "name": "\(name)", "dir": "\(name)", "title": "\(name)", "commit": "abc", "updating": false, \
        "startedAt": "2026-11-22T17:00:00.000Z", "deadline": "2026-11-22T17:10:00.000Z", "command": ["fudge", "build"]}
        """
    try Data(text.utf8).write(to: folder.appendingPathComponent("\(pid).json"))
}

@MainActor
private final class WatcherLog {
    var found: [[InstallBuild]] = []
    var ended: [InstallEnd] = []
    var order: [String] = []

    /// Waits for `condition`, letting the main queue deliver meanwhile; false after 30 s.
    func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

@Test @MainActor func theWatcherCountsOutcomesThereAtTheStartAsFound() async throws {
    let folder = try Fixtures.temporaryDirectory().appendingPathComponent("installing")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try writeRecord(201, name: "jira", in: folder)
    try BuildOutcomeFile(pid: 201, status: 0, endedAt: Date()).write(in: folder)
    let log = WatcherLog()
    let watcher = InstallOutcomeWatcher(
        folder: folder,
        found: {
            log.found.append($0)
            log.order.append("found")
        },
        ended: {
            log.ended += $0
            log.order.append("ended")
        })
    watcher.start()
    defer { watcher.stop() }
    #expect(await log.wait { !log.found.isEmpty })
    #expect(log.found == [[InstallBuild(pid: 201, startedAt: "2026-11-22T17:00:00.000Z")]])
    // A build that ends now is reported, once its outcome is written; a dot name isn't counted.
    try writeRecord(202, name: "zoom", in: folder)
    try Data("{}".utf8).write(to: folder.appendingPathComponent(".a1b2.ended.json"))
    try BuildOutcomeFile(pid: 202, status: 1, endedAt: Date()).write(in: folder)
    // FSEvents may still report jira's, written just before the stream: it then comes after `found`, whose "decided"
    // wins in the center (`outcomesFoundAtLaunchPostNothing`).
    #expect(await log.wait { log.ended.contains { $0.name == "zoom" } })
    #expect(log.ended.filter { $0.name != "jira" }.map(\.outcome) == [.failed])
    #expect(log.order.first == "found")
    // An outcome whose record is gone isn't reported.
    try BuildOutcomeFile(pid: 203, status: 0, endedAt: Date()).write(in: folder)
    try writeRecord(204, name: "linear", in: folder)
    try BuildOutcomeFile(pid: 204, status: 0, endedAt: Date()).write(in: folder)
    #expect(await log.wait { log.ended.contains { $0.name == "linear" } })
    #expect(log.ended.map(\.name).filter { $0 != "jira" } == ["zoom", "linear"])
    // The read when a store session ends gives every outcome that has its record.
    var all: [InstallEnd]?
    watcher.readAll { all = $0 }
    #expect(await log.wait { all != nil })
    #expect(all?.map(\.name) == ["jira", "zoom", "linear"])
}

@Test @MainActor func theWatcherMakesTheFolderWhenItsMissing() async throws {
    let folder = try Fixtures.temporaryDirectory().appendingPathComponent("extension-data/store/installing")
    let log = WatcherLog()
    let watcher = InstallOutcomeWatcher(folder: folder, found: { log.found.append($0) }, ended: { log.ended += $0 })
    watcher.start()
    defer { watcher.stop() }
    #expect(await log.wait { !log.found.isEmpty })
    #expect(log.found == [[]])
    var isFolder: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue)
}

@Test func onlyOutcomeNamesDirectlyInTheFolderCount() {
    let roots = ["/var/x/installing", "/private/var/x/installing"]
    let names = InstallOutcomeWatcher.outcomeNames(
        in: [
            "/private/var/x/installing/12.ended.json", "/var/x/installing/13.ended.json",
            "/var/x/installing/14.json", "/var/x/installing/.t.ended.json", "/var/x/installing/sub/15.ended.json",
            "/var/x/other/16.ended.json", "/var/x/installing",
        ], roots: roots)
    #expect(names == ["12.ended.json", "13.ended.json"])
}

// MARK: - The store's report

@Test func theStoresReportIsReadStrictly() throws {
    let report: JSONValue = .object([
        "build": .object(["pid": .number(4242), "startedAt": .string("2026-11-22T17:00:00.000Z")]),
        "name": .string("github"), "dir": .string("github"), "title": .string("GitHub"), "updating": .bool(true),
        "outcome": .string("failed"),
    ])
    let end = try #require(InstallEnd(report: report))
    #expect(
        end
            == InstallEnd(
                build: InstallBuild(pid: 4242, startedAt: "2026-11-22T17:00:00.000Z"), name: "github", dir: "github",
                title: "GitHub", updating: true, outcome: .failed))
    guard case .object(var values) = report else { return }
    values["build"] = nil
    #expect(InstallEnd(report: .object(values))?.build == nil, "a refusal before any build has none")
    let broken: [(String, JSONValue?)] = [
        ("name", .string("Git Hub")), ("dir", .string("../x")), ("title", .number(1)), ("updating", .string("yes")),
        ("outcome", .string("alreadyBuilding")), ("outcome", nil),
        ("build", .object(["pid": .number(1.5), "startedAt": .string("2026-11-22T17:00:00.000Z")])),
        ("build", .object(["pid": .number(0), "startedAt": .string("2026-11-22T17:00:00.000Z")])),
        ("build", .object(["pid": .number(12), "startedAt": .string("yesterday")])),
        ("build", .string("12")),
    ]
    for (key, value) in broken {
        var changed = values
        changed[key] = value
        #expect(InstallEnd(report: .object(changed)) == nil, "\(key): \(String(describing: value))")
    }
    #expect(
        InstallAnswer(onScreen: false, notified: true).json
            == .object(["onScreen": .bool(false), "notified": .bool(true)]))
}
