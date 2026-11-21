import Foundation

/// How often Fudge asks GitHub for a new release (`updateCheck` in `settings.json`). Unset, nothing is checked until
/// the user chooses, on onboarding's Updates step or the General page.
public enum UpdateCheckSetting: String, Sendable, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly
    case off

    public var id: Self { self }

    /// How old the last successful check may be before the next one; nil when it's off.
    public var interval: TimeInterval? {
        switch self {
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        case .monthly: 30 * 24 * 3600
        case .off: nil
        }
    }

    /// The General page's popup: Daily, Weekly, Monthly, Never.
    public var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .off: "Never"
        }
    }

    /// What the popup says while nothing has been chosen (FUD-135 §3). It behaves as Never until a choice is made.
    public static let notChosenTitle = "Not Chosen"

    /// The General page's popup for `current`: while it's unset (nil, or an unknown value in `settings.json`), "Not
    /// Chosen" first, then the four; once something is chosen, only the four, so "Not Chosen" can't be picked again.
    public static func popupOptions(current: UpdateCheckSetting?) -> [(UpdateCheckSetting?, String)] {
        let choices = allCases.map { (Optional($0), $0.title) }
        return current == nil ? [(nil, notChosenTitle)] + choices : choices
    }

    /// Onboarding's choices: Daily, Weekly, Monthly, Off.
    public var onboardingTitle: String {
        self == .off ? "Off" : title
    }

    /// The value in `settings.json`; anything else, or nothing, is unset.
    public init?(settingsValue value: Any?) {
        guard let text = value as? String, let setting = Self(rawValue: text) else { return nil }
        self = setting
    }
}

/// A version as semver.org 2.0.0 defines it (`1.2.0`, `1.2.0-rc.1`, `1.2.0+build.5`), compared by its precedence.
/// Build metadata is accepted and dropped, since it doesn't count for precedence.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The dot-separated identifiers after "-"; empty for a release.
    public let preRelease: [String]

    public init(major: Int, minor: Int, patch: Int, preRelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    /// Parses `major.minor.patch[-pre.release][+build]` exactly: no "v", no leading zeros in numbers, ASCII only.
    public init?(_ text: String) {
        var rest = Substring(text)
        if let plus = rest.firstIndex(of: "+") {
            let build = rest[rest.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false)
            guard build.allSatisfy(Self.isIdentifier) else { return nil }
            rest = rest[..<plus]
        }
        var preRelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let identifiers = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy({ Self.isIdentifier($0) && !Self.hasLeadingZero($0) }) else { return nil }
            preRelease = identifiers.map(String.init)
            rest = rest[..<dash]
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
            numbers.allSatisfy({ Self.isNumeric($0) && !Self.hasLeadingZero($0) }),
            let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2])
        else { return nil }
        self.init(major: major, minor: minor, patch: patch, preRelease: preRelease)
    }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (preRelease.isEmpty ? "" : "-" + preRelease.joined(separator: "."))
    }

    /// Precedence: major, minor and patch as numbers; then a pre-release is lower than its release; then the
    /// pre-release identifiers left to right, numbers as numbers and below words, words in ASCII order, and fewer
    /// identifiers lower when all before are equal.
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.preRelease, rhs.preRelease) where left != right {
            switch (isNumeric(left[...]), isNumeric(right[...])) {
            // No leading zeros, so the longer number is the bigger one, and equal lengths compare as text.
            case (true, true): return left.count != right.count ? left.count < right.count : left < right
            case (true, false): return true
            case (false, true): return false
            case (false, false): return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
        }
        return lhs.preRelease.count < rhs.preRelease.count
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "-" || isAlphanumeric($0)) }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isNumeric(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// A number with a leading zero ("01"), which semver doesn't allow.
    private static func hasLeadingZero(_ text: Substring) -> Bool {
        isNumeric(text) && text.count > 1 && text.first == "0"
    }
}

/// The version Fudge runs, as the Makefile writes it into `Info.plist`: `git describe --tags --always --dirty`.
public enum RunningVersion: Sendable, Equatable {
    /// Built from a tag (`v0.3.0`) or after one (`v0.2.0-14-g51ba5a2`): the tag's version.
    case tagged(SemanticVersion)
    /// No version tag behind it: a bare commit (`8f8e040`), `dev`, or anything else. It counts as older than any
    /// release.
    case untagged

    /// Takes off, by their exact shapes, a trailing `-dirty`, then `git describe`'s `-<commits>-g<hex>`, then a
    /// leading `v`, and parses what's left as a semantic version. So `v0.2.0-14-g51ba5a2-dirty` is 0.2.0, and
    /// `v1.2.0-rc.1-3-gabc1234` is 1.2.0-rc.1. It also reads the app's short version for a build after a tag
    /// (`0.2.0-dev+14.51ba5a2` is 0.2.0), in case that's all an `Info.plist` has.
    public init(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasSuffix("-dirty") { rest.removeLast("-dirty".count) }
        if let match = rest.wholeMatch(of: /(.+)-[0-9]+-g[0-9a-f]{4,64}/) { rest = String(match.1) }
        if rest.hasPrefix("v") { rest.removeFirst() }
        guard let version = SemanticVersion(rest) else {
            self = .untagged
            return
        }
        // `make app`'s CFBundleShortVersionString for a build after a tag: `0.3.0-dev+14.a539cdd` is 0.3.0, and
        // `1.2.0-rc.1.dev+3.abc1234` is 1.2.0-rc.1. Only with build metadata, so a tag named `v1.0.0-dev` stays one.
        if rest.contains("+"), version.preRelease.last == "dev" {
            self = .tagged(
                SemanticVersion(
                    major: version.major, minor: version.minor, patch: version.patch,
                    preRelease: version.preRelease.dropLast()))
            return
        }
        self = .tagged(version)
    }

    /// Whether `release` is newer than this build: its version beats the tag's. A build after `v0.2.0` isn't older
    /// than 0.2.0, which it already has; an untagged build is older than every release.
    public func isOlder(than release: SemanticVersion) -> Bool {
        switch self {
        case .tagged(let base): base < release
        case .untagged: true
        }
    }
}

/// A release of Fudge on GitHub: a `v` tag with a semantic version.
public struct Release: Sendable, Hashable {
    /// `v0.9.0`.
    public let tag: String
    public let version: SemanticVersion
    /// The release's page, made from the tag (GitHub's own `html_url` isn't used).
    public let pageURL: URL

    /// Nil unless `tag` is `v` and a semantic version.
    public init?(tag: String) {
        guard tag.hasPrefix("v"), let version = SemanticVersion(String(tag.dropFirst())),
            let url = URL(string: UpdateCheck.releasePagePrefix + tag)
        else { return nil }
        self.tag = tag
        self.version = version
        pageURL = url
    }
}

/// Fetches `releases/latest` from GitHub. The app's fetcher uses its own `URLSession`; tests use a fake.
public protocol ReleaseFetcher: Sendable {
    /// The answer's body, or nil when GitHub has no release yet (404).
    func fetchLatestRelease() async throws -> Data?
}

/// Why a check failed, as the General page says it.
public enum UpdateCheckFailure: Error, Equatable, LocalizedError {
    case status(Int)
    case tooLarge
    case notARelease

    public var errorDescription: String? {
        switch self {
        case .status(let code): "GitHub answered \(code)"
        case .tooLarge: "GitHub's answer was over 1 MB"
        case .notARelease: "GitHub's answer wasn't a Fudge release"
        }
    }
}

/// The request, the answer, and what Fudge says about it.
public enum UpdateCheck {
    /// The newest full release: GitHub leaves out drafts and pre-releases.
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/jakeobsen/fudge/releases/latest")!
    /// A release's page is this and its tag.
    public static let releasePagePrefix = "https://github.com/jakeobsen/fudge/releases/tag/"
    /// The answer is a few KB; anything bigger than this is refused.
    public static let byteLimit = 1_000_000

    private static let userAgentCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-_")

    /// `Fudge/<version>`, with only the characters a User-Agent's version may hold.
    public static func userAgent(version: String) -> String {
        let kept = version.filter { userAgentCharacters.contains($0) }
        return kept.isEmpty ? "Fudge" : "Fudge/\(kept)"
    }

    /// Reads a response body, refusing one over `limit` bytes: at once when its announced length is, else as soon
    /// as it gets there.
    public static func readBody<Bytes: AsyncSequence>(
        _ bytes: Bytes, expectedLength: Int64 = -1, limit: Int = byteLimit
    ) async throws -> Data where Bytes.Element == UInt8 {
        if expectedLength > Int64(limit) { throw UpdateCheckFailure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw UpdateCheckFailure.tooLarge }
        }
        return data
    }

    /// Reads `releases/latest`: its `tag_name`, `draft` and `prerelease`. A draft or a pre-release is nil, as if
    /// there were none; so is a tag with a pre-release version. A body over 1 MB, one that isn't a release, or a tag
    /// that isn't `v` and a semantic version, throws.
    public static func parseLatest(_ data: Data) throws -> Release? {
        guard data.count <= byteLimit else { throw UpdateCheckFailure.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String
        else { throw UpdateCheckFailure.notARelease }
        if try flag(object["draft"]) || flag(object["prerelease"]) { return nil }
        guard let release = Release(tag: tag) else { throw UpdateCheckFailure.notARelease }
        return release.version.isPreRelease ? nil : release
    }

    /// A JSON `true` or `false`, or false when it's missing. Anything else, a number included, isn't GitHub's answer.
    private static func flag(_ value: Any?) throws -> Bool {
        guard let value else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw UpdateCheckFailure.notARelease
        }
        return number.boolValue
    }

    /// The menu bar item's entry: "Fudge 0.9.0 Is Available…".
    public static func menuTitle(_ release: Release) -> String {
        "Fudge \(release.version) Is Available…"
    }

    /// The HUD, and the General page's line: "Fudge 0.9.0 is available".
    public static func availableText(_ release: Release) -> String {
        "Fudge \(release.version) is available"
    }
}

/// What Fudge remembers about checking (`update-check.json`).
public struct UpdateCheckState: Sendable, Equatable {
    /// When the last check ran, whatever its result.
    public var lastCheck: Date?
    /// When a check last got an answer.
    public var lastSuccess: Date?
    /// The newest release that answer named; nil when there was none.
    public var latest: Release?
    /// Why the last check failed; nil when it got an answer.
    public var failure: String?
    /// When scheduled checks failed since the last success, for the daily limit.
    public var failedChecks: [Date]
    /// The version the HUD has announced, so it says each one once.
    public var announced: SemanticVersion?

    public init(
        lastCheck: Date? = nil, lastSuccess: Date? = nil, latest: Release? = nil, failure: String? = nil,
        failedChecks: [Date] = [], announced: SemanticVersion? = nil
    ) {
        self.lastCheck = lastCheck
        self.lastSuccess = lastSuccess
        self.latest = latest
        self.failure = failure
        self.failedChecks = failedChecks
        self.announced = announced
    }

    /// Reads the file tolerantly: a missing or broken file is nothing checked yet, and a value of the wrong type, a
    /// tag that isn't a release's or a date that doesn't parse reads as unset.
    public static func load(from file: URL) -> UpdateCheckState {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return UpdateCheckState() }
        let dates = ISO8601DateFormatter()
        func date(_ key: String) -> Date? { (object[key] as? String).flatMap(dates.date(from:)) }
        return UpdateCheckState(
            lastCheck: date("lastCheck"), lastSuccess: date("lastSuccess"),
            latest: (object["latest"] as? String).flatMap(Release.init(tag:)), failure: object["failure"] as? String,
            failedChecks: (object["failedChecks"] as? [Any] ?? []).compactMap {
                ($0 as? String).flatMap(dates.date(from:))
            },
            announced: (object["announced"] as? String).flatMap(SemanticVersion.init))
    }

    /// Writes the file atomically. A broken one is replaced: it holds nothing but this.
    public func save(to file: URL) throws {
        let dates = ISO8601DateFormatter()
        var object: [String: Any] = [:]
        object["lastCheck"] = lastCheck.map(dates.string(from:))
        object["lastSuccess"] = lastSuccess.map(dates.string(from:))
        object["latest"] = latest?.tag
        object["failure"] = failure
        object["failedChecks"] = failedChecks.isEmpty ? nil : failedChecks.map(dates.string(from:))
        object["announced"] = announced?.description
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

/// When Fudge checks by itself. The app asks at launch and every hour; Check Now doesn't ask.
public enum UpdateCheckPolicy {
    /// At most this many scheduled checks may fail in a day; then none until the oldest is a day old.
    public static let maximumFailuresPerDay = 4
    public static let day: TimeInterval = 24 * 3600

    /// Due when the setting is chosen and on, the last success is older than its interval (or there's none, or it's
    /// in the future, after the clock was changed), and fewer than 4 scheduled checks failed in the last day. A
    /// failure is tried again at the next hourly tick, since the last success hasn't moved.
    public static func isDue(setting: UpdateCheckSetting?, state: UpdateCheckState, now: Date) -> Bool {
        guard let interval = setting?.interval else { return false }
        guard recentFailures(state.failedChecks, now: now).count < maximumFailuresPerDay else { return false }
        guard let last = state.lastSuccess, last <= now else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// The failures of the last day, leaving out any from the future.
    public static func recentFailures(_ failures: [Date], now: Date) -> [Date] {
        failures.filter { $0 <= now && now.timeIntervalSince($0) < day }
    }
}

/// What the General page shows about updates.
public struct UpdateStatus: Sendable, Equatable {
    public var checking: Bool
    public var lastCheck: Date?
    /// A release newer than the running Fudge, from the last answer.
    public var available: Release?
    /// Why the last check failed.
    public var failure: String?

    public init(checking: Bool = false, lastCheck: Date? = nil, available: Release? = nil, failure: String? = nil) {
        self.checking = checking
        self.lastCheck = lastCheck
        self.available = available
        self.failure = failure
    }

    /// The line beside Check Now.
    public var headline: String {
        if checking { return "Checking for updates…" }
        if let available { return UpdateCheck.availableText(available) }
        if failure != nil { return "Couldn't check for updates" }
        return lastCheck == nil ? "Not checked yet" : "Fudge is up to date"
    }

    /// The small lines under it: why the last check failed, and when it ran.
    public func details(locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
        var lines: [String] = []
        if !checking, let failure {
            lines.append(available == nil ? failure : "Couldn't check for updates: \(failure)")
        }
        if let lastCheck {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            lines.append("Last checked: \(formatter.string(from: lastCheck))")
        }
        return lines
    }
}

/// Checks for a new release when `UpdateCheckPolicy` says so, or at once for Check Now, one check at a time, and
/// keeps the state in `update-check.json`. Nothing is downloaded or installed: it only says so.
@MainActor
public final class UpdateChecker {
    public private(set) var state: UpdateCheckState
    public private(set) var checking = false
    public private(set) var setting: UpdateCheckSetting?
    public let running: RunningVersion
    /// Called whenever `status` may have changed.
    public var onChange: () -> Void = {}
    /// Called once per version, when a check finds one newer than the running Fudge: the HUD.
    public var onNewRelease: (Release) -> Void = { _ in }

    private let fetcher: any ReleaseFetcher
    private let stateFile: URL?

    /// Without a `stateFile`, the state is kept in memory only (snapshot runs).
    public init(fetcher: any ReleaseFetcher, stateFile: URL?, running: RunningVersion, setting: UpdateCheckSetting?) {
        self.fetcher = fetcher
        self.stateFile = stateFile
        self.running = running
        self.setting = setting
        state = stateFile.map(UpdateCheckState.load(from:)) ?? UpdateCheckState()
    }

    /// A release newer than the running Fudge, from the last answer.
    public var available: Release? {
        guard let latest = state.latest, running.isOlder(than: latest.version) else { return nil }
        return latest
    }

    public var status: UpdateStatus {
        UpdateStatus(checking: checking, lastCheck: state.lastCheck, available: available, failure: state.failure)
    }

    /// The setting changed (on the General page, onboarding, or an import); checks if that makes one due.
    public func setSetting(_ setting: UpdateCheckSetting?, now: Date) async {
        guard setting != self.setting else { return }
        self.setting = setting
        onChange()
        await checkIfDue(now: now)
    }

    /// At launch and every hour: checks when `UpdateCheckPolicy` says it's due.
    public func checkIfDue(now: Date) async {
        guard UpdateCheckPolicy.isDue(setting: setting, state: state, now: now) else { return }
        await check(now: now, scheduled: true)
    }

    /// Check Now: always, whatever the setting, unless a check is running.
    public func checkNow(now: Date) async {
        await check(now: now, scheduled: false)
    }

    /// Snapshot runs: as if a check had just found `release`, without asking GitHub, writing a file or the HUD.
    public func show(_ release: Release, checkedAt now: Date) {
        state.latest = release
        state.lastCheck = now
        state.lastSuccess = now
        state.failure = nil
        onChange()
    }

    private func check(now: Date, scheduled: Bool) async {
        guard !checking else { return }
        checking = true
        onChange()
        var state = self.state
        state.lastCheck = now
        do {
            let body = try await fetcher.fetchLatestRelease()
            state.latest = try body.flatMap(UpdateCheck.parseLatest)
            state.lastSuccess = now
            state.failure = nil
            state.failedChecks = []
        } catch {
            state.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state.failedChecks = UpdateCheckPolicy.recentFailures(state.failedChecks, now: now)
            if scheduled { state.failedChecks.append(now) }
        }
        self.state = state
        checking = false
        if let available, self.state.announced != available.version {
            self.state.announced = available.version
            onNewRelease(available)
        }
        if let stateFile {
            do {
                try self.state.save(to: stateFile)
            } catch {
                FileHandle.standardError.write(Data("fudge: couldn't save \(stateFile.path): \(error)\n".utf8))
            }
        }
        onChange()
    }
}
