import FudgeCore
import SwiftUI

/// The Settings window's General page: Open at Login, the launcher's hotkey, whether the calculator downloads
/// exchange rates, and clearing root search's history.
struct GeneralPage: View {
    @Bindable var model: SettingsModel
    @State private var confirmingClear = false

    var body: some View {
        Form {
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
                    Text("\(model.launcherHotkey.description); change it in settings.json")
                        .foregroundStyle(.secondary)
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
