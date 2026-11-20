import FudgeCore
import SwiftUI

/// The Settings window's General page: the launcher's hotkey, and whether the calculator downloads exchange rates.
struct GeneralPage: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Launcher hotkey") {
                    Text("\(model.launcherHotkey.description); change it in settings.json")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Pop to Root Search") {
                    HStack(spacing: 6) {
                        Picker(
                            "Pop to Root Search",
                            selection: Binding(get: { model.resetAfter }, set: { model.setResetAfter($0) })
                        ) {
                            ForEach(PanelResetSetting.allCases) { setting in Text(setting.title).tag(setting) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("Timeout after which fudge resets to root search after closing the window")
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
