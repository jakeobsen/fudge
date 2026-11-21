import AppKit
import FudgeCore
import SwiftUI

/// The Settings window's Quicklinks page (SPEC-052 B4): every quicklink's name, link and app, sorted by name, with
/// + to add one, Edit… (or a double-click) to change one, and − to delete one. Each one's alias and hotkey show
/// too, read only: they're set on the Commands page (SPEC-097).
struct QuicklinksPage: View {
    @Bindable var model: SettingsModel
    @State private var selection: Quicklink.ID?
    @State private var sheet: QuicklinkSheet.Editing?

    var body: some View {
        VStack(spacing: 0) {
            if model.quicklinksUnreadable {
                Label(QuicklinkStore.Unreadable().description, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            if model.quicklinks.isEmpty {
                Text(
                    model.quicklinksUnreadable
                        ? "" : "No quicklinks yet. Create one with + or with Create Quicklink in Fudge."
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.quicklinks, selection: $selection) {
                    TableColumn("Name", value: \.name)
                        .width(min: 90, ideal: 130, max: 240)
                    TableColumn("Link") { quicklink in
                        Text(quicklink.link).truncationMode(.middle).help(quicklink.link)
                    }
                    .width(min: 120, ideal: 190)
                    TableColumn("Open With") { quicklink in
                        Text(model.applicationName(of: quicklink))
                    }
                    .width(min: 70, ideal: 90, max: 200)
                    // Read only here: they're set on the Commands page, with every command's.
                    TableColumn("Alias") { quicklink in
                        Text(QuicklinkCommands.commandID(ofQuicklink: quicklink.id).flatMap(model.alias(for:)) ?? "")
                            .font(.system(size: 12, design: .monospaced))
                            .help(Self.editHelp)
                    }
                    .width(min: 50, ideal: 60, max: 120)
                    TableColumn("Hotkey") { quicklink in
                        Group {
                            if let spec = QuicklinkCommands.commandID(ofQuicklink: quicklink.id).flatMap(
                                model.hotkey(for:))
                            {
                                Keycaps(spec: spec)
                            } else {
                                Text("")
                            }
                        }
                        .help(Self.editHelp)
                    }
                    .width(min: 80, ideal: 90, max: 140)
                }
                .contextMenu(forSelectionType: Quicklink.ID.self) { ids in
                    if let id = ids.first {
                        Button("Edit…") { edit(id) }
                        Button("Delete…", role: .destructive) { delete(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .onDeleteCommand { if let selection { delete(selection) } }
                .disabled(model.quicklinksUnreadable)
            }
            Divider()
            HStack(spacing: 2) {
                Button {
                    sheet = .init(draft: QuicklinkDraft())
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 18)
                }
                .help("Add a quicklink")
                Button {
                    if let selection { delete(selection) }
                } label: {
                    Image(systemName: "minus").frame(width: 20, height: 18)
                }
                .help("Delete the selected quicklink")
                .disabled(selection == nil)
                Spacer()
                Button("Edit…") { if let selection { edit(selection) } }
                    .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .disabled(model.quicklinksUnreadable)
        }
        .onAppear { model.loadQuicklinks() }
        .onChange(of: model.quicklinks.map(\.id)) { _, ids in
            if let selected = selection, !ids.contains(selected) { selection = nil }
        }
        .sheet(item: $sheet) { editing in
            QuicklinkSheet(model: model, draft: editing.draft) { sheet = nil }
        }
    }

    /// The Alias and Hotkey columns' help.
    private static let editHelp = "Edit on the Commands page"

    private func edit(_ id: Quicklink.ID) {
        guard let quicklink = model.quicklinks.first(where: { $0.id == id }) else { return }
        sheet = .init(draft: QuicklinkDraft(editing: quicklink))
    }

    /// Asks in a sheet first, as Delete Quicklink… does in the launcher.
    private func delete(_ id: Quicklink.ID) {
        guard !model.quicklinksUnreadable, let quicklink = model.quicklinks.first(where: { $0.id == id }) else {
            return
        }
        let request = LauncherModel.AlertRequest(
            title: "Delete “\(quicklink.name)”?", message: "It's removed from root search.", primary: "Delete",
            dismiss: "Cancel", destructive: true)
        Task {
            guard await model.confirm(request) else { return }
            model.deleteQuicklink(id: id)
        }
    }
}

/// The sheet that adds or edits a quicklink: Name, Link and Open With, with each field's problem under it.
private struct QuicklinkSheet: View {
    struct Editing: Identifiable {
        let id = UUID()
        var draft: QuicklinkDraft
    }

    let model: SettingsModel
    @State var draft: QuicklinkDraft
    let done: () -> Void
    @State private var problems = QuicklinkDraft.Problems()
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.id == nil ? "New Quicklink" : "Edit Quicklink").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    field(TextField("", text: $draft.name, prompt: Text("Quicklink name")), problem: problems.name)
                }
                GridRow {
                    Text("Link")
                    VStack(alignment: .leading, spacing: 4) {
                        field(
                            TextField(
                                "", text: $draft.link, prompt: Text("https://example.com/search?q={argument}")),
                            problem: problems.link)
                        Text(QuicklinkForm.linkInfo).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Open With")
                    Picker("", selection: $draft.application) {
                        Text("Default").tag(String?.none)
                        Divider()
                        if let other = draft.application,
                            !model.quicklinkApplications.contains(where: { $0.bundleId == other })
                        {
                            Text(other).tag(String?.some(other))
                        }
                        ForEach(model.quicklinkApplications, id: \.bundleId) { app in
                            Text(app.name).tag(String?.some(app.bundleId))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
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
        .onChange(of: draft.link) { _, _ in problems.link = nil }
    }

    private func field(_ textField: TextField<Text>, problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            textField.textFieldStyle(.roundedBorder)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    private func save() {
        switch model.saveQuicklink(draft) {
        case .saved: done()
        case .problems(let found): problems = found
        case .failed(let message): failure = message
        }
    }
}
