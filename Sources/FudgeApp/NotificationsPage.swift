import AppKit
import FudgeCore
import SwiftUI

/// Settings → Notifications (SPEC-156 F): macOS's answer for Fudge, read and never asked, with Ask Now while it hasn't
/// been asked and a way to its pane, then one switch per notification. The switches stay usable while macOS has them
/// off: they're Fudge's own choice.
struct NotificationsPage: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Section("macOS") {
                LabeledContent {
                    if let permission = model.notificationPermission {
                        Button(permission.buttonTitle) {
                            if permission == .notAsked {
                                model.askForNotificationsNow()
                            } else {
                                model.openNotificationSettings()
                            }
                        }
                    }
                } label: {
                    Text("Notifications for Fudge")
                    Text(model.notificationPermission?.statusLine ?? "Checking…")
                }
            }
            Section {
                Toggle(
                    isOn: Binding(
                        get: { model.notifyInstallFinished }, set: { model.setNotifyInstallFinished($0) })
                ) {
                    Text("Install or update finished")
                    Text("When an extension you install or update is ready to use.")
                }
                Toggle(
                    isOn: Binding(get: { model.notifyInstallFailed }, set: { model.setNotifyInstallFailed($0) })
                ) {
                    Text("Install or update failed")
                    Text("When an extension couldn't be installed or updated.")
                }
            } header: {
                Text("Extension Store")
            } footer: {
                Text("Shown only while the Extension Store isn't on screen.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .task { model.refreshNotificationPermission() }
    }
}
