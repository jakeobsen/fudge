import AppKit
import FudgeCore
import Observation
import SwiftUI

/// Whether fudge has Accessibility permission, as onboarding's step and the Permissions page show it. Each reads it
/// when it appears and every second while it's on screen (`AccessibilityStatusPolling`), never with a prompt.
@MainActor
@Observable
final class AccessibilityStatus {
    private(set) var isTrusted = false
    /// macOS's prompt was asked for this run, here or by an extension reading the selection.
    private(set) var promptShown = false
    @ObservationIgnored private let access: any AccessibilityAccess
    @ObservationIgnored private let promptShownElsewhere: () -> Bool
    @ObservationIgnored private let openPane: (URL) -> Void

    init(
        access: any AccessibilityAccess, promptShownElsewhere: @escaping () -> Bool = { false },
        openPane: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.access = access
        self.promptShownElsewhere = promptShownElsewhere
        self.openPane = openPane
        refresh()
    }

    func refresh() {
        let trusted = access.isTrusted(prompt: false)
        if trusted != isTrusted { isTrusted = trusted }
        if !promptShown, promptShownElsewhere() { promptShown = true }
    }

    /// Open Accessibility Settings: macOS's prompt on the first click, the pane on later ones
    /// (`AccessibilityPermission.request`), so the two never stack.
    func openSettings() {
        switch AccessibilityPermission.request(promptShown: promptShown || promptShownElsewhere()) {
        case .prompt:
            promptShown = true
            isTrusted = access.isTrusted(prompt: true)
        case .openPane:
            openPane(AccessibilitySettingsAlert.paneURL)
        }
    }
}

/// A fixed answer for snapshots (`--accessibility allowed|missing`): no prompt, nothing read from the system.
@MainActor
final class FixedAccessibility: AccessibilityAccess {
    private let trusted: Bool

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted(prompt: Bool) -> Bool { trusted }
    func selectedText(pid: Int32) async -> String? { nil }
}

extension NSWindow {
    /// Drops the window's views once it has closed, so a SwiftUI `.task` in them (the Accessibility polling) is
    /// cancelled: a closed window that isn't released keeps its views, and their tasks, alive. Done on the next turn,
    /// after the close, and only if the window hasn't been shown again meanwhile.
    func dropContentWhenClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isVisible else { return }
            self.contentView = nil
        }
    }
}

/// Reads the status when the view appears, then every second until it goes away. A closed window drops its views
/// (`dropContentWhenClosed`), which ends this too.
struct AccessibilityStatusPolling: ViewModifier {
    let status: AccessibilityStatus

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                status.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Accessibility's status and reason, with Open Accessibility Settings while it isn't allowed. Onboarding's step and
/// the Permissions page both show it.
struct AccessibilityControls: View {
    let status: AccessibilityStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AccessibilityPermission.reason).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if status.isTrusted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Not allowed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Accessibility Settings") { status.openSettings() }
                }
            }
            if !status.isTrusted, status.promptShown {
                Text("If macOS didn't ask, click again to open the Accessibility settings, then turn Fudge on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .modifier(AccessibilityStatusPolling(status: status))
    }
}

/// Settings → Permissions: what fudge needs from macOS, the answers about extensions opening other extensions, and
/// Show Onboarding Again.
struct PermissionsPage: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Accessibility") {
                AccessibilityControls(status: model.accessibility)
            }
            LaunchPermissionsSection(model: model)
            Section {
                LabeledContent {
                    Button("Show Onboarding Again") { model.showOnboarding() }
                } label: {
                    Text("Go through Fudge's first-run choices again, starting from what's set now.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The answers to "Allow <A> to open <B>'s commands?": each can be changed, or forgotten so it's asked again.
/// Always shown, so there's one place to look even before any extension has asked.
struct LaunchPermissionsSection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            if model.launchPermissionsUnreadable {
                Text(LaunchPermissions.Unreadable().description).font(.callout).foregroundStyle(.red)
            } else if model.launchPermissions.isEmpty {
                Text("No extension has asked to open another yet.").foregroundStyle(.secondary)
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
            Text("When one extension opens another, Fudge asks you once. Your answers are here.")
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
