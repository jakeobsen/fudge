import FudgeCore
import SwiftUI

/// The Settings window's General page: Open at Login, the launcher's hotkey, whether the calculator downloads
/// exchange rates, clearing root search's history, and which extensions may open other extensions' commands.
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
                OpenAtLoginControls(model: model)
            }
            Section {
                LabeledContent("Launcher hotkey") {
                    LauncherHotkeyControls(model: model)
                }
            }
            Section("Calculator") {
                CurrencyRatesToggle(model: model)
                Picker(
                    selection: Binding(get: { model.numberFormat }, set: { model.setNumberFormat($0) })
                ) {
                    Text("Same as macOS (\(Calculator.format(1234.5, locale: .current, for: .card)))")
                        .tag(NumberFormatSetting.system)
                    Text("1,234.5").tag(NumberFormatSetting.dotDecimal)
                    Text("1.234,5").tag(NumberFormatSetting.commaDecimal)
                } label: {
                    Text("Number format")
                    Text("How the calculator reads the numbers you type, and writes its answers.")
                }
            }
            Section("Search") {
                LabeledContent {
                    Button("Clear Search History…") { confirmingClear = true }
                } label: {
                    Text("Root search ranks what you open often first.")
                }
            }
            if !model.launchPermissions.isEmpty || model.launchPermissionsUnreadable {
                LaunchPermissionsSection(model: model)
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

/// The answers to "Allow <A> to open <B>'s commands?": each can be changed, or forgotten so it's asked again.
private struct LaunchPermissionsSection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            if model.launchPermissionsUnreadable {
                Text(LaunchPermissions.Unreadable().description).font(.callout).foregroundStyle(.red)
            }
            ForEach(model.launchPermissions) { entry in
                HStack(spacing: 6) {
                    name(entry.caller)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).imageScale(.small)
                    name(entry.target)
                    Spacer()
                    Picker(
                        "",
                        selection: Binding(
                            get: { entry.allowed },
                            set: { model.setLaunchPermission($0, caller: entry.caller, target: entry.target) })
                    ) {
                        Text("Allowed").tag(true)
                        Text("Not allowed").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        model.forgetLaunchPermission(caller: entry.caller, target: entry.target)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Forget: ask again the next time")
                }
                .disabled(model.launchPermissionsUnreadable)
            }
        } header: {
            Text("Extensions that open other extensions")
        } footer: {
            Text("fudge asks the first time an extension opens another extension's commands.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The extension's title, or its name in grey when it isn't installed.
    @ViewBuilder private func name(_ extensionName: String) -> some View {
        if let title = model.extensionTitle(extensionName) {
            Text(title)
        } else {
            Text(extensionName).foregroundStyle(.secondary).help("Not installed")
        }
    }
}

// The controls below are General's, and onboarding's steps use the same ones, so both make the same model calls.

/// The Open at Login switch, with macOS's approval note and Open Login Items when it asks for one.
struct OpenAtLoginControls: View {
    let model: SettingsModel

    var body: some View {
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
}

/// The calculator's currency conversion checkbox, saying what it downloads and from where.
struct CurrencyRatesToggle: View {
    let model: SettingsModel

    var body: some View {
        Toggle(isOn: Binding(get: { model.currencyRates }, set: { model.setCurrencyRates($0) })) {
            Text("Currency conversion: download exchange rates from the European Central Bank once a day")
            Text(
                "Apart from the images extensions show, this is the only connection fudge makes on its own. It "
                    + "downloads one public file; like any download, the server sees your IP address, and nothing "
                    + "else is sent."
            )
        }
        .toggleStyle(.checkbox)
    }
}

/// The launcher's hotkey and its Reset button.
struct LauncherHotkeyControls: View {
    let model: SettingsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            LauncherHotkeyCell(model: model)
            Button("Reset to \(HotKeySpec.default.description)") { model.recordLauncherHotkey(.clear) }
                .controlSize(.small)
                .disabled(model.launcherHotkey.sameKeys(as: .default) && !model.launcherHotkeyInUse)
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
