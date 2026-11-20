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

/// Reads the status when the view appears, then every second until it goes away.
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
                Text("If macOS didn't ask, click again to open the Accessibility settings, then turn fudge on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .modifier(AccessibilityStatusPolling(status: status))
    }
}

/// Settings → Permissions: what fudge needs from macOS, and Show Onboarding Again.
struct PermissionsPage: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Accessibility") {
                AccessibilityControls(status: model.accessibility)
            }
            Section {
                LabeledContent {
                    Button("Show Onboarding Again") { model.showOnboarding() }
                } label: {
                    Text("Go through fudge's first-run choices again, starting from what's set now.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
