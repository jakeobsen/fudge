import AppKit
import FudgeCore
import SwiftUI

/// The Settings window's Snippets page (SPEC-078 §4): every snippet's name, keyword and the start of its text, sorted
/// by name, with + to add one, Edit… (or a double-click) to change one, and − to delete one.
struct SnippetsPage: View {
    @Bindable var model: SettingsModel
    @State private var selection: Snippet.ID?
    @State private var sheet: SnippetSheet.Editing?

    var body: some View {
        VStack(spacing: 0) {
            ExpandSnippetsRow(model: model)
            Divider()
            if model.snippetsUnreadable {
                Label(SnippetStore.Unreadable().description, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            if model.snippets.isEmpty {
                Text(
                    model.snippetsUnreadable
                        ? "" : "No snippets yet. Create one with + or with Create Snippet in Fudge."
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.snippets, selection: $selection) {
                    TableColumn("Name", value: \.name)
                        .width(min: 100, ideal: 160, max: 240)
                    TableColumn("Keyword") { snippet in
                        Text(snippet.keyword ?? "").font(.system(.body, design: .monospaced))
                    }
                    .width(min: 60, ideal: 90, max: 160)
                    TableColumn("Snippet") { snippet in
                        Text(Self.preview(of: snippet.text)).truncationMode(.tail).foregroundStyle(.secondary)
                    }
                    .width(min: 160, ideal: 380)
                }
                .contextMenu(forSelectionType: Snippet.ID.self) { ids in
                    if let id = ids.first {
                        Button("Edit…") { edit(id) }
                        Button("Delete…", role: .destructive) { delete(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .onDeleteCommand { if let selection { delete(selection) } }
                .disabled(model.snippetsUnreadable)
            }
            Divider()
            HStack(spacing: 2) {
                Button {
                    sheet = .init(draft: SnippetDraft())
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 18)
                }
                .help("Add a snippet")
                Button {
                    if let selection { delete(selection) }
                } label: {
                    Image(systemName: "minus").frame(width: 20, height: 18)
                }
                .help("Delete the selected snippet")
                .disabled(selection == nil)
                Spacer()
                Button("Edit…") { if let selection { edit(selection) } }
                    .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .disabled(model.snippetsUnreadable)
        }
        .onAppear { model.loadSnippets() }
        .onChange(of: model.snippets.map(\.id)) { _, ids in
            if let selected = selection, !ids.contains(selected) { selection = nil }
        }
        .sheet(item: $sheet) { editing in
            SnippetSheet(model: model, draft: editing.draft) { sheet = nil }
        }
    }

    /// The text on one line: its lines joined by spaces, cut short well before the column could show it all.
    static func preview(of text: String) -> String {
        text.prefix(300).split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func edit(_ id: Snippet.ID) {
        guard let snippet = model.snippets.first(where: { $0.id == id }) else { return }
        sheet = .init(draft: SnippetDraft(editing: snippet))
    }

    /// Asks in a sheet first, as Delete Snippet… does in the launcher.
    private func delete(_ id: Snippet.ID) {
        guard !model.snippetsUnreadable, let snippet = model.snippets.first(where: { $0.id == id }) else { return }
        let request = LauncherModel.AlertRequest(
            title: "Delete “\(snippet.name)”?", message: "It's removed from Search Snippets.", primary: "Delete",
            dismiss: "Cancel", destructive: true)
        Task {
            guard await model.confirm(request) else { return }
            model.deleteSnippet(id: id)
        }
    }
}

/// **Expand Snippets as You Type** (SPEC-078 §5): the switch, and Input Monitoring's status while it's on. Turning it
/// on without Input Monitoring says why it's needed, then asks macOS (its prompt the first time, its pane after that).
struct ExpandSnippetsRow: View {
    @Bindable var model: SettingsModel

    static let explanation = "Type a snippet's keyword in any app to replace it with the snippet."
    static let permissionRequest = LauncherModel.AlertRequest(
        title: "Allow Input Monitoring?",
        message: SnippetExpander.permissionsExplanation,
        primary: "Open System Settings", dismiss: "Cancel", destructive: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expand Snippets as You Type")
                    Text(Self.explanation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // A closure, not the method itself: Swift 6.3's compiler crashes on the thunk a method reference
                // needs here.
                Toggle("", isOn: Binding(get: { model.expandSnippets }, set: { on in switched(on) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if model.expandSnippets {
                HStack(spacing: 6) {
                    if model.inputMonitoring.isAllowed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Input Monitoring is allowed.").font(.caption)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Fudge needs Input Monitoring to expand snippets.").font(.caption)
                        Spacer()
                        Button("Open Input Monitoring Settings") { InputMonitoring.request() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .task {
            while !Task.isCancelled {
                model.inputMonitoring.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func switched(_ on: Bool) {
        guard on else {
            model.setExpandSnippets(false)
            return
        }
        guard !model.inputMonitoring.isAllowed else {
            model.setExpandSnippets(true)
            return
        }
        Task {
            guard await model.confirm(Self.permissionRequest) else { return }
            model.turnOnSnippetExpansion()
        }
    }
}

/// The sheet that adds or edits a snippet: Name, Snippet and Keyword, with each field's problem under it.
private struct SnippetSheet: View {
    struct Editing: Identifiable {
        let id = UUID()
        var draft: SnippetDraft
    }

    let model: SettingsModel
    @State var draft: SnippetDraft
    let done: () -> Void
    @State private var problems = SnippetDraft.Problems()
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.id == nil ? "New Snippet" : "Edit Snippet").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    field(TextField("", text: $draft.name, prompt: Text("Snippet name")), problem: problems.name)
                }
                GridRow {
                    Text("Snippet")
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $draft.text)
                            .font(.body)
                            .frame(height: 140)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        if let problem = problems.text { Text(problem).font(.caption).foregroundStyle(.red) }
                        Text(SnippetForm.textInfo).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Keyword")
                    field(
                        TextField("", text: $draft.keyword, prompt: Text("Optional, like /addr")),
                        problem: problems.keyword)
                }
            }
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: draft.name) { _, _ in problems.name = nil }
        .onChange(of: draft.text) { _, _ in problems.text = nil }
        .onChange(of: draft.keyword) { _, _ in problems.keyword = nil }
    }

    private func field(_ textField: TextField<Text>, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            textField.textFieldStyle(.roundedBorder)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    private func save() {
        switch model.saveSnippet(draft) {
        case .saved: done()
        case .problems(let found): problems = found
        case .failed(let message): failure = message
        }
    }
}
