import AppKit
import FudgeCore
import SwiftUI

/// The Settings window's Window Management page (SPEC-094): the custom positions, with + to add one, Edit… (or a
/// double-click) to change one and − to delete one, and the saved layouts, with Rename… and −. Each is a command in
/// the Window Management group, so its alias and hotkey are on the Commands page.
struct WindowManagementPage: View {
    @Bindable var model: SettingsModel
    @State private var positionSelection: CustomWindowPosition.ID?
    @State private var layoutSelection: SavedWindowLayout.ID?
    @State private var positionSheet: PositionSheet.Editing?
    @State private var renameSheet: LayoutRenameSheet.Editing?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.windowLayoutsUnreadable {
                Label(WindowLayoutStore.Unreadable().description, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            heading("Custom Positions", "Each one is a command that moves the front window there.")
            positions
            Divider()
            heading("Layouts", "Save one with Save Layout… in Fudge. “Apply” puts each app's windows back.")
            layouts
        }
        .disabled(model.windowLayoutsUnreadable)
        .onAppear { model.loadWindowLayouts() }
        .onChange(of: model.windowPositions.map(\.id)) { _, ids in
            if let selected = positionSelection, !ids.contains(selected) { positionSelection = nil }
        }
        .onChange(of: model.savedLayouts.map(\.id)) { _, ids in
            if let selected = layoutSelection, !ids.contains(selected) { layoutSelection = nil }
        }
        .sheet(item: $positionSheet) { editing in
            PositionSheet(model: model, draft: editing.draft) { positionSheet = nil }
        }
        .sheet(item: $renameSheet) { editing in
            LayoutRenameSheet(model: model, draft: editing.draft) { renameSheet = nil }
        }
        .overlay {
            // A snapshot run shows the sheet here, in the window, since it never begins a sheet.
            if let draft = model.snapshotPositionDraft {
                ZStack {
                    Color.black.opacity(0.15)
                    PositionSheet(model: model, draft: draft) {}
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 12)
                }
            }
        }
    }

    private func heading(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(explanation).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var positions: some View {
        VStack(spacing: 0) {
            Table(model.windowPositions, selection: $positionSelection) {
                TableColumn("Name", value: \.name)
                    .width(min: 120, ideal: 200, max: 280)
                TableColumn("Position") { position in
                    HStack(spacing: 8) {
                        PositionPreview(frame: position.frame).frame(width: 32, height: 20)
                        Text(Self.describe(position.frame)).foregroundStyle(.secondary)
                    }
                }
                .width(min: 200, ideal: 320)
            }
            .contextMenu(forSelectionType: CustomWindowPosition.ID.self) { ids in
                if let id = ids.first {
                    Button("Edit…") { editPosition(id) }
                    Button("Delete…", role: .destructive) { deletePosition(id) }
                }
            } primaryAction: { ids in
                if let id = ids.first { editPosition(id) }
            }
            .onDeleteCommand { if let positionSelection { deletePosition(positionSelection) } }
            Divider()
            HStack(spacing: 2) {
                Button {
                    positionSheet = .init(draft: PositionDraft())
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 18)
                }
                .help("Add a position")
                Button {
                    if let positionSelection { deletePosition(positionSelection) }
                } label: {
                    Image(systemName: "minus").frame(width: 20, height: 18)
                }
                .help("Delete the selected position")
                .disabled(positionSelection == nil)
                Spacer()
                Button("Edit…") { if let positionSelection { editPosition(positionSelection) } }
                    .disabled(positionSelection == nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var layouts: some View {
        VStack(spacing: 0) {
            Table(model.savedLayouts, selection: $layoutSelection) {
                TableColumn("Name", value: \.name)
                    .width(min: 120, ideal: 200, max: 280)
                TableColumn("Windows") { layout in
                    Text(LayoutDraft(renaming: layout).summary).foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Saved") { layout in
                    Text(Self.date(layout.createdAt)).foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 160)
            }
            .contextMenu(forSelectionType: SavedWindowLayout.ID.self) { ids in
                if let id = ids.first {
                    Button("Rename…") { renameLayout(id) }
                    Button("Delete…", role: .destructive) { deleteLayout(id) }
                }
            } primaryAction: { ids in
                if let id = ids.first { renameLayout(id) }
            }
            .onDeleteCommand { if let layoutSelection { deleteLayout(layoutSelection) } }
            Divider()
            HStack(spacing: 2) {
                Button {
                    if let layoutSelection { deleteLayout(layoutSelection) }
                } label: {
                    Image(systemName: "minus").frame(width: 20, height: 18)
                }
                .help("Delete the selected layout")
                .disabled(layoutSelection == nil)
                Spacer()
                Button("Rename…") { if let layoutSelection { renameLayout(layoutSelection) } }
                    .disabled(layoutSelection == nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    /// "x 0%, y 0%, 70% × 100%".
    static func describe(_ frame: WindowFractions) -> String {
        let draft = PositionDraft(editing: CustomWindowPosition(id: "", name: "", frame: frame))
        return "x \(draft.x)%, y \(draft.y)%, \(draft.width)% × \(draft.height)%"
    }

    static func date(_ iso: String?) -> String {
        guard let iso, let date = try? Date(iso, strategy: .iso8601) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func editPosition(_ id: CustomWindowPosition.ID) {
        guard let position = model.windowPositions.first(where: { $0.id == id }) else { return }
        positionSheet = .init(draft: PositionDraft(editing: position))
    }

    private func renameLayout(_ id: SavedWindowLayout.ID) {
        guard let layout = model.savedLayouts.first(where: { $0.id == id }) else { return }
        renameSheet = .init(draft: LayoutDraft(renaming: layout))
    }

    /// Asks in a sheet first, as the other pages do.
    private func deletePosition(_ id: CustomWindowPosition.ID) {
        guard !model.windowLayoutsUnreadable, let position = model.windowPositions.first(where: { $0.id == id }) else {
            return
        }
        let request = LauncherModel.AlertRequest(
            title: "Delete “\(position.name)”?", message: "Its command, alias and hotkey go too.", primary: "Delete",
            dismiss: "Cancel", destructive: true)
        Task {
            guard await model.confirm(request) else { return }
            model.deletePosition(id: id)
        }
    }

    private func deleteLayout(_ id: SavedWindowLayout.ID) {
        guard !model.windowLayoutsUnreadable, let layout = model.savedLayouts.first(where: { $0.id == id }) else {
            return
        }
        let request = LauncherModel.AlertRequest(
            title: "Delete “\(layout.name)”?", message: "Its command, alias and hotkey go too.", primary: "Delete",
            dismiss: "Cancel", destructive: true)
        Task {
            guard await model.confirm(request) else { return }
            model.deleteLayout(id: id)
        }
    }
}

/// A screen with a position drawn on it.
private struct PositionPreview: View {
    let frame: WindowFractions?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.5))
                if let frame {
                    let inset: CGFloat = 1.5
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(
                            width: max(1, (size.width - 2 * inset) * frame.width),
                            height: max(1, (size.height - 2 * inset) * frame.height)
                        )
                        .offset(
                            x: inset + (size.width - 2 * inset) * frame.x,
                            y: inset + (size.height - 2 * inset) * frame.y)
                }
            }
        }
    }
}

/// The sheet that adds or edits a custom position: Name, and X, Y, Width and Height as percentages of the screen's
/// visible area, with a drawing of where it goes.
private struct PositionSheet: View {
    struct Editing: Identifiable {
        let id = UUID()
        var draft: PositionDraft
    }

    let model: SettingsModel
    @State var draft: PositionDraft
    let done: () -> Void
    @State private var problems = PositionDraft.Problems()
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.id == nil ? "New Position" : "Edit Position").font(.headline)
            HStack(alignment: .top, spacing: 20) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Name").gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("", text: $draft.name, prompt: Text("Left 70%"))
                                .textFieldStyle(.roundedBorder)
                            if let problem = problems.name { Text(problem).font(.caption).foregroundStyle(.red) }
                        }
                        .gridCellColumns(3)
                    }
                    GridRow {
                        Text("X")
                        percent($draft.x)
                        Text("Y").gridColumnAlignment(.trailing)
                        percent($draft.y)
                    }
                    GridRow {
                        Text("Width")
                        percent($draft.width)
                        Text("Height")
                        percent($draft.height)
                    }
                    if let problem = problems.frame {
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            Text(problem).font(.caption).foregroundStyle(.red).gridCellColumns(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(spacing: 4) {
                    PositionPreview(frame: preview).frame(width: 160, height: 100)
                    Text("Percent of the screen, from its top left").font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: [draft.x, draft.y, draft.width, draft.height]) { _, _ in problems.frame = nil }
    }

    /// What the drawing shows: the values as typed, kept inside the screen, or nothing while they aren't numbers.
    private var preview: WindowFractions? {
        guard let frame = draft.fractions else { return nil }
        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
        let x = clamp(frame.x)
        let y = clamp(frame.y)
        return WindowFractions(
            x: x, y: y, width: min(clamp(frame.width), 1 - x), height: min(clamp(frame.height), 1 - y))
    }

    private func percent(_ value: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField("", text: value).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text("%").foregroundStyle(.secondary)
        }
    }

    private func save() {
        switch model.savePosition(draft) {
        case .saved: done()
        case .positionProblems(let found): problems = found
        case .nameProblem(let problem): problems.name = problem
        case .failed(let message): failure = message
        }
    }
}

/// The sheet that renames a layout.
private struct LayoutRenameSheet: View {
    struct Editing: Identifiable {
        let id = UUID()
        var draft: LayoutDraft
    }

    let model: SettingsModel
    @State var draft: LayoutDraft
    let done: () -> Void
    @State private var problem: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Layout").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $draft.name, prompt: Text("Layout name")).textFieldStyle(.roundedBorder)
                        if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    }
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
        .frame(width: 400)
        .onChange(of: draft.name) { _, _ in problem = nil }
    }

    private func save() {
        switch model.renameLayout(draft) {
        case .saved: done()
        case .nameProblem(let found): problem = found
        case .positionProblems: break
        case .failed(let message): failure = message
        }
    }
}
