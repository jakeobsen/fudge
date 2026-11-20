import FudgeCore
import SwiftUI

/// A command's Form: a label column and the fields, as in Raycast.
struct FormScreen: View {
    let model: LauncherModel
    let form: FormContent
    @FocusState private var focused: Int?
    @State private var lastFocused: Int?

    var body: some View {
        ScrollView {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
                ForEach(form.fields) { field in
                    row(field)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .onAppear { focusFirstField() }
        // Fields that arrive after the form (loaded text, a remounted field) take focus if nothing has it.
        .onChange(of: form.fields.filter(\.isEditable).map(\.id)) { _, ids in
            if focused == nil || !ids.contains(focused!) { focusFirstField() }
        }
        .onChange(of: focused) { _, field in
            if let field {
                lastFocused = field
                model.formFieldFocused(field)
            }
        }
        // Each showing of the panel puts the keyboard back in the field the model names (the last one, or the
        // first). Through nil, since setting what `focused` already says does nothing.
        .onChange(of: model.keyboardRequests) { _, _ in
            guard case .formField(let field) = model.keyboardTarget else { return }
            focused = nil
            DispatchQueue.main.async { focused = field }
        }
        // The action panel takes the keyboard; give it back to the field after.
        .onChange(of: model.actionPanel == nil) { _, closed in
            if closed { focused = lastFocused }
        }
    }

    private func focusFirstField() {
        let editable = form.fields.filter(\.isEditable)
        focused = (editable.first(where: \.autoFocus) ?? editable.first)?.id
    }

    @ViewBuilder private func row(_ field: FormContent.Field) -> some View {
        switch field.kind {
        case .separator:
            GridRow {
                Divider().gridCellColumns(2)
            }
        case .description:
            GridRow {
                label(field)
                Text(field.text ?? "")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            GridRow {
                label(field)
                VStack(alignment: .leading, spacing: 4) {
                    control(field)
                    if let error = field.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func label(_ field: FormContent.Field) -> some View {
        HStack(spacing: 4) {
            Text(field.title ?? "").foregroundStyle(.secondary)
            if let info = field.info {
                Image(systemName: "info.circle").foregroundStyle(.tertiary).help(info)
            }
        }
        .frame(width: 150, alignment: .trailing)
        .padding(.top, field.kind == .checkbox ? 0 : 4)
        .gridColumnAlignment(.trailing)
    }

    @ViewBuilder private func control(_ field: FormContent.Field) -> some View {
        switch field.kind {
        case .textField:
            TextField(field.placeholder ?? "", text: text(field))
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: field.id)
        case .passwordField:
            SecureField(field.placeholder ?? "", text: text(field))
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: field.id)
        case .textArea:
            TextEditor(text: text(field))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 90, maxHeight: 240)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(alignment: .topLeading) {
                    if case .string(let current) = model.fieldValue(field.id), current.isEmpty,
                        let placeholder = field.placeholder
                    {
                        Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .focused($focused, equals: field.id)
        case .checkbox:
            Toggle(field.text ?? "", isOn: bool(field))
                .toggleStyle(.checkbox)
                .focused($focused, equals: field.id)
        case .unsupported(let type):
            Text("fudge can't show a \(type) yet.").foregroundStyle(.tertiary)
        case .description, .separator:
            EmptyView()
        }
    }

    private func text(_ field: FormContent.Field) -> Binding<String> {
        Binding(
            get: {
                if case .string(let value) = model.fieldValue(field.id) { return value }
                return ""
            },
            set: { model.edit(field: field.id, to: .string($0)) }
        )
    }

    private func bool(_ field: FormContent.Field) -> Binding<Bool> {
        Binding(
            get: { model.fieldValue(field.id) == .bool(true) },
            set: { model.edit(field: field.id, to: .bool($0)) }
        )
    }
}

/// A command's Detail: its markdown, with its metadata in a column on the right.
struct DetailScreen: View {
    let model: LauncherModel
    let view: UINode
    let assets: URL?

    var body: some View {
        let metadata = MetadataEntry.entries(of: view.node("metadata"))
        HStack(spacing: 0) {
            ScrollView {
                MarkdownView(markdown: view.string("markdown") ?? "", assets: assets).padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !metadata.isEmpty {
                Divider()
                ScrollView {
                    MetadataView(
                        entries: metadata, assets: assets, layout: .stacked,
                        onTag: { model.call(node: $0, ["onAction"]) }
                    )
                    .padding(16)
                }
                .frame(width: 250)
            }
        }
    }
}
