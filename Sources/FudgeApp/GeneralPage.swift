import FudgeCore
import SwiftUI

/// The Settings window's General page: Open at Login, the launcher's hotkey, whether the calculator downloads
/// exchange rates, and clearing root search's history.
struct GeneralPage: View {
    @Bindable var model: SettingsModel
    @State private var confirmingClear = false

    var body: some View {
        Form {
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            Section {
                Toggle(
                    "Open at Login",
                    isOn: Binding(get: { model.loginItemState.isOn }, set: { model.setOpenAtLogin($0) })
                )
                .toggleStyle(.switch)
                if let note = model.loginItemState.note {
                    HStack {
                        Text(note).foregroundStyle(.secondary)
                        Spacer()
                        if model.loginItemState.offersLoginItemsSettings {
                            Button("Open Login Items") { model.openLoginItemsSettings() }
                        }
                    }
                }
                if let error = model.loginItemError {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Launcher hotkey") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        LauncherHotkeyCell(model: model)
                        Button("Reset to \(HotKeySpec.default.description)") { model.recordLauncherHotkey(.clear) }
                            .controlSize(.small)
                            .disabled(model.launcherHotkey.sameKeys(as: .default) && !model.launcherHotkeyInUse)
                    }
                }
                SettingsPopupRow(
                    "Pop to Root Search",
                    selection: Binding(get: { model.resetAfter }, set: { model.setResetAfter($0) }),
                    options: PanelResetSetting.allCases.map { ($0, $0.title) },
                    help: "How long after the window closes fudge goes back to root search."
                )
            }
            Section("Calculator") {
                Toggle(isOn: Binding(get: { model.currencyRates }, set: { model.setCurrencyRates($0) })) {
                    Text("Currency conversion: download exchange rates from the European Central Bank once a day")
                    Text(
                        "This is the only connection fudge makes on its own. It downloads one public file; like any "
                            + "download, the server sees your IP address, and nothing else is sent."
                    )
                }
                .toggleStyle(.checkbox)
            }
            Section("Search") {
                LabeledContent {
                    Button("Clear Search History…") { confirmingClear = true }
                } label: {
                    Text("Root search ranks what you open often first.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLoginItem() }
        .alert("Clear search history?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { model.clearSearchHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Root search forgets which results you opened, and ranks them by name again.")
        }
    }
}

/// The launcher's hotkey as keycaps; clicking records a new one, with the Commands page's rules. It can't be
/// cleared: ⌫ resets it to ⌥Space, since without it fudge opens only from the menu bar item.
private struct LauncherHotkeyCell: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if model.recording == SettingsModel.launcherRecording {
                HotkeyRecordingPrompt { [model] key in model.recordLauncherHotkey(key) }
            } else {
                Button {
                    model.startRecording(SettingsModel.launcherRecording)
                } label: {
                    Keycaps(spec: model.launcherHotkey)
                }
                .buttonStyle(.plain)
                .help("Click, then press a new shortcut")
            }
            if let message = model.hotkeyMessages[SettingsModel.launcherRecording] {
                Text(message).font(.system(size: 10)).foregroundStyle(.red)
            } else if model.launcherHotkeyInUse {
                Text("In use by another app").font(.system(size: 10)).foregroundStyle(.red)
            }
        }
    }
}

/// A General-page row as Raycast lays it out: a label, a popup of choices, and an ⓘ whose tooltip explains it.
struct SettingsPopupRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let help: String

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], help: String) {
        self.title = title
        _selection = selection
        self.options = options.map { (value: $0.0, title: $0.1) }
        self.help = help
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.value) { option in Text(option.title).tag(option.value) }
                }
                .labelsHidden()
                .fixedSize()
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(help)
                    .accessibilityLabel(help)
            }
        }
    }
}
