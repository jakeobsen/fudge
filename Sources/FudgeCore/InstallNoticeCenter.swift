import Foundation

/// The builds that ended in the store's `installing/` folder (SPEC-156 C.2), as the app reads them: each valid
/// `<pid>.ended.json` whose `<pid>.json` is there and valid, by the store reader's rules. An outcome whose record is gone
/// is left out, since its store's run ended and reported it. Both are read as the store reads them: regular files only,
/// never through a link, at most 4 KiB for an outcome and 64 KiB for a record.
public enum InstallOutcomeFolder {
    static let maxOutcomeBytes = 4 * 1024
    static let maxRecordBytes = 64 * 1024

    /// Whether `name` is an outcome's, the only names the app's watcher counts.
    public static func isOutcome(_ name: String) -> Bool {
        BuildOutcomeFile.pid(ofCompanion: name, suffix: ".ended.json") != nil
    }

    /// The ends in `folder`, by name, or only those of `names`; none when it can't be listed.
    public static func ends(in folder: URL, only names: Set<String>? = nil) -> [InstallEnd] {
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return listed.filter { isOutcome($0) && names?.contains($0) != false }.sorted().compactMap { name in
            guard let data = RegularFile.read(folder.appendingPathComponent(name), maxBytes: maxOutcomeBytes),
                let outcome = BuildOutcomeFile.parse(fileName: name, data: data)
            else { return nil }
            let recordName = "\(outcome.pid).json"
            guard
                let recordData = RegularFile.read(folder.appendingPathComponent(recordName), maxBytes: maxRecordBytes),
                let record = StoreBuildRecord.parse(fileName: recordName, data: recordData)
            else { return nil }
            return InstallEnd(record: record, status: outcome.status)
        }
    }
}

/// The app's one place that decides and posts install notifications (SPEC-156 C), once per build.
/// - A loaded store session's reports (`store.installEnded`) decide its builds (`report`).
/// - With no store session loaded, the watcher's outcomes do (`outcomes`); with one loaded, they decide nothing (R1).
/// - When a store session ends, the outcomes it left are decided (`sessionEnded`).
/// - At launch, the outcomes already there count as decided, with nothing posted (`foundAtLaunch`).
/// macOS is asked only through `ask`, from the user's own actions (G), at most once per run.
@MainActor
public final class InstallNoticeCenter {
    private let notifications: any InstallNotifications
    private let switches: @MainActor () -> InstallNotificationSwitches
    private var notices = InstallNotices()
    private var asked = false

    /// `switches` reads Settings → Notifications' two switches at each decision.
    public init(
        notifications: any InstallNotifications, switches: @escaping @MainActor () -> InstallNotificationSwitches
    ) {
        self.notifications = notifications
        self.switches = switches
    }

    /// A loaded store's report of an install or update it saw end; `onScreen`: the panel is visible and its command is
    /// a store session.
    public func report(_ end: InstallEnd, onScreen: Bool) async -> InstallAnswer {
        await decide(end, onScreen: onScreen)
    }

    /// Outcomes the watcher read. With a store session loaded they decide nothing: its own reports do. Otherwise each is
    /// decided, the store being by definition not on screen.
    public func outcomes(_ ends: [InstallEnd], storeLoaded: Bool) async {
        guard !storeLoaded else { return }
        for end in ends { _ = await decide(end, onScreen: false) }
    }

    /// A store session ended: the outcomes that still have their records (`InstallOutcomeFolder.ends`) are decided, once
    /// each, so one it reported isn't decided again. `onScreen`: another store session is on screen by then.
    public func sessionEnded(_ ends: [InstallEnd], onScreen: Bool) async {
        for end in ends { _ = await decide(end, onScreen: onScreen) }
    }

    /// The outcomes found at launch ended while Fudge wasn't running: decided, with nothing posted, so neither the stream
    /// nor a later read posts them.
    public func foundAtLaunch(_ builds: [InstallBuild]) {
        for build in builds { notices.markDecided(build) }
    }

    /// Asks macOS whether Fudge may show notifications, only while it hasn't been asked and at most once per run.
    /// `needsSwitch`: a confirmed install asks only with either switch on; Ask Now asks either way.
    public func ask(needsSwitch: Bool) async {
        guard !asked, !needsSwitch || switches().any else { return }
        guard await notifications.permission() == .notAsked, !asked else { return }
        asked = true
        await notifications.requestPermission()
    }

    private func decide(_ end: InstallEnd, onScreen: Bool) async -> InstallAnswer {
        if let earlier = notices.answer(for: end.build) { return earlier }
        let permission = await notifications.permission()
        let (answer, notice) = notices.decide(end, onScreen: onScreen, switches: switches(), permission: permission)
        guard let notice else { return answer }
        do {
            try await notifications.post(notice)
            return answer
        } catch {
            if let build = end.build { notices.markDecided(build, onScreen: onScreen) }
            return InstallAnswer(onScreen: onScreen, notified: false)
        }
    }
}
