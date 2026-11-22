import FudgeCore
import SwiftUI

/// **Extension Repositories** (FUD-182), right below the Extension Store's switch on its page: Raycast's official
/// repository first, with a switch and no remove button, then each added one with its switch and a remove button,
/// each with its status line; then the Address and Branch fields and Add…. Its controls are off while the store is.
struct ExtensionRepositoriesSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section {
            row(
                name: ExtensionRepositoryText.raycastName, detail: ExtensionRepositoryText.raycastAddress,
                copyId: ExtensionRepository.raycastCopyId, branch: nil,
                isOn: Binding(get: { model.raycastRepository }, set: { model.setRaycastRepository($0) }),
                removable: false)
            ForEach(model.extensionRepositories, id: \.repository.copyId) { listed in
                let repository = listed.repository
                row(
                    name: repository.name, detail: ExtensionRepositoryText.detail(repository),
                    copyId: repository.copyId, branch: repository.branch,
                    isOn: Binding(get: { listed.on }, set: { model.setRepository(repository.copyId, on: $0) }),
                    removable: true)
            }
            TextField(
                ExtensionRepositoryText.addressLabel, text: $model.repositoryAddress,
                prompt: Text(ExtensionRepositoryText.addressPrompt))
            TextField(
                ExtensionRepositoryText.branchLabel, text: $model.repositoryBranch,
                prompt: Text(ExtensionRepositoryText.branchPrompt))
            HStack {
                // A refused address says why here, in red, as the Sign-in page does, and nothing is asked.
                if let problem = model.repositoryProblem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
                Button(ExtensionRepositoryText.addButton) { model.addRepository() }
                    .disabled(model.repositoryAddress.allSatisfy(\.isWhitespace))
            }
        } header: {
            Text(ExtensionRepositoryText.section)
        }
        .disabled(!model.extensionStore)
        .onAppear { model.loadRepositoryStatuses() }
    }

    /// A repository's row: its name, the address (and branch) in secondary text, its status line under that, red for
    /// a problem, and its switch, with a remove button for an added one.
    private func row(
        name: String, detail: String, copyId: String, branch: String?, isOn: Binding<Bool>, removable: Bool
    ) -> some View {
        let status = model.repositoryStatuses[copyId] ?? .notChecked
        return LabeledContent {
            HStack(spacing: 8) {
                Toggle(name, isOn: isOn).labelsHidden().toggleStyle(.switch)
                if removable {
                    Button {
                        model.removeRepository(copyId)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(ExtensionRepositoryText.removeHelp)
                }
            }
        } label: {
            Text(name)
            Text(detail)
            Text(status.sentence(branch: branch)).foregroundStyle(status.isProblem ? .red : .secondary)
        }
    }
}
