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
            Section("Calendar") {
                CalendarAccessRow(model: model)
            }
            LaunchPermissionsSection(model: model)
            Section {
                LabeledContent {
                    Button("Show Onboarding Again") { model.showOnboardingAgain() }
                } label: {
                    Text("Go through Fudge's first-run choices again, starting from what's set now.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The answers to "Allow <A> to open <B>'s commands?": each can be changed, or forgotten so it's asked again.
/// Always shown, so there's one place to look even before any extension has asked. Answers to an extension installed
/// from two or more repositories are one row per caller, whose menu picks the copy (`LaunchPermissions.rows`).
struct LaunchPermissionsSection: View {
    let model: SettingsModel

    var body: some View {
        Section {
            if model.launchPermissionsUnreadable {
                Text(LaunchPermissions.Unreadable().description).font(.callout).foregroundStyle(.red)
            } else if model.launchPermissionRows.isEmpty {
                Text("No extension has asked to open another yet.").foregroundStyle(.secondary)
            }
            ForEach(model.launchPermissionRows) { row in
                Group {
                    switch row {
                    case .answer(let entry): answerRow(entry)
                    case .choice(let choice): choiceRow(choice)
                    }
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

    /// One answer: caller → target, "Allowed" or "Not allowed", and ✕.
    private func answerRow(_ entry: LaunchPermissions.Entry) -> some View {
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
            forgetButton { model.forgetLaunchPermission(caller: entry.caller, target: entry.target) }
        }
    }

    /// A caller's choice among copies: caller → a menu of each copy, "Not allowed", and "Ask next time" only while
    /// nothing is chosen, so the menu always shows what's stored; and ✕, which forgets the choice.
    private func choiceRow(_ choice: LaunchPermissions.Choice) -> some View {
        let copies = choice.copies.map(\.id)
        return HStack(spacing: 6) {
            name(choice.caller)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).imageScale(.small)
            Picker(
                "",
                selection: Binding(
                    get: { choice.selection },
                    set: { picked in
                        switch picked {
                        case .chosen(let copy): model.chooseLaunchCopy(copy, caller: choice.caller, among: copies)
                        case .notAllowed: model.chooseLaunchCopy(nil, caller: choice.caller, among: copies)
                        case .unanswered: break
                        }
                    })
            ) {
                ForEach(choice.copies, id: \.id) { copy in
                    Text(model.copyTitle(copy)).tag(LaunchPermissions.CopyChoice.chosen(copy.id))
                }
                Text("Not allowed").tag(LaunchPermissions.CopyChoice.notAllowed)
                if choice.selection == .unanswered {
                    Text("Ask next time").tag(LaunchPermissions.CopyChoice.unanswered)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            forgetButton { model.forgetLaunchChoice(caller: choice.caller, among: copies) }
        }
    }

    private func forgetButton(_ forget: @escaping () -> Void) -> some View {
        Button(action: forget) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Forget: ask again the next time")
    }

    /// The extension's title, or its id in grey when it isn't installed.
    @ViewBuilder private func name(_ id: ExtensionID) -> some View {
        if let title = model.extensionTitle(id) {
            Text(title)
        } else {
            Text(id.key).foregroundStyle(.secondary).help("Not installed")
        }
    }
}
