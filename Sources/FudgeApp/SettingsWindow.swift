import AppKit
import FudgeCore
import Observation
import SwiftUI

/// What the Settings window shows: installed extensions and their preference values.
@MainActor
@Observable
final class SettingsModel {
    private(set) var extensions: [InstalledExtension] = []
    /// The page shown. Change it with `select(_:)`, which ends a hotkey recording on the page being left.
    private(set) var selected: String?
    /// The General and Commands pages' entries in the sidebar; extension names can't start with ":".
    static let generalPage = ":general"
    static let commandsPage = ":commands"
    static let permissionsPage = ":permissions"
    static let quicklinksPage = ":quicklinks"
    static let snippetsPage = ":snippets"
    static let colorPickerPage = ":color-picker"
    static let windowManagementPage = ":window-management"
    static let signInPage = ":sign-in"
    static let calendarPage = ":calendar"
    /// Every installed extension, for the Commands page.
    private(set) var allExtensions: [InstalledExtension] = []
    /// `settings.json`, as the Commands page edits it.
    private(set) var fudgeSettings = FudgeSettings()
    /// Which hotkey is being recorded (a command id, or `launcherRecording`).
    private(set) var recorder = HotKeyRecorder()
    var recording: String? { recorder.recording }
    /// A short message under a command's hotkey: why a recording was refused.
    private(set) var hotkeyMessages: [String: String] = [:]
    /// A short note under a hotkey that was saved: the command that isn't installed it was taken from.
    private(set) var hotkeyNotes: [String: String] = [:]
    /// A short message under a command's alias: why it was refused.
    private(set) var aliasMessages: [String: String] = [:]
    /// Set while `settings.json` isn't a JSON object, so changes can't be saved; the General and Commands pages say so.
    private(set) var settingsProblem: String?
    /// The launcher's own hotkey, which commands can't take; kept current by the app delegate.
    var launcherHotkey = HotKeySpec.default
    /// The system refused the launcher's hotkey: another app has it, so it doesn't work.
    var launcherHotkeyInUse = false
    /// Changes the launcher's hotkey: registers it, then runs the save, putting everything back if the save fails
    /// (`HotKeyRegistry.changeLauncher`). Set by the app delegate.
    @ObservationIgnored var changeLauncherHotkey: (HotKeySpec, () -> Bool) -> HotKeyRegistry.LauncherChange = {
        _, save in save() ? .changed : .notSaved
    }
    /// Suspend and resume fudge's global hotkeys around a recording, so pressing one records it.
    @ObservationIgnored var suspendHotkeys: () -> Void = {}
    @ObservationIgnored var resumeHotkeys: () -> Void = {}
    /// Registers the command hotkeys from `settings.json`; returns the command ids the system refused.
    @ObservationIgnored var applyHotkeys: () -> Set<String> = { [] }
    /// Accessibility's live status, for the Permissions page and onboarding; the app delegate sets the real one.
    @ObservationIgnored var accessibility = AccessibilityStatus(access: FixedAccessibility(trusted: false))
    /// Show Onboarding Again; set by the app delegate.
    @ObservationIgnored var showOnboarding: () -> Void = {}
    private(set) var stored: [String: StoredPreferences] = [:]
    @ObservationIgnored private let store: PreferenceStore
    @ObservationIgnored private let paths: FudgePaths
    @ObservationIgnored private(set) lazy var applications: [RootItem] = ApplicationIndex.scan()

    init(paths: FudgePaths) {
        self.paths = paths
        store = PreferenceStore(directory: paths.preferencesDirectory)
        reload()
    }

    func reload() {
        let installed = InstalledExtension.all(paths: paths, resources: Bundle.main.resourceURL)
        extensions = InstalledExtension.settingsPages(of: installed)
        stored = Dictionary(uniqueKeysWithValues: extensions.map { ($0.manifest.name, store.load($0.manifest.name)) })
        allExtensions = installed.sorted {
            $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending
        }
        fudgeSettings = readSettings()
        settingsProblem = FudgeSettings.isWritable(paths.settingsFile) ? nil : unreadableMessage
        loadLaunchPermissions()
        loadQuicklinks()
        loadSnippets()
        loadWindowLayouts()
        loadSignIns()
        loadCalendars()
        if selected != Self.generalPage, selected != Self.commandsPage, selected != Self.permissionsPage,
            selected != Self.quicklinksPage, selected != Self.snippetsPage, selected != Self.signInPage,
            selected != Self.colorPickerPage, selected != Self.windowManagementPage, selected != Self.calendarPage,
            !extensions.contains(where: { $0.manifest.name == selected })
        {
            select(Self.generalPage)
        }
    }

    /// Shows `page`. Leaving a page ends a hotkey recording on it, with no change, and Fudge's hotkeys resume.
    func select(_ page: String?) {
        if recorder.pageChanged(from: selected, to: page) { resumeHotkeys() }
        selected = page
        if page == Self.quicklinksPage || page == Self.commandsPage { loadQuicklinks() }
        if page == Self.snippetsPage { loadSnippets() }
        if page == Self.windowManagementPage || page == Self.commandsPage { loadWindowLayouts() }
        if page == Self.calendarPage || page == Self.permissionsPage { loadCalendars() }
    }

    /// Show Onboarding Again: a recording here ends first, since onboarding has its own hotkey step.
    func showOnboardingAgain() {
        cancelRecording()
        showOnboarding()
    }

    /// The ids of every installed command, menu-bar ones included, of Fudge's own (`BuiltInCommandGroup`) and of
    /// the quicklinks (`QuicklinkCommands`). Only their hotkeys block a key.
    private var installedCommandIDs: Set<String> {
        Set(
            allExtensions.flatMap { item in
                item.manifest.commands.map { FudgeSettings.commandID(extension: item.manifest.name, command: $0.name) }
            } + BuiltInCommandGroup.commandIDs(in: builtInGroups) + QuicklinkCommands.commandIDs(quicklinks))
    }

    /// What the Commands page's search starts with: a snapshot run's `--search`, else nothing.
    @ObservationIgnored var commandsSearch: String?

    /// Fudge's own command groups (`builtInGroups`), then the quicklinks as a group of their own
    /// (`QuicklinkCommands.group`), as the Commands page lists them and conflicts name them.
    var commandGroups: [BuiltInCommandGroup] {
        builtInGroups + [QuicklinkCommands.group(quicklinks)]
    }

    // MARK: - General

    /// Whether the calculator downloads exchange rates (`currencyRates` in `settings.json`).
    var currencyRates: Bool { fudgeSettings.currencyRates }
    /// Tells the exchange rate updater; set by the app delegate.
    @ObservationIgnored var currencyRatesChanged: (Bool) -> Void = { _ in }

    func setCurrencyRates(_ on: Bool) {
        // A settings.json that can't be written is refused, with the banner, and nothing is turned on.
        guard FudgeSettings.load(from: paths.settingsFile).currencyRates != on, change({ $0.currencyRates = on })
        else { return }
        currencyRatesChanged(on)
    }

    // MARK: - Hyperkey

    /// **Hyperkey (Caps Lock)** (`hyperkey` in `settings.json`, SPEC-093).
    var hyperkey: Bool { fudgeSettings.hyperkey }
    /// **Quick press toggles Caps Lock** (`hyperkeyQuickPress`).
    var hyperkeyQuickPress: Bool { fudgeSettings.hyperkeyQuickPress }
    /// What stopped Hyperkey, shown under its switch: no Accessibility, or Caps Lock mapped elsewhere.
    var hyperkeyProblem: String?
    /// Whether Fudge may use Accessibility, asked as a user's click is: macOS's prompt the first time, Fudge's offer of
    /// the pane after that. Set by the app delegate.
    @ObservationIgnored var mayUseAccessibility: () -> Bool = { false }
    /// Starts Hyperkey and calls back with what stopped it, if anything (`HyperkeyService.turnOn`); set by the app
    /// delegate.
    @ObservationIgnored var turnOnHyperkey: (Bool, @escaping @MainActor (String?) -> Void) -> Void = { _, done in
        done(nil)
    }
    @ObservationIgnored var turnOffHyperkey: () -> Void = {}
    @ObservationIgnored var hyperkeyQuickPressChanged: () -> Void = {}

    /// The switch, and onboarding's step. Turning it on needs Accessibility, and is saved only once Caps Lock is
    /// remapped, so a refusal leaves it off with the reason under the switch.
    func setHyperkey(_ on: Bool) {
        guard FudgeSettings.load(from: paths.settingsFile).hyperkey != on else { return }
        guard on else {
            guard change({ $0.hyperkey = false }) else { return }
            hyperkeyProblem = nil
            turnOffHyperkey()
            return
        }
        guard FudgeSettings.isWritable(paths.settingsFile) else {
            settingsProblem = unreadableMessage
            return
        }
        guard mayUseAccessibility() else {
            hyperkeyProblem = HyperkeyService.needsAccessibility
            return
        }
        turnOnHyperkey(hyperkeyQuickPress) { [weak self] problem in
            guard let self else { return }
            hyperkeyProblem = problem
            guard problem == nil else { return }
            // Remapped; a settings.json that can't be written now puts Caps Lock back.
            if !change({ $0.hyperkey = true }) { turnOffHyperkey() }
        }
    }

    func setHyperkeyQuickPress(_ on: Bool) {
        guard hyperkeyQuickPress != on, change({ $0.hyperkeyQuickPress = on }) else { return }
        hyperkeyQuickPressChanged()
    }

    /// The Color Picker's Copy Format (`colorFormat` in `settings.json`).
    var colorFormat: ColorFormat { fudgeSettings.colorFormat }
    /// Recent Colors, if it's open in the launcher, is drawn again with the new format first; set by the app delegate.
    @ObservationIgnored var colorFormatChanged: () -> Void = {}

    func setColorFormat(_ format: ColorFormat) {
        guard format != colorFormat, change({ $0.colorFormat = format }) else { return }
        colorFormatChanged()
    }

    /// How the calculator reads and shows numbers (`numberFormat` in `settings.json`).
    var numberFormat: NumberFormatSetting { fudgeSettings.numberFormat }
    /// Re-evaluates root search's calculator card; set by the app delegate.
    @ObservationIgnored var numberFormatChanged: () -> Void = {}

    /// Saved through `change {}`, so a broken `settings.json` is refused and the banner says why.
    func setNumberFormat(_ format: NumberFormatSetting) {
        guard format != numberFormat, change({ $0.numberFormat = format }) else { return }
        numberFormatChanged()
    }

    // MARK: - Updates

    /// How often Fudge checks for a new release (`updateCheck` in `settings.json`); nil until it's chosen.
    var updateCheck: UpdateCheckSetting? { fudgeSettings.updateCheck }
    /// What the last check found, and whether one is running; kept current by the app delegate.
    var updateStatus = UpdateStatus()
    /// Tells the update checker; set by the app delegate.
    @ObservationIgnored var updateCheckChanged: (UpdateCheckSetting) -> Void = { _ in }
    /// Check Now; set by the app delegate.
    @ObservationIgnored var checkForUpdates: () -> Void = {}
    /// Download…: the release's page in the browser; set by the app delegate.
    @ObservationIgnored var openReleasePage: (Release) -> Void = { _ in }

    /// Saved through `change {}`, so a broken `settings.json` is refused and the banner says why. The value shown
    /// while it's unset counts as a change, so onboarding's Continue saves its preselected Daily.
    func setUpdateCheck(_ setting: UpdateCheckSetting) {
        guard setting != updateCheck, change({ $0.updateCheck = setting }) else { return }
        updateCheckChanged(setting)
    }

    // MARK: - Open at Login and search history

    /// fudge as a login item; the app delegate sets the real one, and snapshots a fake.
    @ObservationIgnored var loginItem: any LoginItem = FixedLoginItem(.notRegistered)
    /// Where the running app is: Open at Login can't be turned on from the disk image or a translocated copy. The
    /// app delegate reads it at launch; snapshots keep `.installed`.
    @ObservationIgnored var appLocation = AppLocation.installed
    /// The Open at Login switch, from the system's real status (`refreshLoginItem()`), never a stored value.
    private(set) var loginItemState = LoginItemState(.notRegistered)
    /// Why turning Open at Login on or off failed, until the next try.
    private(set) var loginItemError: String?
    /// Clears root search's launch history; set by the app delegate.
    @ObservationIgnored var clearSearchHistory: () -> Void = {}

    /// Import / Export on the General page.
    @ObservationIgnored private(set) lazy var backup = BackupController(paths: paths, settings: self)
    /// Onboarding's Restore from a Backup…: the same flow, with its own sheets, so they show on the onboarding
    /// window and not on General as well.
    @ObservationIgnored private(set) lazy var onboardingBackup = BackupController(paths: paths, settings: self)
    /// After an import: the launcher reloads, and the hotkeys and the currency setting are applied again. Set by
    /// the app delegate.
    @ObservationIgnored var imported: () -> Void = {}

    /// Reads the login item's status again: a change made in System Settings shows too.
    func refreshLoginItem() {
        loginItemState = LoginItemState(loginItem.status)
    }

    func setOpenAtLogin(_ on: Bool) {
        (loginItemState, loginItemError) = LoginItemState.change(loginItem, to: on, location: appLocation)
    }

    func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    // MARK: - Extensions that open other extensions

    /// The answers to "Allow <A> to open <B>'s commands?" (`launch-permissions.json`).
    private(set) var launchPermissions: [LaunchPermissions.Entry] = []
    /// The file holds something fudge can't read, so the answers can't be changed here.
    private(set) var launchPermissionsUnreadable = false

    /// An installed extension's title, or nil when it isn't installed.
    func extensionTitle(_ name: String) -> String? {
        allExtensions.first { $0.manifest.name == name }?.manifest.title
    }

    func setLaunchPermission(_ allowed: Bool, caller: String, target: String) {
        changeLaunchPermissions { $0.record(allowed, caller: caller, target: target) }
    }

    /// Forgets an answer, so the user is asked again next time.
    func forgetLaunchPermission(caller: String, target: String) {
        changeLaunchPermissions { $0.forget(caller: caller, target: target) }
    }

    private func loadLaunchPermissions() {
        launchPermissions = LaunchPermissions.load(from: paths.launchPermissionsFile).entries
        launchPermissionsUnreadable = LaunchPermissions.isUnreadable(paths.launchPermissionsFile)
    }

    /// Reads the file again first, so an answer given meanwhile isn't lost, then edits and saves it.
    private func changeLaunchPermissions(_ edit: (inout LaunchPermissions) -> Void) {
        var permissions = LaunchPermissions.load(from: paths.launchPermissionsFile)
        edit(&permissions)
        do {
            try permissions.save(to: paths.launchPermissionsFile)
        } catch {
            FudgeLog.error("couldn't save launch permissions: \(error)")
        }
        loadLaunchPermissions()
    }

    // MARK: - Quicklinks

    /// The quicklinks, by name, as the Quicklinks page lists them. Read again whenever the page is shown or the
    /// window becomes key, so changes made in the launcher show.
    private(set) var quicklinks: [Quicklink] = []
    /// `quicklinks.json` holds something Fudge can't read, so the page can't change it.
    private(set) var quicklinksUnreadable = false
    /// Root search reads the quicklinks again; set by the app delegate.
    @ObservationIgnored var quicklinksChanged: () -> Void = {}
    /// Open With's choices, with their bundle ids.
    @ObservationIgnored private(set) lazy var quicklinkApplications: [QuicklinkApplication] =
        applications
        .compactMap { item in
            guard case .application(let url) = item.kind, let bundleId = Bundle(url: url)?.bundleIdentifier else {
                return nil
            }
            return QuicklinkApplication(name: item.title, bundleId: bundleId, path: url.path)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    func loadQuicklinks() {
        let file = paths.quicklinksFile
        quicklinks = QuicklinkStore.load(from: file).quicklinks.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        quicklinksUnreadable = !QuicklinkStore.isWritable(file)
    }

    /// The name Open With shows: the application's, or "Default".
    func applicationName(of quicklink: Quicklink) -> String {
        guard let bundleId = quicklink.application else { return "Default" }
        if let app = quicklinkApplications.first(where: { $0.bundleId == bundleId }) { return app.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        }
        return bundleId
    }

    enum QuicklinkSave: Equatable {
        case saved
        case problems(QuicklinkDraft.Problems)
        case failed(String)
    }

    /// Saves the sheet's quicklink, after reading the file again: as a new one, or in place of the one edited.
    func saveQuicklink(_ draft: QuicklinkDraft) -> QuicklinkSave {
        let file = paths.quicklinksFile
        var store = QuicklinkStore.load(from: file)
        let problems = draft.problems(among: store.quicklinks)
        guard problems.isEmpty else { return .problems(problems) }
        draft.save(into: &store)
        do {
            try store.save(to: file)
        } catch {
            loadQuicklinks()
            return .failed(String(describing: error))
        }
        loadQuicklinks()
        quicklinksChanged()
        return .saved
    }

    func deleteQuicklink(id: String) {
        let file = paths.quicklinksFile
        var store = QuicklinkStore.load(from: file)
        store.remove(id: id)
        do {
            try store.save(to: file)
            // Its alias, hotkey and Enabled go with it (`QuicklinkCommands.prune`).
            var pruned = FudgeSettings.load(from: paths.settingsFile)
            if QuicklinkCommands.prune(&pruned, in: store) {
                change { QuicklinkCommands.prune(&$0, in: store) }
            }
        } catch {
            FudgeLog.error("couldn't delete the quicklink: \(error)")
        }
        loadQuicklinks()
        quicklinksChanged()
    }

    // MARK: - Calendar (SPEC-092)

    /// The calendars, read only with access, which only My Schedule's own run asks for; set by the app delegate,
    /// which shares the launcher's.
    @ObservationIgnored var calendarSource: any CalendarSource = FixedCalendarSource(access: .notDetermined)
    /// Tells the launcher to draw My Schedule again; set by the app delegate.
    @ObservationIgnored var calendarChanged: () -> Void = {}
    private(set) var calendarAccess = CalendarAuthorization.notDetermined
    /// The Mac's calendars, by title, as the Calendar page lists them.
    private(set) var calendars: [CalendarInfo] = []

    /// Reads the access and the calendars again, without asking: when the page is shown or the window becomes key.
    /// The calendars are read off the main thread, since EventKit waits on the calendar agent.
    func loadCalendars() {
        calendarAccess = calendarSource.authorization
        let source = calendarSource
        Task {
            let read = await Task.detached(priority: .userInitiated) { source.calendars() }.value
            calendars = read.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var calendarDaysAhead: Int { fudgeSettings.calendarDaysAhead }

    func isCalendarShown(_ id: String) -> Bool {
        !fudgeSettings.calendarHidden.contains(id)
    }

    /// Ticks or unticks a calendar; an unticked one is kept by id, so a calendar added later shows.
    func setCalendarShown(_ shown: Bool, id: String) {
        guard
            change({ settings in
                settings.calendarHidden.removeAll { $0 == id }
                if !shown { settings.calendarHidden.append(id) }
            })
        else { return }
        calendarChanged()
    }

    func setCalendarDaysAhead(_ days: Int) {
        guard days != calendarDaysAhead, change({ $0.calendarDaysAhead = days }) else { return }
        calendarChanged()
    }

    // MARK: - Snippets

    /// The snippets, by name, as the Snippets page lists them. Read again whenever the page is shown or the window
    /// becomes key, so changes made in the launcher show.
    private(set) var snippets: [Snippet] = []
    /// `snippets.json` holds something Fudge can't read, so the page can't change it.
    private(set) var snippetsUnreadable = false
    /// Search Snippets, if it's open in the launcher, and snippet expansion read the snippets again; set by the app
    /// delegate.
    @ObservationIgnored var snippetsChanged: () -> Void = {}

    /// **Expand Snippets as You Type** (`expandSnippets` in `settings.json`, SPEC-078 §5).
    var expandSnippets: Bool { fudgeSettings.expandSnippets }
    /// Starts or stops snippet expansion's keyboard tap; set by the app delegate.
    @ObservationIgnored var snippetExpansionChanged: () -> Void = {}
    /// Input Monitoring's status for the Snippets page. Snapshot runs get a fixed one.
    @ObservationIgnored var inputMonitoring = InputMonitoringStatus()

    /// Turns expansion on, the switch's way and onboarding's: saved, then macOS is asked for Input Monitoring when
    /// it isn't allowed (its prompt the first time, the pane after that).
    func turnOnSnippetExpansion() {
        // Fresh, since onboarding shows no Snippets page to keep it current.
        inputMonitoring.refresh()
        setExpandSnippets(true)
        if expandSnippets, !inputMonitoring.isAllowed { InputMonitoring.request() }
    }

    func setExpandSnippets(_ on: Bool) {
        // A settings.json that can't be written is refused, with the banner, and nothing is turned on.
        guard FudgeSettings.load(from: paths.settingsFile).expandSnippets != on, change({ $0.expandSnippets = on })
        else { return }
        snippetExpansionChanged()
    }

    func loadSnippets() {
        let file = paths.snippetsFile
        snippets = SnippetList.sorted(SnippetStore.load(from: file).snippets)
        snippetsUnreadable = !SnippetStore.isWritable(file)
    }

    enum SnippetSave: Equatable {
        case saved
        case problems(SnippetDraft.Problems)
        case failed(String)
    }

    /// Saves the sheet's snippet, after reading the file again: as a new one, or in place of the one edited.
    func saveSnippet(_ draft: SnippetDraft) -> SnippetSave {
        let file = paths.snippetsFile
        var store = SnippetStore.load(from: file)
        let problems = draft.problems(among: store.snippets)
        guard problems.isEmpty else { return .problems(problems) }
        draft.save(into: &store)
        do {
            try store.save(to: file)
        } catch {
            loadSnippets()
            return .failed(String(describing: error))
        }
        loadSnippets()
        snippetsChanged()
        return .saved
    }

    func deleteSnippet(id: String) {
        let file = paths.snippetsFile
        var store = SnippetStore.load(from: file)
        store.remove(id: id)
        do {
            try store.save(to: file)
        } catch {
            FudgeLog.error("couldn't delete the snippet: \(error)")
        }
        loadSnippets()
        snippetsChanged()
    }

    // MARK: - Window Management

    /// The custom positions and saved layouts (SPEC-094), for the Window Management and Commands pages. Read again
    /// whenever either page is shown or the window becomes key, so a layout saved in the launcher shows.
    private(set) var windowLayouts = WindowLayoutStore()
    /// `window-layouts.json` holds something Fudge can't read, so the page can't change it.
    private(set) var windowLayoutsUnreadable = false
    /// In a snapshot run, the position sheet the Window Management page shows in place, never as a sheet
    /// (`--edit-position`).
    var snapshotPositionDraft: PositionDraft?

    var windowPositions: [CustomWindowPosition] { WindowLayoutStore.byName(windowLayouts.positions, \.name) }
    var savedLayouts: [SavedWindowLayout] { WindowLayoutStore.byName(windowLayouts.layouts, \.name) }

    /// Fudge's command groups with the user's own window commands, as the Commands page lists them.
    var builtInGroups: [BuiltInCommandGroup] { BuiltInCommandGroup.all(with: windowLayouts) }

    func loadWindowLayouts() {
        let file = paths.windowLayoutsFile
        windowLayouts = WindowLayoutStore.load(from: file)
        windowLayoutsUnreadable = !WindowLayoutStore.isWritable(file)
    }

    enum WindowLayoutSave: Equatable {
        case saved
        case positionProblems(PositionDraft.Problems)
        case nameProblem(String)
        case failed(String)
    }

    /// Saves the sheet's position, after reading the file again: as a new one, or in place of the one edited.
    func savePosition(_ draft: PositionDraft) -> WindowLayoutSave {
        var store = WindowLayoutStore.load(from: paths.windowLayoutsFile)
        let problems = draft.problems(among: store.positions)
        guard problems.isEmpty else { return .positionProblems(problems) }
        draft.save(into: &store)
        return saveWindowLayouts(store)
    }

    /// Renames a layout, after reading the file again.
    func renameLayout(_ draft: LayoutDraft) -> WindowLayoutSave {
        var store = WindowLayoutStore.load(from: paths.windowLayoutsFile)
        if let problem = draft.problem(among: store.layouts) { return .nameProblem(problem) }
        draft.save(into: &store)
        return saveWindowLayouts(store)
    }

    /// Deletes a position, with its alias, hotkey and Enabled in `settings.json`, since no command has its id again.
    func deletePosition(id: String) {
        var store = WindowLayoutStore.load(from: paths.windowLayoutsFile)
        guard let position = store.position(id: id) else { return }
        store.removePosition(id: id)
        deleteWindowCommand(position.commandName, from: store)
    }

    /// Deletes a layout, with its command's settings, as `deletePosition` does.
    func deleteLayout(id: String) {
        var store = WindowLayoutStore.load(from: paths.windowLayoutsFile)
        guard let layout = store.layout(id: id) else { return }
        store.removeLayout(id: id)
        deleteWindowCommand(layout.commandName, from: store)
    }

    private func deleteWindowCommand(_ command: String, from store: WindowLayoutStore) {
        if case .failed(let message) = saveWindowLayouts(store) {
            FudgeLog.error("couldn't delete it: \(message)")
            return
        }
        let id = FudgeSettings.commandID(extension: BuiltInCommandGroup.windowManagement.name, command: command)
        if fudgeSettings.commands[id] != nil, change({ $0.commands[id] = nil }) { _ = applyHotkeys() }
    }

    /// Writes the file; then root search reads it again and the hotkeys follow (`applyHotkeys`).
    private func saveWindowLayouts(_ store: WindowLayoutStore) -> WindowLayoutSave {
        defer { loadWindowLayouts() }
        do {
            try store.save(to: paths.windowLayoutsFile)
        } catch {
            return .failed(String(describing: error))
        }
        _ = applyHotkeys()
        return .saved
    }

    // MARK: - The launcher's hotkey

    /// `recording` while the launcher's hotkey is being recorded, and its key in `hotkeyMessages`. Command ids always
    /// have a "/", so it can't be one.
    static let launcherRecording = ":launcher"

    /// A key pressed while recording the launcher's hotkey; the Reset button passes `.clear`. A conflict, or a
    /// shortcut the system refuses, keeps the old hotkey and says why.
    func recordLauncherHotkey(_ key: HotKeyRecording) {
        cancelRecording()
        // Check against the file as it is now, so a command hotkey added by hand meanwhile counts.
        fudgeSettings = readSettings()
        switch key.launcherEdit(commands: fudgeSettings.commandHotkeys, installed: installedCommandIDs) {
        case .keep:
            return
        case .refused(let conflict):
            hotkeyMessages[Self.launcherRecording] = message(for: conflict)
        case .set(let spec):
            setLauncherHotkey(spec)
        }
    }

    private func setLauncherHotkey(_ spec: HotKeySpec) {
        hotkeyMessages[Self.launcherRecording] = nil
        hotkeyNotes[Self.launcherRecording] = nil
        // A settings.json that isn't a JSON object is refused before anything is registered (the banner says why).
        guard FudgeSettings.isWritable(paths.settingsFile) else {
            settingsProblem = unreadableMessage
            return
        }
        let displaced = HotKeyConflict.displaced(
            by: spec, commands: fudgeSettings.commandHotkeys, installed: installedCommandIDs)
        // Registered, then saved; if the save fails, the registration goes back to what it was (the banner says why),
        // so the next launch never brings a different hotkey back unannounced.
        let result = changeLauncherHotkey(spec) {
            self.change { settings in
                settings.launcherHotkey = spec
                for id in displaced { settings.commands[id]?.hotkey = nil }
            }
        }
        switch result {
        case .changed: hotkeyNotes[Self.launcherRecording] = note(displaced)
        case .inUse: hotkeyMessages[Self.launcherRecording] = "This shortcut is in use by another app"
        case .notSaved: break
        }
    }

    // MARK: - Extension Store

    /// Whether the Extension Store is on: switched on through its consent sheet. Whether it's in fudge at all is
    /// its Enabled on the Commands page, which the switch leaves alone.
    var extensionStore: Bool { fudgeSettings.isExtensionStoreOn }
    /// Asks the user with a sheet on the Settings window; set by the window controller.
    @ObservationIgnored var confirm: (LauncherModel.AlertRequest) async -> Bool = { _ in false }
    /// Tells the launcher the store was turned on or off; set by the app delegate.
    @ObservationIgnored var extensionStoreChanged: () -> Void = {}
    /// Unloads a running store, so its git stops before its copy is deleted; set by the app delegate.
    @ObservationIgnored var stopExtensionStore: () async -> Void = {}

    /// The switch on the store's Settings page: on only after the consent sheet's Turn On, which records the date;
    /// off after its own sheet, which deletes the store's downloaded repository but keeps its record of what it
    /// installed.
    func setExtensionStore(_ on: Bool) {
        guard on != extensionStore else { return }
        Task {
            let sheet = on ? ExtensionStore.consentRequest : ExtensionStore.turnOffRequest
            guard await confirm(sheet) else { return }
            guard change({ $0.setExtensionStore(on, now: Date()) }) else { return }
            if !on {
                await stopExtensionStore()
                do {
                    try ExtensionStore.deleteRepository(paths)
                } catch {
                    FudgeLog.error("couldn't delete the store's list: \(error)")
                }
            }
            reload()
            extensionStoreChanged()
        }
    }

    /// Onboarding's Turn On Extension Store, under the consent sheet's own words: what the switch and its sheet write,
    /// and the store's Enabled too, so it's in root search straight away.
    func turnOnExtensionStore() {
        guard change({ $0.turnOnExtensionStore(now: Date()) }) else { return }
        _ = applyHotkeys()
        reload()
        extensionStoreChanged()
    }

    // MARK: - Clipboard history (SPEC-077)

    /// Whether clipboard history is on: switched on through its consent sheet.
    var clipboardHistory: Bool { fudgeSettings.isClipboardHistoryOn }
    var clipboardHistoryKeepDays: Int { fudgeSettings.clipboardHistoryKeepDays }
    var clipboardHistoryIgnoredApps: [String] { fudgeSettings.clipboardHistoryIgnoredApps }
    /// Tells the launcher's clipboard history to read the settings again; set by the app delegate.
    @ObservationIgnored var clipboardHistoryChanged: () -> Void = {}
    /// Deletes every copy and the key; set by the app delegate.
    @ObservationIgnored var deleteClipboardHistory: () -> Void = {}

    /// The switch: on only after the consent sheet's Turn On, which records the date. Off stops recording at once,
    /// then asks whether to keep what's there.
    func setClipboardHistory(_ on: Bool) {
        guard on != clipboardHistory else { return }
        Task {
            if on {
                guard await confirm(ClipboardHistorySheets.consent) else { return }
                keepClipboardHistory()
                return
            } else {
                guard change({ $0.setClipboardHistory(false, now: Date()) }) else { return }
                clipboardHistoryChanged()
                if !(await confirm(ClipboardHistorySheets.turnedOff)) { deleteClipboardHistory() }
            }
            reload()
        }
    }

    /// Turns it on, the consent having been given: the switch's sheet, or onboarding's step, which shows the same
    /// words. Writes the switch and its consent date, and starts recording.
    func keepClipboardHistory() {
        guard change({ $0.setClipboardHistory(true, now: Date()) }) else { return }
        clipboardHistoryChanged()
        reload()
    }

    func setClipboardHistoryKeepDays(_ days: Int) {
        guard change({ $0.clipboardHistoryKeepDays = days }) else { return }
        clipboardHistoryChanged()
    }

    /// Adds the app at `path` to **Ignore Apps**, by its bundle id.
    func ignoreClipboard(fromApplicationAt path: String) {
        guard let id = Bundle(path: path)?.bundleIdentifier, !clipboardHistoryIgnoredApps.contains(id) else { return }
        guard change({ $0.clipboardHistoryIgnoredApps.append(id) }) else { return }
        clipboardHistoryChanged()
    }

    func stopIgnoringClipboard(of bundleId: String) {
        guard change({ $0.clipboardHistoryIgnoredApps.removeAll { $0 == bundleId } }) else { return }
        clipboardHistoryChanged()
    }

    /// **Clear History…**: asks first.
    func clearClipboardHistory() {
        Task {
            guard await confirm(ClipboardHistorySheets.clear) else { return }
            deleteClipboardHistory()
        }
    }

    // MARK: - Sign-in (SPEC-056)

    /// The server extensions sign in through.
    var signInServer: SignInServer { fudgeSettings.signIn }
    /// The stored sign-ins, for the Signed in table.
    private(set) var signIns: [SignInEntry] = []
    /// Why the typed server address wasn't saved, or why the Keychain couldn't be read or changed.
    private(set) var signInProblem: String?
    /// Where sign-ins are kept: the Keychain, set by the app delegate; memory in snapshot runs.
    @ObservationIgnored var tokenSecrets: any SecretStore = MemorySecretStore()
    /// Where the line under the server choice asks for the server's services (SPEC-149): the server, set once by the
    /// app delegate at launch; a snapshot run's fixed answer, which never uses the network, as this default doesn't.
    @ObservationIgnored var signInServicesFetcher: any SignInServicesFetching = FixedSignInServices(ids: nil)

    private var tokenStore: OAuthTokenStore { OAuthTokenStore(secrets: tokenSecrets) }

    func loadSignIns() {
        do {
            signIns = try tokenStore.entries()
        } catch {
            signIns = []
            signInProblem = String(describing: error)
        }
    }

    /// Chooses a server: the consent sheet first (Continue saves it). Changing from one server to another, or to off,
    /// signs out of everything, after its own sheet when there are sign-ins. The sheets go on the Settings window, or
    /// where `ask` shows them (onboarding's window).
    func setSignInServer(_ server: SignInServer, ask: ((LauncherModel.AlertRequest) async -> Bool)? = nil) {
        guard server != signInServer else { return }
        signInProblem = nil
        let confirm = ask ?? confirm
        Task {
            loadSignIns()
            if !signIns.isEmpty {
                let change = SignInServer.Change.self
                guard
                    await confirm(
                        LauncherModel.AlertRequest(
                            title: change.title, message: change.message, primary: change.confirm,
                            dismiss: change.cancel, destructive: true))
                else { return }
            }
            if let host = server.host {
                let consent = SignInServer.Consent.self
                guard
                    await confirm(
                        LauncherModel.AlertRequest(
                            title: consent.title(host: host), message: nil, primary: consent.confirm,
                            dismiss: consent.cancel, destructive: false))
                else { return }
            }
            do {
                try tokenStore.removeAll()
            } catch {
                signInProblem = String(describing: error)
                return
            }
            _ = change { $0.setSignIn(server, now: Date()) }
            loadSignIns()
        }
    }

    /// "Your own server…": the typed address, saved on ↵ when it's valid.
    func setCustomSignInServer(_ text: String, ask: ((LauncherModel.AlertRequest) async -> Bool)? = nil) {
        switch SignInServer.validate(text) {
        case .success(let url): setSignInServer(.custom(url), ask: ask)
        case .failure(let problem): signInProblem = problem.message
        }
    }

    // MARK: - Extensions with their own sign-in, and Raycast's links (SPEC-132)

    /// **Extensions with their own sign-in**: on only through its consent sheet, or onboarding's Turn On.
    var ownAppSignIn: Bool { fudgeSettings.isOwnAppSignInOn }
    /// `--own-app-sign-in`: a snapshot run shows the switch on, in memory only.
    @ObservationIgnored var snapshotOwnAppSignIn = false
    /// Which app opens Raycast's links: LaunchServices, set by the app delegate; a fixed answer in snapshot runs.
    @ObservationIgnored var raycastLinks: any RaycastLinks = FixedRaycastLinks(app: nil)
    /// This app's Fudge Links, the only part of Fudge that can open Raycast's links.
    @ObservationIgnored var raycastLinksHelper = RaycastLinksHelper.url(in: Bundle.main.bundleURL)
    /// Who opens them, read when the Sign-in page or onboarding's step shows and when its window becomes key.
    private(set) var raycastLinksStatus = RaycastLinksStatus.elsewhere(nil)
    /// While Fudge opens them: the app switching it off gives them back to, nil when no other app claims them.
    private(set) var raycastLinksGiveBack: URL?
    /// Why switching it on or off didn't work, until the next try.
    private(set) var raycastLinksProblem: String?

    /// The Sign-in page's **Fudge opens Raycast links** switch, from who opens them now.
    var raycastLinksToggle: RaycastLinksToggle {
        RaycastLinksToggle(
            status: raycastLinksStatus, giveBackTo: raycastLinksGiveBack.map(SystemRaycastLinks.appName))
    }

    /// The switch: on after its consent sheet's Continue, which records the date; off removes both keys, so new
    /// direct sign-ins are refused, and the ones stored stay under Signed in. The sheet goes on the Settings window, or
    /// where `ask` shows it.
    func setOwnAppSignIn(_ on: Bool, ask: ((LauncherModel.AlertRequest) async -> Bool)? = nil) {
        guard on != ownAppSignIn else { return }
        guard on else {
            change { $0.setOwnAppSignIn(false, now: Date()) }
            return
        }
        let confirm = ask ?? confirm
        Task {
            let consent = OwnAppSignIn.Consent.self
            guard
                await confirm(
                    LauncherModel.AlertRequest(
                        title: consent.title, message: OwnAppSignIn.explanation, primary: consent.confirm,
                        dismiss: consent.cancel, destructive: false))
            else { return }
            turnOnOwnAppSignIn()
        }
    }

    /// Turns it on, the consent having been given: the switch's sheet, or onboarding's step, which shows the same
    /// words.
    func turnOnOwnAppSignIn() {
        change { $0.setOwnAppSignIn(true, now: Date()) }
    }

    func refreshRaycastLinks() {
        show(raycastLinksStatus: raycastLinks.status(helper: raycastLinksHelper))
    }

    private func show(raycastLinksStatus status: RaycastLinksStatus) {
        raycastLinksStatus = status
        raycastLinksGiveBack = status.isFudge ? raycastLinks.handBackTarget(helper: raycastLinksHelper) : nil
    }

    /// The Sign-in page's switch: on is Open Raycast Links with Fudge, off gives them back to the other app that claims
    /// them. Only the user's click gets here.
    func setRaycastLinks(_ on: Bool) {
        guard on != raycastLinksStatus.isFudge else { return }
        if on { openRaycastLinksWithFudge() } else { giveRaycastLinksBack() }
    }

    /// **Open Raycast Links with Fudge** (onboarding), or switching it on: registers Fudge Links and makes it open
    /// `raycast` and `com.raycast` links, then reads who opens them again. Refused from the disk image or a translocated
    /// copy. Only the user's click does this, never a launch.
    func openRaycastLinksWithFudge() {
        raycastLinksProblem = nil
        Task {
            let (status, problem) = await raycastLinks.openWithFudge(helper: raycastLinksHelper, location: appLocation)
            show(raycastLinksStatus: status)
            raycastLinksProblem = problem
        }
    }

    /// Switching it off: gives both schemes back to the other app that claims them, then reads who opens them again.
    private func giveRaycastLinksBack() {
        guard let app = raycastLinksGiveBack else { return }
        raycastLinksProblem = nil
        Task {
            let (status, problem) = await raycastLinks.giveBack(to: app, helper: raycastLinksHelper)
            show(raycastLinksStatus: status)
            raycastLinksProblem = problem
        }
    }

    func signOut(_ entry: SignInEntry) {
        do {
            try tokenStore.remove(extension: entry.extensionName, provider: entry.providerID)
            signInProblem = nil
        } catch {
            signInProblem = String(describing: error)
        }
        loadSignIns()
    }

    // MARK: - Show fudge on, and Escape key behavior

    var showOnScreen: ShowOnScreen { fudgeSettings.showOnScreen }
    var escapeBehavior: EscapeBehavior { fudgeSettings.escapeBehavior }

    func setShowOnScreen(_ setting: ShowOnScreen) {
        guard setting != showOnScreen, change({ $0.showOnScreen = setting }) else { return }
        _ = applyHotkeys()  // which applies settings.json to the launcher too
    }

    func setEscapeBehavior(_ behavior: EscapeBehavior) {
        guard behavior != escapeBehavior, change({ $0.escapeBehavior = behavior }) else { return }
        _ = applyHotkeys()
    }

    // MARK: - Logs (SPEC-124)

    /// How much goes into the log files (`logLevel`).
    var logLevel: LogLevel { fudgeSettings.logLevel }

    /// Takes effect at once, for running commands too: `applyHotkeys` applies `settings.json` to the launcher, which
    /// tells `FudgeLog` and the extension host.
    func setLogLevel(_ level: LogLevel) {
        guard level != logLevel, change({ $0.logLevel = level }) else { return }
        _ = applyHotkeys()
    }

    /// Opens the logs folder in Finder, creating it first when nothing has been logged yet.
    func showLogs() {
        let folder = FudgePaths.logsDirectory()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            FudgeLog.error("couldn't create \(folder.path): \(error)")
        }
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Pop to Root Search

    /// How long the panel stays hidden before it opens on root search again (`resetAfterSeconds`).
    var resetAfter: PanelResetSetting { fudgeSettings.resetAfter }
    /// Tells the launcher; set by the app delegate.
    @ObservationIgnored var resetAfterChanged: (PanelResetSetting) -> Void = { _ in }

    func setResetAfter(_ setting: PanelResetSetting) {
        guard change({ $0.resetAfter = setting }) else { return }
        resetAfterChanged(setting)
    }

    // MARK: - Command hotkeys

    func hotkey(for commandID: String) -> HotKeySpec? {
        fudgeSettings.commands[commandID]?.hotkey.flatMap(HotKeySpec.parse)
    }

    func startRecording(_ commandID: String) {
        if recorder.start(commandID) { suspendHotkeys() }
        hotkeyMessages[commandID] = nil
        hotkeyNotes[commandID] = nil
    }

    /// Ends a recording without changing anything (Esc, the window closing, or leaving the page).
    func cancelRecording() {
        if recorder.end() { resumeHotkeys() }
    }

    /// The keys pressed while recording `commandID`. A conflict, or a shortcut the system refuses, keeps the old
    /// hotkey and says why.
    func record(_ spec: HotKeySpec, for commandID: String) {
        cancelRecording()
        let installed = installedCommandIDs
        if let conflict = HotKeyConflict.check(
            spec, for: commandID, launcher: launcherHotkey, commands: fudgeSettings.commandHotkeys,
            installed: installed)
        {
            hotkeyMessages[commandID] = message(for: conflict)
            return
        }
        // A command that isn't installed gives its saved hotkey up; its alias and Enabled state stay.
        let displaced = HotKeyConflict.displaced(
            by: spec, except: commandID, commands: fudgeSettings.commandHotkeys, installed: installed)
        let old = ([commandID] + displaced).map { ($0, fudgeSettings.commands[$0]?.hotkey) }
        let saved = change { settings in
            settings.commands[commandID, default: .init()].hotkey = spec.text
            for id in displaced { settings.commands[id]?.hotkey = nil }
        }
        guard saved else { return }
        if applyHotkeys().contains(commandID) {
            change { settings in
                for (id, hotkey) in old { settings.commands[id, default: .init()].hotkey = hotkey }
            }
            _ = applyHotkeys()
            hotkeyMessages[commandID] = "This shortcut is in use by another app"
            return
        }
        hotkeyNotes[commandID] = note(displaced)
    }

    /// What the hotkeys a new one took over were (`HotKeyConflict.displacedNote`), by title; nil for none.
    private func note(_ displaced: [String]) -> String? {
        HotKeyConflict.displacedNote(displaced, title: title(ofCommand:))
    }

    func clearHotkey(_ commandID: String) {
        cancelRecording()
        hotkeyMessages[commandID] = nil
        hotkeyNotes[commandID] = nil
        setHotkey(nil, for: commandID)
        _ = applyHotkeys()
    }

    @discardableResult
    private func setHotkey(_ text: String?, for commandID: String) -> Bool {
        change { $0.commands[commandID, default: .init()].hotkey = text }
    }

    /// Changes `settings.json`, read again first so hand edits made meanwhile aren't overwritten. Returns false,
    /// leaving the file and `fudgeSettings` as they were, when the file can't be written.
    @discardableResult
    private func change(_ edit: (inout FudgeSettings) -> Void) -> Bool {
        fudgeSettings = readSettings()
        var edited = fudgeSettings
        edit(&edited)
        do {
            try edited.save(to: paths.settingsFile)
            fudgeSettings = edited
            settingsProblem = nil
            return true
        } catch is FudgeSettings.Unreadable {
            settingsProblem = unreadableMessage
        } catch {
            settingsProblem = "Couldn't save settings: \(error.localizedDescription)"
        }
        return false
    }

    private var unreadableMessage: String {
        let path = (paths.settingsFile.path as NSString).abbreviatingWithTildeInPath
        return "\(path) isn't valid JSON, so Fudge won't change it. Fix or remove it, then try again."
    }

    // MARK: - Aliases and enabled

    /// The command's alias, its default included (`FudgeSettings.alias(ofCommand:)`).
    func alias(for commandID: String) -> String? {
        fudgeSettings.alias(ofCommand: commandID)
    }

    /// Saves `text` as the command's alias; empty removes it. Returns false, with a message, when it's refused.
    @discardableResult
    func setAlias(_ text: String, for commandID: String) -> Bool {
        let alias = text.trimmingCharacters(in: .whitespaces)
        // Check against the file as it is now, as `change` edits it, so an alias added by hand meanwhile counts.
        fudgeSettings = readSettings()
        // ↵ on the alias shown, a default included, changes nothing, so a default never becomes the user's choice.
        if alias == fudgeSettings.alias(ofCommand: commandID) ?? "" {
            aliasMessages[commandID] = nil
            return true
        }
        // A quicklink removed from its file by hand can still hold the alias: its settings go first, so it's free.
        if !alias.isEmpty,
            case .duplicate(let other) = CommandAliases.problem(with: alias, for: commandID, in: fudgeSettings),
            QuicklinkCommands.nameWhenGone(other) != nil
        {
            let store = QuicklinkStore.load(from: paths.quicklinksFile)
            if QuicklinkStore.isWritable(paths.quicklinksFile), QuicklinkCommands.prune(&fudgeSettings, in: store) {
                change { QuicklinkCommands.prune(&$0, in: store) }
            }
        }
        if !alias.isEmpty, let problem = CommandAliases.problem(with: alias, for: commandID, in: fudgeSettings) {
            aliasMessages[commandID] =
                switch problem {
                case .length: "Use 1 to 32 characters"
                case .spaces: "No spaces"
                case .duplicate(let other): "Already used by \(title(ofCommand: other))"
                }
            return false
        }
        aliasMessages[commandID] = nil
        guard change({ $0.setAlias(alias, ofCommand: commandID) }) else {
            return false
        }
        _ = applyHotkeys()
        return true
    }

    /// A command's own Enabled: the user's choice, else its default (off for one that uses Raycast AI or the
    /// Browser Extension, SPEC-109).
    func isEnabled(command commandID: String) -> Bool {
        fudgeSettings.isEnabledOwn(commandID: commandID)
    }

    /// Why a command is off by default, for its row on the Commands page; nil for one that isn't.
    func offByDefaultReason(command commandID: String) -> String? {
        guard let slash = commandID.firstIndex(of: "/") else { return nil }
        let name = String(commandID[..<slash])
        return allExtensions.first { $0.manifest.name == name }?.compatibility
            .reason(for: String(commandID[commandID.index(after: slash)...]))
    }

    /// `settings.json`, with the commands that are off by default worked out from the installed extensions.
    private func readSettings() -> FudgeSettings {
        var settings = FudgeSettings.load(from: paths.settingsFile)
        settings.offByDefault = InstalledExtension.offByDefault(allExtensions)
        if snapshotOwnAppSignIn { settings.setOwnAppSignIn(true, now: Date()) }
        return settings
    }

    /// The Extension Store is off unless enabled (`FudgeSettings.isEnabled(extension:)`).
    func isEnabled(extension name: String) -> Bool {
        fudgeSettings.isEnabled(extension: name)
    }

    /// Enables or disables a command: a disabled one leaves root search, and its hotkey stops working.
    func setEnabled(_ enabled: Bool, command commandID: String) {
        change { $0.setEnabled(enabled, commandID: commandID) }
        _ = applyHotkeys()
    }

    /// Enables or disables every command of an extension.
    func setEnabled(_ enabled: Bool, extension name: String) {
        change { $0.setEnabled(enabled, extension: name) }
        _ = applyHotkeys()
    }

    private func message(for conflict: HotKeyConflict) -> String {
        switch conflict {
        case .needsModifier: "Use ⌘, ⌥ or ⌃, or an F-key"
        case .launcher: "That's Fudge's own shortcut"
        case .command(let other):
            "Used by \(CommandNames.name(of: other, in: allExtensions, groups: commandGroups) ?? QuicklinkCommands.nameWhenGone(other) ?? other)"
        }
    }

    /// A command's title, from its id: an installed command's, one of Fudge's own or a quicklink's.
    func title(ofCommand commandID: String) -> String {
        for group in commandGroups {
            for command in group.commands where group.commandID(command) == commandID { return command.title }
        }
        for installed in allExtensions {
            for command in installed.manifest.commands
            where FudgeSettings.commandID(extension: installed.manifest.name, command: command.name) == commandID {
                return command.title
            }
        }
        return QuicklinkCommands.nameWhenGone(commandID) ?? commandID
    }

    /// The value shown for a preference: what's stored, else its default.
    func value(_ preference: ExtensionManifest.Preference, of extensionName: String, command: String?) -> JSONValue? {
        let values = stored[extensionName] ?? StoredPreferences()
        let storedValue =
            command.map { values.commandValues[$0]?[preference.name] } ?? values.extensionValues[preference.name]
        return storedValue ?? preference.default ?? PreferenceResolver.typeDefault(preference)
    }

    func set(
        _ value: JSONValue?, for preference: ExtensionManifest.Preference, of extensionName: String, command: String?
    ) {
        var values = stored[extensionName] ?? StoredPreferences()
        if let command {
            values.commandValues[command, default: [:]][preference.name] = value
        } else {
            values.extensionValues[preference.name] = value
        }
        stored[extensionName] = values
        do {
            try store.save(values, for: extensionName)
        } catch {
            FudgeLog.error("couldn't save preferences: \(error)")
        }
    }

    /// Required preferences of `extensionName` that still have no value, for highlighting.
    func isMissing(_ preference: ExtensionManifest.Preference, of extensionName: String, command: String?) -> Bool {
        guard preference.required == true else { return false }
        switch value(preference, of: extensionName, command: command) {
        case nil, .null, .string(""): return true
        default: return false
        }
    }
}

/// A snapshot run's alert, laid out but never ordered in, which never takes the keyboard.
final class SnapshotSheet: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A snapshot run's alert, which no one may see: it's laid out without being shown (`layout()` never orders its
    /// window in), and its content moves to a panel that can't become key and is never ordered in either, transparent
    /// for good measure. It isn't begun as a sheet: the window a snapshot renders is transparent, but ordering it front
    /// puts it back on screen, and a sheet on it is a window of its own, which would show there. Nobody answers it:
    /// the run saves it and quits.
    static func laidOut(_ alert: NSAlert) -> NSWindow {
        alert.layout()
        let laidOut = alert.window
        let sheet = SnapshotSheet(
            contentRect: laidOut.frame, styleMask: laidOut.styleMask, backing: .buffered, defer: false)
        sheet.alphaValue = 0
        sheet.ignoresMouseEvents = true
        sheet.contentView = laidOut.contentView
        return sheet
    }
}

/// The Settings window: extensions on the left, the selected one's preferences on the right.
/// The Settings window, which can refuse the keyboard: snapshots render it without taking anyone's typing.
final class SettingsNSWindow: NSWindow {
    var refusesKey = false
    /// Whether a hotkey is being recorded, when ⌘Q and ⌘W belong to the recorder.
    var isRecording: () -> Bool = { false }

    override var canBecomeKey: Bool { !refusesKey && super.canBecomeKey }
    override var canBecomeMain: Bool { !refusesKey && super.canBecomeMain }

    /// A snapshot run's window stays where it's put, off every screen: AppKit would otherwise move a titled window
    /// back onto one when it's ordered front. It's transparent too, but nothing of a snapshot run belongs on a screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        refusesKey ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// ⌘Q closes the window as ⌘W and its close button do, and fudge keeps running (`WindowShortcut`). The key is
    /// the one that types "q" in the current layout, as for the panel's shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let pressed = AppDelegate.shortcut(for: event),
            WindowShortcut.closesWindow(pressed, recording: isRecording())
        {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    /// Opens the window, optionally on one extension's preferences, in front and key: from closed, from behind
    /// other apps' windows, minimized, or on another Space (it comes to the current one). Every way into Settings
    /// comes here. **Only for entries the user starts** (⌘,, Settings…, Configure Extension, a command's
    /// `openExtensionPreferences`, an unset required preference): it takes focus from the app in front, so no
    /// background path may reach it; `CommandLocator.checkMode` keeps background launches from opening Settings.
    func show(extension name: String? = nil, origin: CallOrigin) {
        guard origin.mayComeForward else { return }
        prepare(extension: name)
        guard let window else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activateFromUserAction(origin: origin)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    /// Reads the installed extensions and settings again while the window is on screen; closed, it reads them
    /// when it next opens.
    func reloadIfShown() {
        guard window?.isVisible == true else { return }
        model.reload()
    }

    /// Lays the window out off-screen and transparent, never key; only snapshots use this.
    func renderOffscreen(extension name: String?) {
        prepare(extension: name)
        guard let window else { return }
        (window as? SettingsNSWindow)?.refusesKey = true
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
    }

    private func prepare(extension name: String?) {
        model.reload()
        model.refreshLoginItem()
        // "Fudge Settings" and Settings… open on the General page; Configure Extension on the extension's own.
        model.select(name ?? SettingsModel.generalPage)
        if let window, window.contentView == nil {
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
        }
        if window == nil {
            let window = SettingsNSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Fudge Settings"
            window.isReleasedWhenClosed = false
            window.isRecording = { [model] in model.recording != nil }
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
            model.confirm = { [weak self, weak window] request in
                guard let window else { return false }
                let alert = Self.alert(for: request)
                if window.refusesKey {
                    self?.snapshotSheet = SnapshotSheet.laidOut(alert)
                    return false
                }
                return await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                }
            }
            // Closing the window mid-recording gives fudge its hotkeys back. Its views go too, so nothing in them keeps
            // running while it's closed (the Permissions page polls Accessibility); showing it builds them again.
            let model = model
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    model.cancelRecording()
                    window?.dropContentWhenClosed()
                }
            }
            // Coming back from System Settings → Login Items shows what was changed there, and from the launcher a
            // quicklink or snippet saved there.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    model.refreshLoginItem()
                    model.refreshRaycastLinks()
                    model.loadQuicklinks()
                    model.loadSnippets()
                    model.loadWindowLayouts()
                }
            }
        }
    }

    var contentView: NSView? { window?.contentView }
    /// In a snapshot run, the alert a `confirm` would have shown, for the run to save.
    private(set) var snapshotSheet: NSWindow?

    /// The alert for a `confirm` request, on the Settings window or onboarding's: its title, message, footnote and
    /// buttons, the primary one first.
    static func alert(for request: LauncherModel.AlertRequest) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message ?? ""
        if let footnote = request.footnote { alert.accessoryView = footnoteView(footnote) }
        alert.addButton(withTitle: request.primary).hasDestructiveAction = request.destructive
        alert.addButton(withTitle: request.dismiss)
        return alert
    }

    /// A sheet's last paragraph, as selectable text with a working link: an alert's own text can't hold one.
    /// Clicking the link opens the browser and leaves the sheet open.
    private static func footnoteView(_ footnote: LauncherModel.AlertRequest.Footnote) -> NSView {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = NSMutableAttributedString(
            string: footnote.text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let range = (footnote.text as NSString).range(of: footnote.linkText)
        if range.location != NSNotFound { text.addAttribute(.link, value: footnote.url, range: range) }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(text)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let height = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0
        view.frame.size.height = ceil(height)
        return view
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        // A fixed 200 pt sidebar beside the page, not a NavigationSplitView: the split view's divider could be dragged
        // until the sidebar collapsed, and with no toggle (it jumped across the title bar) nothing brought it back.
        // There's no split view, so no divider and no collapsed state to restore.
        HStack(spacing: 0) {
            List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
                Label("General", systemImage: "gearshape").tag(SettingsModel.generalPage)
                Label("Permissions", systemImage: "hand.raised").tag(SettingsModel.permissionsPage)
                Label("Commands", systemImage: "command").tag(SettingsModel.commandsPage)
                Label("Quicklinks", systemImage: "link").tag(SettingsModel.quicklinksPage)
                Label("Snippets", systemImage: "doc.text").tag(SettingsModel.snippetsPage)
                Label("Window Management", systemImage: "macwindow").tag(SettingsModel.windowManagementPage)
                Label("Sign-in", systemImage: "person.badge.key").tag(SettingsModel.signInPage)
                Label("Color Picker", systemImage: "eyedropper").tag(SettingsModel.colorPickerPage)
                Label("Calendar", systemImage: "calendar").tag(SettingsModel.calendarPage)
                Section("Extensions") {
                    ForEach(model.extensions, id: \.manifest.name) { installed in
                        Text(installed.manifest.title).tag(installed.manifest.name)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(SidebarMaterial())
            .frame(width: 200)
            Divider()
            Group {
                if model.selected == SettingsModel.generalPage {
                    GeneralPage(model: model)
                } else if model.selected == SettingsModel.permissionsPage {
                    PermissionsPage(model: model)
                } else if model.selected == SettingsModel.commandsPage {
                    CommandsPage(model: model)
                } else if model.selected == SettingsModel.quicklinksPage {
                    QuicklinksPage(model: model)
                } else if model.selected == SettingsModel.snippetsPage {
                    SnippetsPage(model: model)
                } else if model.selected == SettingsModel.windowManagementPage {
                    WindowManagementPage(model: model)
                } else if model.selected == SettingsModel.signInPage {
                    SignInPage(model: model)
                } else if model.selected == SettingsModel.colorPickerPage {
                    ColorPickerPage(model: model)
                } else if model.selected == SettingsModel.calendarPage {
                    CalendarPage(model: model)
                } else if let installed = model.extensions.first(where: { $0.manifest.name == model.selected }) {
                    ExtensionPreferencesForm(model: model, installed: installed)
                } else {
                    Text("No extension has preferences.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The width it opens at: any narrower and the Commands table squeezes its Name column, truncating names and
        // running a command's subtitle into the Type column.
        .frame(minWidth: 880, minHeight: 400)
    }
}

/// The sidebar's translucent material, as a split view's sidebar has it.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct ExtensionPreferencesForm: View {
    let model: SettingsModel
    let installed: InstalledExtension

    var body: some View {
        let manifest = installed.manifest
        Form {
            if manifest.name == ExtensionStore.extensionName {
                ExtensionStoreSwitch(model: model)
            }
            if manifest.name == ClipboardHistory.extensionName {
                ClipboardHistorySettings(model: model)
            }
            if !manifest.preferences.isEmpty {
                Section(manifest.title) {
                    ForEach(manifest.preferences, id: \.name) { preference in
                        PreferenceField(
                            model: model, preference: preference, extensionName: manifest.name, command: nil)
                    }
                }
            }
            ForEach(manifest.commands.filter { !$0.preferences.isEmpty }, id: \.name) { command in
                Section(command.title) {
                    ForEach(command.preferences, id: \.name) { preference in
                        PreferenceField(
                            model: model,
                            preference: preference,
                            extensionName: manifest.name,
                            command: command.name
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The first row of the Extension Store's page: its switch, which asks with the consent sheet before turning on.
private struct ExtensionStoreSwitch: View {
    let model: SettingsModel

    var body: some View {
        if let problem = model.settingsProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
        Section {
            Toggle(isOn: Binding(get: { model.extensionStore }, set: { model.setExtensionStore($0) })) {
                Text(ExtensionStore.Switch.title)
                Text(ExtensionStore.Switch.help)
            }
            .toggleStyle(.switch)
        }
    }
}

/// Clipboard History's page (SPEC-077 §1): its switch first, then Keep For, Ignore Apps and Clear History….
private struct ClipboardHistorySettings: View {
    let model: SettingsModel

    var body: some View {
        if let problem = model.settingsProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
        Section {
            Toggle(isOn: Binding(get: { model.clipboardHistory }, set: { model.setClipboardHistory($0) })) {
                Text(ClipboardHistorySheets.switchTitle)
                Text(ClipboardHistorySheets.switchHelp)
            }
            .toggleStyle(.switch)
            Picker(
                ClipboardHistorySheets.keepFor,
                selection: Binding(
                    get: { model.clipboardHistoryKeepDays }, set: { model.setClipboardHistoryKeepDays($0) })
            ) {
                ForEach(ClipboardHistory.keepForChoices, id: \.self) { days in
                    Text(ClipboardHistorySheets.keepForTitle(days)).tag(days)
                }
            }
        }
        Section {
            ForEach(model.clipboardHistoryIgnoredApps, id: \.self) { bundleId in
                LabeledContent(Self.name(of: bundleId)) {
                    Button {
                        model.stopIgnoringClipboard(of: bundleId)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Keep copies made in this app")
                }
            }
            Menu("Add App…") {
                ForEach(model.applications) { application in
                    if case .application(let url) = application.kind {
                        Button(application.title) { model.ignoreClipboard(fromApplicationAt: url.path) }
                    }
                }
            }
            .fixedSize()
        } header: {
            Text(ClipboardHistorySheets.ignoreApps)
        } footer: {
            Text(ClipboardHistorySheets.ignoreAppsHelp).foregroundStyle(.secondary)
        }
        Section {
            Button("Clear History…") { model.clearClipboardHistory() }
        }
    }

    /// An app's name for a bundle id, or the id when it isn't installed.
    private static func name(of bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// One preference, with the control its type calls for.
private struct PreferenceField: View {
    let model: SettingsModel
    let preference: ExtensionManifest.Preference
    let extensionName: String
    let command: String?

    var body: some View {
        control
            .help(preference.description ?? "")
            .overlay(alignment: .trailing) {
                if model.isMissing(preference, of: extensionName, command: command) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).offset(x: 22)
                }
            }
    }

    private var title: String { preference.title ?? preference.label ?? preference.name }

    private var current: JSONValue? { model.value(preference, of: extensionName, command: command) }

    private func set(_ value: JSONValue?) {
        model.set(value, for: preference, of: extensionName, command: command)
    }

    private var text: Binding<String> {
        Binding(
            get: { if case .string(let value) = current { value } else { "" } },
            set: { set(.string($0)) }
        )
    }

    @ViewBuilder private var control: some View {
        switch preference.type {
        case "checkbox":
            // A switch on the right, as everywhere in Settings: the title, with the manifest's `label` under it.
            Toggle(
                isOn: Binding(
                    get: { if case .bool(let value) = current { value } else { false } },
                    set: { set(.bool($0)) }
                )
            ) {
                Text(title)
                if preference.title != nil, let label = preference.label { Text(label) }
            }
            .toggleStyle(.switch)
        case "dropdown":
            Picker(title, selection: text) {
                ForEach(preference.data ?? [], id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
        case "password":
            SecureField(title, text: text, prompt: preference.placeholder.map { Text($0) })
        case "appPicker":
            Picker(title, selection: text) {
                Text("None").tag("")
                if case .string(let value) = current, !value.isEmpty,
                    !model.applications.contains(where: { applicationPath($0) == value })
                {
                    Text((value as NSString).lastPathComponent).tag(value)
                }
                ForEach(model.applications) { application in
                    Text(application.title).tag(applicationPath(application))
                }
            }
        case "directory", "file":
            LabeledContent(title) {
                HStack {
                    Text(text.wrappedValue.isEmpty ? "Not set" : text.wrappedValue)
                        .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { choosePath() }
                    if !text.wrappedValue.isEmpty {
                        Button("Clear") { set(nil) }
                    }
                }
            }
        default:
            TextField(title, text: text, prompt: preference.placeholder.map { Text($0) })
        }
    }

    private func applicationPath(_ item: RootItem) -> String {
        if case .application(let url) = item.kind { return url.path }
        return ""
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = preference.type == "directory"
        panel.canChooseFiles = preference.type == "file"
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { set(.string(url.path)) }
    }
}
