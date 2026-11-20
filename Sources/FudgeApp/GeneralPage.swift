import FudgeCore
import SwiftUI

/// The Settings window's General page: the launcher's hotkey, and whether the calculator downloads exchange rates.
struct GeneralPage: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Launcher hotkey") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        LauncherHotkeyCell(model: model)
                        Button("Reset to \(HotKeySpec.default.description)") { model.recordLauncherHotkey(.clear) }
                            .controlSize(.small)
                            .disabled(model.launcherHotkey.sameKeys(as: .default) && !model.launcherHotkeyInUse)
                    }
                }
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
        }
        .formStyle(.grouped)
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
