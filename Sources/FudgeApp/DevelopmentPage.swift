import AppKit
import FudgeCore
import SwiftUI

/// Settings → Development (SPEC-145 §1): the folder of Apple's Command Line Tools that builds extensions' parts written
/// in Swift, found by itself or chosen, with its status. The status is read when the page appears, and every few
/// seconds while it's on screen and nothing is found, so tools installed meanwhile show up.
struct DevelopmentPage: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Section {
                CommandLineToolsRow(model: model)
            } footer: {
                Text(CommandLineTools.Text.help).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .task {
            model.loadCommandLineTools()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if model.commandLineTools?.tools == nil { model.loadCommandLineTools() }
            }
        }
    }
}

/// The Command Line Tools row: the folder and its status line, Choose…, Use Default while one is chosen, and
/// Install… while nothing is found.
private struct CommandLineToolsRow: View {
    let model: SettingsModel

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if model.commandLineTools != nil, model.commandLineTools?.tools == nil {
                    Button(CommandLineTools.Text.install) { model.installCommandLineTools() }
                }
                Button(CommandLineTools.Text.choose) { choose() }
                if model.commandLineToolsSetting != nil {
                    Button(CommandLineTools.Text.useDefault) { model.setCommandLineTools(nil) }
                }
            }
        } label: {
            Text(CommandLineTools.Text.title)
            if let folder = model.commandLineToolsFolder {
                Text((folder as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
            }
            Text(model.commandLineTools?.line ?? "Checking…")
            if let problem = model.commandLineToolsInstallProblem {
                Text(problem).foregroundStyle(.red)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Library/Developer", isDirectory: true)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.setCommandLineTools(url.path) }
    }
}
