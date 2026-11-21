import Foundation
import Testing

@testable import FudgeCore

private let now = Date(timeIntervalSince1970: 1_795_000_000)
private let hour: TimeInterval = 3600
private let day: TimeInterval = 24 * hour

private func version(_ text: String) -> SemanticVersion {
    SemanticVersion(text)!
}

private func release(_ tag: String) -> Release {
    Release(tag: tag)!
}

/// `releases/latest` as GitHub answers it, trimmed; `html_url` points elsewhere, to show it isn't used.
private func releaseJSON(
    tag: String, draft: Any = false, prerelease: Any = false, body: String = "Notes", omit: Set<String> = []
) -> Data {
    var object: [String: Any] = [
        "url": "https://api.github.com/repos/jakeobsen/fudge/releases/1", "id": 1,
        "html_url": "https://example.com/not-the-release", "tag_name": tag, "name": "Fudge \(tag)",
        "draft": draft, "prerelease": prerelease, "assets": [], "body": body,
    ]
    for key in omit { object[key] = nil }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

// MARK: - Semantic versions

@Test func semanticVersionsParseExactly() {
    #expect(SemanticVersion("0.3.0") == SemanticVersion(major: 0, minor: 3, patch: 0))
    #expect(SemanticVersion("10.20.30")?.description == "10.20.30")
    #expect(SemanticVersion("1.2.0-rc.1")?.preRelease == ["rc", "1"])
    #expect(SemanticVersion("1.0.0-alpha-beta.0.x-y")?.preRelease == ["alpha-beta", "0", "x-y"])
    #expect(SemanticVersion("1.0.0+build.5") == version("1.0.0"), "build metadata is dropped")
    #expect(SemanticVersion("1.0.0-rc.1+build.01")?.description == "1.0.0-rc.1", "leading zeros are fine in a build")
    #expect(SemanticVersion("1.2.0-rc.1")?.isPreRelease == true)
    #expect(SemanticVersion("1.2.0")?.isPreRelease == false)
    for bad in [
        "", "v1.0.0", "1", "1.0", "1.0.0.0", "01.0.0", "1.02.0", "1.0.00", "1.0.0-", "1.0.0-01", "1.0.0-rc..1",
        "1.0.0-rc.", "1.0.0+", "1.0.0+a..b", "1.0.0-rc_1", " 1.0.0", "1.0.0 ", "-1.0.0", "1.-1.0", "a.b.c",
        "１.0.0", "1.0.0-ä", "99999999999999999999.0.0", "1.0.0-rc+", "1.0.0/x",
    ] {
        #expect(SemanticVersion(bad) == nil, "\(bad)")
    }
}

@Test func semanticVersionsCompareByPrecedence() {
    // semver.org's own examples, in order.
    let ordered = [
        "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
        "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "1.10.0", "2.0.0",
    ].map(version)
    for (index, lower) in ordered.enumerated() {
        for higher in ordered[(index + 1)...] {
            #expect(lower < higher, "\(lower) < \(higher)")
            #expect(!(higher < lower), "\(higher) isn't below \(lower)")
        }
        #expect(!(lower < lower))
    }
    #expect(version("0.9.0") < version("0.10.0"), "numbers, not text")
    #expect(version("1.0.0-rc.9") < version("1.0.0-rc.10"))
    #expect(version("1.0.0-1") < version("1.0.0-a"), "numbers are below words")
    #expect(version("1.0.0-B") < version("1.0.0-a"), "words in ASCII order")
    #expect(!(version("1.0.0+a") < version("1.0.0+b")) && !(version("1.0.0+b") < version("1.0.0+a")))
}

// MARK: - The running version (the Makefile's `git describe --tags --always --dirty`)

@Test func theRunningVersionIsReadInEveryFormTheMakefileWrites() {
    let cases: [(String, RunningVersion)] = [
        ("v0.3.0", .tagged(version("0.3.0"))),
        ("0.3.0", .tagged(version("0.3.0"))),
        ("v0.3.0-dirty", .tagged(version("0.3.0"))),
        ("0.3.0-dirty", .tagged(version("0.3.0"))),
        ("v0.2.0-14-g51ba5a2", .tagged(version("0.2.0"))),
        ("0.2.0-14-g51ba5a2", .tagged(version("0.2.0"))),
        ("v0.2.0-14-g51ba5a2-dirty", .tagged(version("0.2.0"))),
        ("v0.2.0-1-g51ba5a2c3d4e5f6", .tagged(version("0.2.0"))),
        ("v1.2.0-rc.1", .tagged(version("1.2.0-rc.1"))),
        ("v1.2.0-rc.1-dirty", .tagged(version("1.2.0-rc.1"))),
        ("v1.2.0-rc.1-3-gabc1234", .tagged(version("1.2.0-rc.1"))),
        ("v1.2.0-rc.1-3-gabc1234-dirty", .tagged(version("1.2.0-rc.1"))),
        ("v1.2.0+build.7-2-gabc1234", .tagged(version("1.2.0"))),
        ("v0.3.0\n", .tagged(version("0.3.0"))),
        // Info.plist's own value, and FudgeVersion.current outside a bundle.
        ("0.0.0", .tagged(version("0.0.0"))),
        ("0.0.0-dev", .tagged(version("0.0.0-dev"))),
        // The short version `make app` writes for a build after a tag (scripts/bundle-version.ts).
        ("0.2.0-dev+14.51ba5a2", .tagged(version("0.2.0"))),
        ("0.2.0-dev+14.51ba5a2.dirty", .tagged(version("0.2.0"))),
        ("0.2.0-dev+dirty", .tagged(version("0.2.0"))),
        ("1.2.0-rc.1.dev+3.abc1234", .tagged(version("1.2.0-rc.1"))),
        ("0.0.0-dev+8f8e040", .tagged(version("0.0.0"))),
        // A tag that is itself named dev is a pre-release, as any other.
        ("v1.0.0-dev", .tagged(version("1.0.0-dev"))),
        // No tag yet: a bare commit, or the Makefile's `dev` when git can't say.
        ("8f8e040", .untagged),
        ("8f8e040-dirty", .untagged),
        ("8f8e040c1d2e", .untagged),
        ("dev", .untagged),
        ("", .untagged),
        // A tag that isn't a version.
        ("nightly-3-gabc1234", .untagged),
        ("v1.2", .untagged),
        ("V1.2.0", .untagged),
    ]
    for (text, expected) in cases {
        #expect(RunningVersion(text) == expected, "\(text)")
    }
}

@Test func aReleaseIsNewerOnlyWhenItBeatsTheRunningBuildsTag() {
    func told(_ running: String, about tag: String) -> Bool {
        RunningVersion(running).isOlder(than: release(tag).version)
    }
    // A release build.
    #expect(!told("v0.3.0", about: "v0.3.0"))
    #expect(!told("0.3.0", about: "v0.2.9"))
    #expect(told("v0.3.0", about: "v0.3.1"))
    #expect(told("v0.3.0-dirty", about: "v0.4.0"))
    #expect(told("v0.9.0", about: "v0.10.0"), "by number, not text")
    // A dev build after v0.2.0 already has v0.2.0, but not v0.2.1.
    #expect(!told("v0.2.0-14-g51ba5a2", about: "v0.2.0"))
    #expect(!told("v0.2.0-14-g51ba5a2-dirty", about: "v0.2.0"))
    #expect(!told("v0.2.0-14-g51ba5a2", about: "v0.1.9"))
    #expect(told("v0.2.0-14-g51ba5a2", about: "v0.2.1"))
    #expect(told("v0.2.0-14-g51ba5a2-dirty", about: "v0.2.1"))
    // A pre-release is below its release.
    #expect(told("v1.2.0-rc.1", about: "v1.2.0"))
    #expect(told("v1.2.0-rc.1-3-gabc1234", about: "v1.2.0"))
    #expect(told("v1.2.0-rc.1-3-gabc1234-dirty", about: "v1.2.0"))
    #expect(!told("v1.2.0-rc.1-3-gabc1234", about: "v1.1.9"))
    // The short version of a build after v0.2.0 says the same as its describe.
    #expect(!told("0.2.0-dev+14.51ba5a2", about: "v0.2.0"))
    #expect(told("0.2.0-dev+14.51ba5a2", about: "v0.2.1"))
    #expect(told("1.2.0-rc.1.dev+3.abc1234", about: "v1.2.0"))
    #expect(!told("1.2.0-rc.1.dev+3.abc1234", about: "v1.2.0-rc.1"))
    // No tag: older than any release.
    for running in ["8f8e040", "8f8e040-dirty", "dev", "0.0.0-dev+8f8e040"] {
        #expect(told(running, about: "v0.0.1"), "\(running)")
        #expect(told(running, about: "v0.2.0"), "\(running)")
    }
}

// MARK: - GitHub's answer

@Test func aReleaseIsAVTagWithASemanticVersion() {
    let found = release("v0.9.0")
    #expect(found.version == version("0.9.0"))
    #expect(found.pageURL.absoluteString == "https://github.com/jakeobsen/fudge/releases/tag/v0.9.0")
    for bad in ["0.9.0", "v0.9", "vv0.9.0", "v0.9.0/../../evil", "v0.9.0?x=1", "v0.9.0#x", "v 0.9.0", "release"] {
        #expect(Release(tag: bad) == nil, "\(bad)")
    }
}

@Test func theLatestReleaseIsReadFromGitHubsAnswer() throws {
    let found = try #require(try UpdateCheck.parseLatest(releaseJSON(tag: "v0.9.0")))
    #expect(found.tag == "v0.9.0")
    #expect(found.version == version("0.9.0"))
    #expect(
        found.pageURL.absoluteString == "https://github.com/jakeobsen/fudge/releases/tag/v0.9.0",
        "made from the tag, not html_url")
    #expect(
        try UpdateCheck.parseLatest(releaseJSON(tag: "v0.9.0", omit: ["draft", "prerelease", "html_url"])) == found)

    #expect(try UpdateCheck.parseLatest(releaseJSON(tag: "v0.9.0", draft: true)) == nil, "drafts are ignored")
    #expect(try UpdateCheck.parseLatest(releaseJSON(tag: "v1.0.0-rc.1", prerelease: true)) == nil, "pre-releases too")
    #expect(try UpdateCheck.parseLatest(releaseJSON(tag: "v1.0.0-rc.1")) == nil, "a pre-release tag too")

    for broken in [
        Data("not json".utf8), Data("[]".utf8), Data(#"{"message": "Not Found"}"#.utf8),
        releaseJSON(tag: "nightly"), releaseJSON(tag: "0.9.0"), releaseJSON(tag: "v0.9.0", draft: "no"),
        releaseJSON(tag: "v0.9.0", prerelease: 0 as Int),
        Data(#"{"tag_name": 9}"#.utf8),
    ] {
        #expect(throws: UpdateCheckFailure.notARelease) { try UpdateCheck.parseLatest(broken) }
    }
}

@Test func anAnswerOverOneMegabyteIsRefused() throws {
    let base = releaseJSON(tag: "v0.9.0", body: "").count
    let atLimit = releaseJSON(tag: "v0.9.0", body: String(repeating: "x", count: UpdateCheck.byteLimit - base))
    #expect(atLimit.count == 1_000_000)
    #expect(try UpdateCheck.parseLatest(atLimit)?.tag == "v0.9.0", "1 MB exactly is read")
    let over = releaseJSON(tag: "v0.9.0", body: String(repeating: "x", count: UpdateCheck.byteLimit - base + 1))
    #expect(throws: UpdateCheckFailure.tooLarge) { try UpdateCheck.parseLatest(over) }
}

/// Bytes as a response streams them, counting how many were read.
private final class CountingBytes: AsyncSequence, @unchecked Sendable {
    typealias Element = UInt8
    let count: Int
    private(set) var read = 0

    init(count: Int) {
        self.count = count
    }

    struct Iterator: AsyncIteratorProtocol {
        let source: CountingBytes
        mutating func next() async -> UInt8? {
            guard source.read < source.count else { return nil }
            source.read += 1
            return UInt8(ascii: "x")
        }
    }

    func makeAsyncIterator() -> Iterator { Iterator(source: self) }
}

@Test func theBodyIsReadUpToOneMegabyte() async throws {
    let small = CountingBytes(count: 2000)
    #expect(try await UpdateCheck.readBody(small).count == 2000)

    let exactly = CountingBytes(count: UpdateCheck.byteLimit)
    #expect(try await UpdateCheck.readBody(exactly).count == UpdateCheck.byteLimit)

    let endless = CountingBytes(count: 50_000_000)
    await #expect(throws: UpdateCheckFailure.tooLarge) { try await UpdateCheck.readBody(endless) }
    #expect(endless.read == UpdateCheck.byteLimit + 1, "it stops as soon as it's over")

    let announced = CountingBytes(count: 10)
    await #expect(throws: UpdateCheckFailure.tooLarge) {
        try await UpdateCheck.readBody(announced, expectedLength: 2_000_000)
    }
    #expect(announced.read == 0, "an announced length over the limit is refused before reading")
}

@Test func theUserAgentNamesFudgeAndItsVersion() {
    #expect(UpdateCheck.userAgent(version: "0.3.0") == "Fudge/0.3.0")
    #expect(UpdateCheck.userAgent(version: "v0.2.0-14-g51ba5a2-dirty") == "Fudge/v0.2.0-14-g51ba5a2-dirty")
    #expect(UpdateCheck.userAgent(version: "1.0 (beta)/x\r\nX-Evil: 1") == "Fudge/1.0betaxX-Evil1")
    #expect(UpdateCheck.userAgent(version: "") == "Fudge")
    #expect(
        UpdateCheck.latestReleaseURL.absoluteString == "https://api.github.com/repos/jakeobsen/fudge/releases/latest")
}

@Test func theMenuAndTheHUDNameTheVersion() {
    #expect(UpdateCheck.menuTitle(release("v0.9.0")) == "Fudge 0.9.0 Is Available…")
    #expect(UpdateCheck.availableText(release("v0.9.0")) == "Fudge 0.9.0 is available")
}

// MARK: - The setting

@Test func theSettingIsUnsetUntilChosenAndKeepsOtherKeys() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(#"{"theme": "dark", "currencyRates": true}"#.utf8).write(to: file)
    #expect(FudgeSettings.load(from: file).updateCheck == nil, "unset until chosen")
    #expect(FudgeSettings().updateCheck == nil)

    for setting in UpdateCheckSetting.allCases {
        var settings = FudgeSettings.load(from: file)
        settings.updateCheck = setting
        try settings.save(to: file)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["updateCheck"] as? String == setting.rawValue, "off is written too: it was chosen")
        #expect(object["theme"] as? String == "dark")
        #expect(object["currencyRates"] as? Bool == true)
        #expect(FudgeSettings.load(from: file).updateCheck == setting)
    }

    for unknown in [#""hourly""#, "3", "true", "null", #"["daily"]"#] {
        try Data(#"{"theme": "dark", "updateCheck": \#(unknown)}"#.utf8).write(to: file)
        #expect(FudgeSettings.load(from: file).updateCheck == nil, "\(unknown) reads as unset")
    }
    #expect(UpdateCheckSetting.allCases.map(\.rawValue) == ["daily", "weekly", "monthly", "off"])
    #expect(UpdateCheckSetting.allCases.map(\.title) == ["Daily", "Weekly", "Monthly", "Never"])
    #expect(UpdateCheckSetting.allCases.map(\.onboardingTitle) == ["Daily", "Weekly", "Monthly", "Off"])
}

// MARK: - The schedule

@Test func aCheckIsDueOncePerIntervalAfterTheLastSuccess() {
    func due(_ setting: UpdateCheckSetting?, lastSuccess ago: TimeInterval?, failures: [TimeInterval] = []) -> Bool {
        let state = UpdateCheckState(
            lastSuccess: ago.map { now.addingTimeInterval(-$0) },
            failedChecks: failures.map { now.addingTimeInterval(-$0) })
        return UpdateCheckPolicy.isDue(setting: setting, state: state, now: now)
    }
    #expect(!due(nil, lastSuccess: nil), "unset: nothing is checked")
    #expect(!due(.off, lastSuccess: nil))
    #expect(!due(.off, lastSuccess: 400 * day))
    #expect(due(.daily, lastSuccess: nil), "never checked: now")
    #expect(!due(.daily, lastSuccess: 23 * hour))
    #expect(due(.daily, lastSuccess: day))
    #expect(!due(.weekly, lastSuccess: 6 * day))
    #expect(due(.weekly, lastSuccess: 7 * day))
    #expect(!due(.monthly, lastSuccess: 29 * day))
    #expect(due(.monthly, lastSuccess: 30 * day))
    #expect(due(.daily, lastSuccess: -2 * day), "a success in the future (the clock was changed): due")

    #expect(due(.daily, lastSuccess: 2 * day, failures: [hour, 2 * hour, 3 * hour]), "3 failures today: try again")
    #expect(!due(.daily, lastSuccess: 2 * day, failures: [hour, 2 * hour, 3 * hour, 4 * hour]), "4: wait")
    #expect(due(.daily, lastSuccess: 2 * day, failures: [hour, 2 * hour, 3 * hour, day]), "one is a day old")
    #expect(
        due(.daily, lastSuccess: nil, failures: [-hour, -2 * hour, -3 * hour, -4 * hour]), "future ones don't count")
}

// MARK: - The checker

/// Answers each check with the next result, and counts the checks.
private actor FakeReleaseFetcher: ReleaseFetcher {
    private var results: [Result<Data?, any Error>]
    private(set) var calls = 0

    init(_ results: [Result<Data?, any Error>]) {
        self.results = results
    }

    func fetchLatestRelease() async throws -> Data? {
        calls += 1
        guard !results.isEmpty else { throw Offline() }
        return try results.removeFirst().get()
    }
}

/// Holds its one check until `open()`.
private actor GatedReleaseFetcher: ReleaseFetcher {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?

    func fetchLatestRelease() async throws -> Data? {
        calls += 1
        await withCheckedContinuation { gate = $0 }
        return releaseJSON(tag: "v0.9.0")
    }

    func open() {
        gate?.resume()
        gate = nil
    }
}

private struct Offline: LocalizedError {
    var errorDescription: String? { "The Internet connection appears to be offline." }
}

private func latest(_ tag: String) -> Result<Data?, any Error> {
    .success(releaseJSON(tag: tag))
}

@MainActor @Test func nothingIsCheckedUntilASettingIsChosenThenOncePerInterval() async throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("update-check.json")
    let fetcher = FakeReleaseFetcher([latest("v0.1.0"), latest("v0.1.0")])
    let checker = UpdateChecker(fetcher: fetcher, stateFile: file, running: RunningVersion("v0.1.0"), setting: nil)
    await checker.checkIfDue(now: now)
    #expect(await fetcher.calls == 0, "unset: nothing")
    await checker.setSetting(.off, now: now)
    #expect(await fetcher.calls == 0, "off: nothing")

    await checker.setSetting(.daily, now: now)
    #expect(await fetcher.calls == 1, "choosing Daily checks")
    #expect(checker.status.headline(version: "0.3.0") == "Fudge 0.3.0 is up to date")
    #expect(checker.state.lastSuccess == now)
    for tick in 1...23 {
        await checker.checkIfDue(now: now.addingTimeInterval(Double(tick) * hour))
    }
    #expect(await fetcher.calls == 1, "never more than once a day")
    await checker.checkIfDue(now: now.addingTimeInterval(day))
    #expect(await fetcher.calls == 2)
    #expect(UpdateCheckState.load(from: file) == checker.state, "kept in update-check.json")
}

@MainActor @Test func checkNowAlwaysRuns() async throws {
    let fetcher = FakeReleaseFetcher([latest("v0.1.0"), latest("v0.1.0"), .failure(Offline())])
    let checker = UpdateChecker(fetcher: fetcher, stateFile: nil, running: RunningVersion("v0.1.0"), setting: .off)
    await checker.checkNow(now: now)
    await checker.checkNow(now: now.addingTimeInterval(60))
    #expect(await fetcher.calls == 2, "off, and a minute apart: Check Now still checks")
    await checker.setSetting(.daily, now: now.addingTimeInterval(120))
    #expect(await fetcher.calls == 2, "the last success is a minute old, so Daily isn't due")
    await checker.checkNow(now: now.addingTimeInterval(180))
    #expect(await fetcher.calls == 3)
    #expect(checker.state.failedChecks.isEmpty, "Check Now's failures don't use up the scheduled ones")
}

@MainActor @Test func aFailureIsRetriedHourlyAtMostFourTimesADay() async throws {
    let fetcher = FakeReleaseFetcher(
        Array(repeating: .failure(UpdateCheckFailure.status(503)), count: 4) + [latest("v0.2.0"), latest("v0.2.0")])
    let checker = UpdateChecker(fetcher: fetcher, stateFile: nil, running: RunningVersion("v0.1.0"), setting: .daily)
    var changes = 0
    checker.onChange = { changes += 1 }
    await checker.checkIfDue(now: now)
    #expect(checker.status.headline(version: "0.3.0") == "Fudge 0.3.0: couldn't check for updates")
    #expect(checker.status.details(locale: Locale(identifier: "en_US")).first == "GitHub answered 503")
    #expect(changes >= 2, "checking, then the result")
    for tick in 1...10 {
        await checker.checkIfDue(now: now.addingTimeInterval(Double(tick) * hour))
    }
    #expect(await fetcher.calls == 4, "at the next three hourly ticks, then no more that day")
    await checker.checkIfDue(now: now.addingTimeInterval(day - 1))
    #expect(await fetcher.calls == 4)

    await checker.checkNow(now: now.addingTimeInterval(day - 1))
    #expect(await fetcher.calls == 5, "Check Now runs whatever the limit")
    #expect(checker.state.failure == nil)
    #expect(checker.state.failedChecks.isEmpty, "a success clears the failures")
    #expect(checker.available?.tag == "v0.2.0")
    await checker.checkIfDue(now: now.addingTimeInterval(day + hour))
    #expect(await fetcher.calls == 5, "it just succeeded, so a day must pass again")
}

@MainActor @Test func theFailureLimitLiftsADayAfterTheFirstFailure() async throws {
    let fetcher = FakeReleaseFetcher(Array(repeating: .failure(Offline()), count: 4) + [latest("v0.1.0")])
    let checker = UpdateChecker(fetcher: fetcher, stateFile: nil, running: RunningVersion("v0.1.0"), setting: .weekly)
    for tick in 0...5 {
        await checker.checkIfDue(now: now.addingTimeInterval(Double(tick) * hour))
    }
    #expect(await fetcher.calls == 4)
    await checker.checkIfDue(now: now.addingTimeInterval(day))
    #expect(await fetcher.calls == 5, "the first failure is a day old")
    #expect(checker.status.headline(version: "0.3.0") == "Fudge 0.3.0 is up to date")
}

@MainActor @Test func theHUDSaysEachNewVersionOnce() async throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("update-check.json")
    let fetcher = FakeReleaseFetcher([
        latest("v0.9.0"), latest("v0.9.0"), .failure(Offline()), latest("v0.10.0"), latest("v0.10.0"),
    ])
    let checker = UpdateChecker(fetcher: fetcher, stateFile: file, running: RunningVersion("v0.8.0"), setting: .daily)
    var announced: [String] = []
    checker.onNewRelease = { announced.append(UpdateCheck.availableText($0)) }

    await checker.checkIfDue(now: now)
    #expect(announced == ["Fudge 0.9.0 is available"])
    #expect(checker.status.headline(version: "0.3.0") == "Fudge 0.9.0 is available")
    #expect(checker.available?.pageURL.absoluteString == "https://github.com/jakeobsen/fudge/releases/tag/v0.9.0")
    await checker.checkNow(now: now.addingTimeInterval(hour))
    #expect(announced.count == 1, "the same version isn't announced again")

    await checker.checkNow(now: now.addingTimeInterval(2 * hour))
    #expect(checker.available?.tag == "v0.9.0", "a failure keeps what the last answer found")
    #expect(checker.status.headline(version: "0.3.0") == "Fudge 0.9.0 is available")
    #expect(
        checker.status.details(locale: Locale(identifier: "en_US")).first
            == "Couldn't check for updates: The Internet connection appears to be offline.")

    // Fudge restarts: the announced version is in the file.
    let restarted = UpdateChecker(fetcher: fetcher, stateFile: file, running: RunningVersion("v0.8.0"), setting: .daily)
    restarted.onNewRelease = { announced.append(UpdateCheck.availableText($0)) }
    #expect(restarted.state.announced == version("0.9.0"))
    #expect(restarted.available?.tag == "v0.9.0")
    await restarted.checkNow(now: now.addingTimeInterval(3 * hour))
    #expect(announced == ["Fudge 0.9.0 is available", "Fudge 0.10.0 is available"])
    await restarted.checkNow(now: now.addingTimeInterval(4 * hour))
    #expect(announced.count == 2)
}

@MainActor @Test func aDevBuildIsToldOnlyAboutReleasesAfterItsTag() async throws {
    let fetcher = FakeReleaseFetcher([latest("v0.2.0"), latest("v0.2.1")])
    let checker = UpdateChecker(
        fetcher: fetcher, stateFile: nil, running: RunningVersion("v0.2.0-14-g51ba5a2-dirty"), setting: .daily)
    var announced = 0
    checker.onNewRelease = { _ in announced += 1 }
    await checker.checkNow(now: now)
    #expect(checker.available == nil)
    #expect(checker.status.headline(version: "0.3.0") == "Fudge 0.3.0 is up to date")
    #expect(announced == 0)
    await checker.checkNow(now: now.addingTimeInterval(hour))
    #expect(checker.available?.tag == "v0.2.1")
    #expect(announced == 1)

    let untagged = UpdateChecker(
        fetcher: FakeReleaseFetcher([latest("v0.0.1")]), stateFile: nil, running: RunningVersion("8f8e040-dirty"),
        setting: .daily)
    await untagged.checkNow(now: now)
    #expect(untagged.available?.tag == "v0.0.1", "a build with no tag is older than any release")
}

@MainActor @Test func noReleaseYetIsUpToDate() async throws {
    let fetcher = FakeReleaseFetcher([.success(nil), .success(releaseJSON(tag: "v1.0.0-rc.1", prerelease: true))])
    let checker = UpdateChecker(fetcher: fetcher, stateFile: nil, running: .untagged, setting: .daily)
    await checker.checkNow(now: now)
    #expect(checker.state.failure == nil)
    #expect(checker.state.lastSuccess == now)
    #expect(
        checker.status.headline(version: "0.3.0") == "Fudge 0.3.0 is up to date", "GitHub's 404 when there's no release"
    )
    await checker.checkNow(now: now.addingTimeInterval(hour))
    #expect(checker.available == nil, "a pre-release is never offered")
}

@MainActor @Test func oneCheckAtATime() async throws {
    let fetcher = GatedReleaseFetcher()
    let checker = UpdateChecker(fetcher: fetcher, stateFile: nil, running: .untagged, setting: .daily)
    let first = Task { await checker.checkNow(now: now) }
    while await fetcher.calls == 0 { await Task.yield() }
    #expect(checker.checking)
    #expect(checker.status.headline(version: "0.3.0") == "Checking for updates…")
    await checker.checkNow(now: now)
    await checker.checkIfDue(now: now)
    #expect(await fetcher.calls == 1, "a second check while one runs does nothing")
    await fetcher.open()
    await first.value
    #expect(!checker.checking)
    #expect(checker.available?.tag == "v0.9.0")
}

@MainActor @Test func snapshotsShowAReleaseWithoutChecking() async throws {
    let fetcher = FakeReleaseFetcher([])
    let checker = UpdateChecker(fetcher: fetcher, stateFile: nil, running: .untagged, setting: .daily)
    var announced = 0
    checker.onNewRelease = { _ in announced += 1 }
    checker.show(release("v0.9.0"), checkedAt: now)
    #expect(checker.status.headline(version: "0.3.0") == "Fudge 0.9.0 is available")
    #expect(await fetcher.calls == 0)
    #expect(announced == 0, "no HUD")
}

// MARK: - The state file and the General page's lines

@Test func theStateFileIsReadTolerantly() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("nested/update-check.json")
    #expect(UpdateCheckState.load(from: file) == UpdateCheckState(), "missing: nothing checked yet")
    let state = UpdateCheckState(
        lastCheck: now, lastSuccess: now.addingTimeInterval(-hour), latest: release("v0.9.0"), failure: "Offline",
        failedChecks: [now], announced: version("0.9.0"))
    try state.save(to: file)
    #expect(UpdateCheckState.load(from: file) == state)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["latest"] as? String == "v0.9.0")
    #expect(object["announced"] as? String == "0.9.0")

    let wrongTypes = #"""
        {"lastCheck": 3, "lastSuccess": "yesterday", "latest": "nightly", "failure": ["x"], "failedChecks": "no",
         "announced": "0.9", "extra": true}
        """#
    try Data(wrongTypes.utf8).write(to: file)
    #expect(UpdateCheckState.load(from: file) == UpdateCheckState(), "wrong types read as unset")
    for broken in ["not json", "[]", ""] {
        try Data(broken.utf8).write(to: file)
        #expect(UpdateCheckState.load(from: file) == UpdateCheckState(), "\(broken)")
    }
    try state.save(to: file)
    #expect(UpdateCheckState.load(from: file) == state, "a broken file is replaced")
}

@Test func theGeneralPageSaysWhatTheLastCheckFound() {
    let enUS = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!
    #expect(UpdateStatus().headline(version: "0.3.0") == "Fudge 0.3.0: not checked for updates yet")
    #expect(UpdateStatus().details(locale: enUS, timeZone: utc).isEmpty)
    let upToDate = UpdateStatus(lastCheck: now)
    #expect(upToDate.headline(version: "0.3.0") == "Fudge 0.3.0 is up to date")
    #expect(upToDate.details(locale: enUS, timeZone: utc).count == 1)
    #expect(upToDate.details(locale: enUS, timeZone: utc)[0].hasPrefix("Last checked: "))
    let failed = UpdateStatus(lastCheck: now, failure: "GitHub answered 503")
    #expect(failed.headline(version: "0.3.0") == "Fudge 0.3.0: couldn't check for updates")
    #expect(failed.details(locale: enUS, timeZone: utc).first == "GitHub answered 503")
    let checking = UpdateStatus(checking: true, lastCheck: now, failure: "GitHub answered 503")
    #expect(checking.headline(version: "0.3.0") == "Checking for updates…")
    #expect(checking.details(locale: enUS, timeZone: utc).count == 1, "the old failure isn't shown while checking")
    #expect(
        UpdateStatus(lastCheck: now, available: release("v0.9.0")).headline(version: "0.3.0")
            == "Fudge 0.9.0 is available")
}

// MARK: - "Not Chosen" while unset (FUD-135 §3)

@Test func thePopupSaysNotChosenOnlyWhileNothingIsChosen() throws {
    let unset = UpdateCheckSetting.popupOptions(current: nil)
    #expect(unset.map(\.1) == ["Not Chosen", "Daily", "Weekly", "Monthly", "Never"])
    #expect(unset.first?.0 == nil, "it stands for no choice, which checks nothing, as Never does")
    for chosen in UpdateCheckSetting.allCases {
        let options = UpdateCheckSetting.popupOptions(current: chosen)
        #expect(options.map(\.1) == ["Daily", "Weekly", "Monthly", "Never"], "\(chosen): can't go back to Not Chosen")
        #expect(options.allSatisfy { $0.0 != nil })
    }
    // A hand-set value Fudge doesn't know reads as unset, so it shows Not Chosen too.
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("settings.json")
    try Data(#"{"updateCheck": "hourly"}"#.utf8).write(to: file)
    let setting = FudgeSettings.load(from: file).updateCheck
    #expect(setting == nil)
    #expect(UpdateCheckSetting.popupOptions(current: setting).first?.1 == "Not Chosen")
}

@Test func theUpdateRowNamesTheRunningVersion() {
    let available = UpdateStatus(lastCheck: Date(timeIntervalSince1970: 0), available: release("v0.3.1"))
    #expect(available.headline(version: "0.3.0") == "Fudge 0.3.1 is available")
    #expect(available.details(version: "0.3.0", locale: Locale(identifier: "en_US")).first == "You have Fudge 0.3.0")
    #expect(!UpdateStatus(lastCheck: Date()).details(version: "0.3.0").contains("You have Fudge 0.3.0"))
}
