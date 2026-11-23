import FudgeCore
import SwiftUI

/// **Extension Repositories** (FUD-182, SPEC-160), right below the Extension Store's switch on its page: every
/// repository in the list with the same row, Raycast's official one first while it's there, then the added ones in
/// order; under them **Add Raycast's Repository** (only while it's removed) and **Add Repository…**, which opens the
/// add window. Its controls are off while the store is.
struct ExtensionRepositoriesSection: View {
    @Bindable var model: SettingsModel
    /// The add window's fields, made new each time it opens, as the Quicklinks page's sheet's draft is, so a window
    /// closed any other way comes back empty.
    @State private var draft = ExtensionRepositoryDraft()
    @State private var adding = false

    var body: some View {
        Section {
            if model.raycastRepositoryListed {
                row(
                    name: ExtensionRepositoryText.raycastName, detail: ExtensionRepositoryText.raycastAddress,
                    copyId: ExtensionRepository.raycastCopyId, branch: nil,
                    isOn: Binding(get: { model.raycastRepository }, set: { model.setRaycastRepository($0) }))
            }
            ForEach(model.extensionRepositories, id: \.repository.copyId) { listed in
                let repository = listed.repository
                row(
                    name: repository.name, detail: ExtensionRepositoryText.detail(repository),
                    copyId: repository.copyId, branch: repository.branch,
                    isOn: Binding(get: { listed.on }, set: { model.setRepository(repository.copyId, on: $0) }))
            }
            HStack {
                Spacer()
                if model.showsAddRaycastRepository {
                    Button(ExtensionRepositoryText.addRaycastButton) { model.addRaycastRepository() }
                }
                Button(ExtensionRepositoryText.addRepositoryButton) {
                    draft = ExtensionRepositoryDraft()
                    adding = true
                }
            }
            .sheet(isPresented: $adding) {
                AddRepositoryWindow(model: model, draft: $draft) { adding = false }
            }
        } header: {
            Text(ExtensionRepositoryText.section)
        }
        .disabled(!model.extensionStore)
        .onAppear { model.loadRepositoryStatuses() }
    }

    /// A repository's row: its name, the address (and branch) in secondary text, its status line under that, red for
    /// a problem, its switch and its remove button.
    private func row(name: String, detail: String, copyId: String, branch: String?, isOn: Binding<Bool>) -> some View {
        let status = model.repositoryStatuses[copyId] ?? .notChecked
        return LabeledContent {
            HStack(spacing: 8) {
                Toggle(name, isOn: isOn).labelsHidden().toggleStyle(.switch)
                Button {
                    model.removeRepository(copyId)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(ExtensionRepositoryText.removeHelp)
            }
        } label: {
            Text(name)
            Text(detail)
            Text(status.sentence(branch: branch)).foregroundStyle(status.isProblem ? .red : .secondary)
        }
    }
}

/// The **Add Repository** window (SPEC-160 B): Address, with the cursor in it, Branch, the warning, a refused address's
/// reason in red, and Cancel (Esc) and Add (↵). The window is the warning, so nothing asks again after Add.
struct AddRepositoryWindow: View {
    let model: SettingsModel
    @Binding var draft: ExtensionRepositoryDraft
    let close: () -> Void
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ExtensionRepositoryText.addWindowTitle).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(ExtensionRepositoryText.addressLabel).gridColumnAlignment(.trailing)
                    TextField("", text: $draft.address, prompt: Text(ExtensionRepositoryText.addressPrompt))
                        .textFieldStyle(.roundedBorder)
                        .focused($addressFocused)
                }
                GridRow {
                    Text(ExtensionRepositoryText.branchLabel)
                    TextField("", text: $draft.branch, prompt: Text(ExtensionRepositoryText.branchPrompt))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text(ExtensionRepositoryText.addWarning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = draft.reason {
                Text(reason).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(ExtensionRepositoryText.cancel, role: .cancel) {
                    draft = draft.cancelled()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button(ExtensionRepositoryText.add) {
                    if model.addRepository(&draft) { close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canAdd)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { addressFocused = true }
    }
}

/// A snapshot run's **Add Repository** window, drawn over the Extension Store's page from
/// `SettingsModel.snapshotAddRepository`, since a snapshot run never begins a sheet, as the Window Management page
/// draws its position sheet.
struct AddRepositorySnapshotOverlay: View {
    let model: SettingsModel

    var body: some View {
        if let draft = model.snapshotAddRepository {
            ZStack {
                Color.black.opacity(0.15)
                AddRepositoryWindow(model: model, draft: .constant(draft)) {}
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 12)
            }
        }
    }
}
