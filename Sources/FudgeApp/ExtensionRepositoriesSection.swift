import FudgeCore
import SwiftUI

/// **Extension Repositories** (FUD-182, SPEC-160, SPEC-176), right below the Extension Store's switch on its page:
/// every repository in the list, Raycast's official one included, with the same row, in the list's order; under them
/// an add button per row of `RepositoryButton.all` that isn't hidden (disabled with the reason as its help while the
/// add window's checks refuse it), and **Add Repository…**, which opens the add window. Its controls are off while the
/// store is.
struct ExtensionRepositoriesSection: View {
    @Bindable var model: SettingsModel
    /// The add window's fields, made new each time it opens, as the Quicklinks page's sheet's draft is, so a window
    /// closed any other way comes back empty.
    @State private var draft = ExtensionRepositoryDraft()
    @State private var adding = false

    var body: some View {
        Section {
            ForEach(model.extensionRepositories, id: \.repository.copyId) { listed in
                let repository = listed.repository
                row(
                    name: ExtensionRepositoryText.rowName(listed), detail: ExtensionRepositoryText.detail(repository),
                    copyId: repository.copyId, branch: repository.branch,
                    isOn: Binding(get: { listed.on }, set: { model.setRepository(repository.copyId, on: $0) }))
            }
            HStack {
                Spacer()
                ForEach(model.repositoryButtons, id: \.button.title) { button, state in
                    switch state {
                    case .hidden: EmptyView()
                    case .enabled: Button(button.title) { model.addRepository(button: button) }
                    case .disabled(let reason): Button(button.title) {}.disabled(true).help(reason)
                    }
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

    /// A repository's row: its name (the name it was added with, else its `owner/repository`), the address
    /// (and branch) in secondary text, its status line under that, red for
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

/// The **Add Repository** window (SPEC-160 B, SPEC-174 B1): Address, with the cursor in it, Branch, Name, a line on
/// what the name is for, the warning, a refused address's or name's reason in red, and Cancel (Esc) and Add (↵). The
/// window is the warning, so nothing asks again after Add.
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
                GridRow {
                    Text(ExtensionRepositoryText.nameLabel)
                    TextField("", text: $draft.label, prompt: Text(ExtensionRepositoryText.namePrompt))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text(ExtensionRepositoryText.nameHelp)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
