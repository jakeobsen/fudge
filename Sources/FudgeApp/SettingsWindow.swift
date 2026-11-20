import AppKit
import FudgeCore
import Observation
import SwiftUI

/// What the Settings window shows: installed extensions and their preference values.
@MainActor
@Observable
final class SettingsModel {
    private(set) var extensions: [InstalledExtension] = []
    var selected: String?
    /// The General and Commands pages' entries in the sidebar; extension names can't start with ":".
    static let generalPage = ":general"
    static let commandsPage = ":commands"
    /// Every installed extension, for the Commands page.
    private(set) var allExtensions: [InstalledExtension] = []
    /// `settings.json`, as the Commands page edits it.
    private(set) var fudgeSettings = FudgeSettings()
    /// The command whose hotkey is being recorded.
    private(set) var recording: String?
    /// A short message under a command's hotkey: why a recording was refused.
    private(set) var hotkeyMessages: [String: String] = [:]
    /// A short message under a command's alias: why it was refused.
    private(set) var aliasMessages: [String: String] = [:]
    /// Set while `settings.json` isn't a JSON object, so changes can't be saved; the General and Commands pages say so.
    private(set) var settingsProblem: String?
    /// The launcher's own hotkey, which commands can't take; kept current by the app delegate.
    var launcherHotkey = HotKeySpec.default
    /// The system refused the launcher's hotkey: another app has it, so it doesn't work.
    var launcherHotkeyInUse = false
    /// Registers a new launcher hotkey; false when the system refuses it, and the old one then stays registered.
    /// Set by the app delegate.
    @ObservationIgnored var registerLauncherHotkey: (HotKeySpec) -> Bool = { _ in true }
    /// Suspend and resume fudge's global hotkeys around a recording, so pressing one records it.
    @ObservationIgnored var suspendHotkeys: () -> Void = {}
    @ObservationIgnored var resumeHotkeys: () -> Void = {}
    /// Registers the command hotkeys from `settings.json`; returns the command ids the system refused.
    @ObservationIgnored var applyHotkeys: () -> Set<String> = { [] }
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
        extensions = InstalledExtension.all(in: paths.extensionsDirectory).filter { installed in
            !installed.manifest.preferences.isEmpty || installed.manifest.commands.contains { !$0.preferences.isEmpty }
        }
        stored = Dictionary(uniqueKeysWithValues: extensions.map { ($0.manifest.name, store.load($0.manifest.name)) })
        allExtensions = InstalledExtension.all(in: paths.extensionsDirectory).sorted {
            $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending
        }
        fudgeSettings = FudgeSettings.load(from: paths.settingsFile)
        settingsProblem = FudgeSettings.isWritable(paths.settingsFile) ? nil : unreadableMessage
        loadLaunchPermissions()
        if selected != Self.generalPage, selected != Self.commandsPage,
            !extensions.contains(where: { $0.manifest.name == selected })
        {
            selected = Self.generalPage
        }
    }

    // MARK: - General

    /// Whether the calculator downloads exchange rates (`currencyRates` in `settings.json`).
    var currencyRates: Bool { fudgeSettings.currencyRates }
    /// Tells the exchange rate updater; set by the app delegate.
    @ObservationIgnored var currencyRatesChanged: (Bool) -> Void = { _ in }

    func setCurrencyRates(_ on: Bool) {
        // Read the file again first, so hand edits made meanwhile aren't overwritten.
        fudgeSettings = FudgeSettings.load(from: paths.settingsFile)
        guard fudgeSettings.currencyRates != on else { return }
        fudgeSettings.currencyRates = on
        do {
            try fudgeSettings.save(to: paths.settingsFile)
        } catch {
            FileHandle.standardError.write(Data("fudge: couldn't save settings: \(error)\n".utf8))
        }
        currencyRatesChanged(on)
    }

    // MARK: - Open at Login and search history

    /// fudge as a login item; the app delegate sets the real one, and snapshots a fake.
    @ObservationIgnored var loginItem: any LoginItem = FixedLoginItem(.notRegistered)
    /// The Open at Login switch, from the system's real status (`refreshLoginItem()`), never a stored value.
    private(set) var loginItemState = LoginItemState(.notRegistered)
    /// Why turning Open at Login on or off failed, until the next try.
    private(set) var loginItemError: String?
    /// Clears root search's launch history; set by the app delegate.
    @ObservationIgnored var clearSearchHistory: () -> Void = {}

    /// Reads the login item's status again: a change made in System Settings shows too.
    func refreshLoginItem() {
        loginItemState = LoginItemState(loginItem.status)
    }

    func setOpenAtLogin(_ on: Bool) {
        (loginItemState, loginItemError) = LoginItemState.change(loginItem, to: on)
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
            FileHandle.standardError.write(Data("fudge: couldn't save launch permissions: \(error)\n".utf8))
        }
        loadLaunchPermissions()
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
        fudgeSettings = FudgeSettings.load(from: paths.settingsFile)
        switch key.launcherEdit(commands: fudgeSettings.commandHotkeys) {
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
        // A settings.json that isn't a JSON object is refused before anything is registered (the banner says why).
        guard FudgeSettings.isWritable(paths.settingsFile) else {
            settingsProblem = unreadableMessage
            return
        }
        let old = launcherHotkey
        guard registerLauncherHotkey(spec) else {
            hotkeyMessages[Self.launcherRecording] = "This shortcut is in use by another app"
            return
        }
        // What's registered must match the file, or the next launch would bring the old one back unannounced.
        if !change({ $0.launcherHotkey = spec }) { _ = registerLauncherHotkey(old) }
    }

    // MARK: - Command hotkeys

    func hotkey(for commandID: String) -> HotKeySpec? {
        fudgeSettings.commands[commandID]?.hotkey.flatMap(HotKeySpec.parse)
    }

    func startRecording(_ commandID: String) {
        if recording == nil { suspendHotkeys() }
        recording = commandID
        hotkeyMessages[commandID] = nil
    }

    /// Ends a recording without changing anything (Esc, or the window closing).
    func cancelRecording() {
        guard recording != nil else { return }
        recording = nil
        resumeHotkeys()
    }

    /// The keys pressed while recording `commandID`. A conflict, or a shortcut the system refuses, keeps the old
    /// hotkey and says why.
    func record(_ spec: HotKeySpec, for commandID: String) {
        cancelRecording()
        if let conflict = HotKeyConflict.check(
            spec, for: commandID, launcher: launcherHotkey, commands: fudgeSettings.commandHotkeys)
        {
            hotkeyMessages[commandID] = message(for: conflict)
            return
        }
        let old = fudgeSettings.commands[commandID]?.hotkey
        guard setHotkey(spec.text, for: commandID) else { return }
        if applyHotkeys().contains(commandID) {
            setHotkey(old, for: commandID)
            _ = applyHotkeys()
            hotkeyMessages[commandID] = "This shortcut is in use by another app"
        }
    }

    func clearHotkey(_ commandID: String) {
        cancelRecording()
        hotkeyMessages[commandID] = nil
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
        fudgeSettings = FudgeSettings.load(from: paths.settingsFile)
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
        return "\(path) isn't valid JSON, so fudge won't change it. Fix or remove it, then try again."
    }

    // MARK: - Aliases and enabled

    func alias(for commandID: String) -> String? {
        fudgeSettings.commands[commandID]?.alias
    }

    /// Saves `text` as the command's alias; empty removes it. Returns false, with a message, when it's refused.
    @discardableResult
    func setAlias(_ text: String, for commandID: String) -> Bool {
        let alias = text.trimmingCharacters(in: .whitespaces)
        // Check against the file as it is now, as `change` edits it, so an alias added by hand meanwhile counts.
        fudgeSettings = FudgeSettings.load(from: paths.settingsFile)
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
        guard change({ $0.commands[commandID, default: .init()].alias = alias.isEmpty ? nil : alias }) else {
            return false
        }
        _ = applyHotkeys()
        return true
    }

    func isEnabled(command commandID: String) -> Bool {
        fudgeSettings.commands[commandID]?.enabled != false
    }

    func isEnabled(extension name: String) -> Bool {
        fudgeSettings.extensions[name]?.enabled != false
    }

    /// Enables or disables a command: a disabled one leaves root search, and its hotkey stops working.
    func setEnabled(_ enabled: Bool, command commandID: String) {
        change { $0.commands[commandID, default: .init()].enabled = enabled ? nil : false }
        _ = applyHotkeys()
    }

    /// Enables or disables every command of an extension.
    func setEnabled(_ enabled: Bool, extension name: String) {
        change { $0.extensions[name, default: .init()].enabled = enabled ? nil : false }
        _ = applyHotkeys()
    }

    private func message(for conflict: HotKeyConflict) -> String {
        switch conflict {
        case .needsModifier: "Use ⌘, ⌥ or ⌃, or an F-key"
        case .launcher: "That's fudge's own shortcut"
        case .command(let other): "Already used by \(title(ofCommand: other))"
        }
    }

    /// A command's title, from its id.
    func title(ofCommand commandID: String) -> String {
        for installed in allExtensions {
            for command in installed.manifest.commands
            where FudgeSettings.commandID(extension: installed.manifest.name, command: command.name) == commandID {
                return command.title
            }
        }
        return commandID
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
            FileHandle.standardError.write(Data("fudge: couldn't save preferences: \(error)\n".utf8))
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

/// The Settings window: extensions on the left, the selected one's preferences on the right.
/// The Settings window, which can refuse the keyboard: snapshots render it without taking anyone's typing.
final class SettingsNSWindow: NSWindow {
    var refusesKey = false

    override var canBecomeKey: Bool { !refusesKey && super.canBecomeKey }
    override var canBecomeMain: Bool { !refusesKey && super.canBecomeMain }
}

@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    /// Opens the window, optionally on one extension's preferences.
    func show(extension name: String? = nil) {
        prepare(extension: name)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
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
        // "fudge Settings" and Settings… open on the General page; Configure Extension on the extension's own.
        model.selected = name ?? SettingsModel.generalPage
        if window == nil {
            let window = SettingsNSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "fudge Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
            // Closing the window mid-recording gives fudge its hotkeys back.
            let model = model
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { model.cancelRecording() }
            }
            // Coming back from System Settings → Login Items shows what was changed there.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { model.refreshLoginItem() }
            }
        }
    }

    var contentView: NSView? { window?.contentView }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        // The sidebar always shows and has no toggle, as in System Settings: it's the way to the other pages, and
        // SwiftUI's toggle jumps across the title bar each time it collapses or expands the sidebar.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $model.selected) {
                Label("General", systemImage: "gearshape").tag(SettingsModel.generalPage)
                Label("Commands", systemImage: "command").tag(SettingsModel.commandsPage)
                Section("Extensions") {
                    ForEach(model.extensions, id: \.manifest.name) { installed in
                        Text(installed.manifest.title).tag(installed.manifest.name)
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            // Keep this last: above `.toolbar(removing:)`, it's ignored and the sidebar comes out about 140 pt wide.
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if model.selected == SettingsModel.generalPage {
                GeneralPage(model: model)
            } else if model.selected == SettingsModel.commandsPage {
                CommandsPage(model: model)
            } else if let installed = model.extensions.first(where: { $0.manifest.name == model.selected }) {
                ExtensionPreferencesForm(model: model, installed: installed)
            } else {
                Text("No extension has preferences.").foregroundStyle(.secondary)
            }
        }
        // The width it opens at: any narrower and the Commands table squeezes its Name column, truncating names and
        // running a command's subtitle into the Type column.
        .frame(minWidth: 880, minHeight: 400)
    }
}

private struct ExtensionPreferencesForm: View {
    let model: SettingsModel
    let installed: InstalledExtension

    var body: some View {
        let manifest = installed.manifest
        Form {
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
            LabeledContent(preference.title ?? "") {
                Toggle(
                    preference.label ?? preference.name,
                    isOn: Binding(
                        get: { if case .bool(let value) = current { value } else { false } },
                        set: { set(.bool($0)) }
                    )
                )
            }
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
