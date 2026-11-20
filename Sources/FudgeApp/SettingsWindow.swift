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
        if selected == nil || !extensions.contains(where: { $0.manifest.name == selected }) {
            selected = extensions.first?.manifest.name
        }
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
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
    }

    private func prepare(extension name: String?) {
        model.reload()
        if let name { model.selected = name }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "fudge Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
    }

    var contentView: NSView? { window?.contentView }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(model.extensions, id: \.manifest.name, selection: $model.selected) { installed in
                Text(installed.manifest.title)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let installed = model.extensions.first(where: { $0.manifest.name == model.selected }) {
                ExtensionPreferencesForm(model: model, installed: installed)
            } else {
                Text("No extension has preferences.").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 620, minHeight: 400)
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
