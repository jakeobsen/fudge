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
                // Another field took the keyboard: a DatePicker's calendar closes.
                if let open = model.datePanel?.node, open != field { model.closeDatePanel() }
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
        // An Action.PickDate picker has no field of its own to take the keyboard (its keys come through the
        // launcher's key monitor), so the field lets go of it here, or ⌘V and ⌥⌫ would still edit it. It comes back
        // when the overlay closes, above.
        .onChange(of: model.actionPanel?.pick != nil) { _, open in
            if open { focused = nil }
        }
        // So does a Dropdown's or TagPicker's panel. The launcher view moves its own focus as the panel closes, so
        // this goes after it, through nil.
        .onChange(of: model.dropdownPanel == nil) { _, closed in
            guard closed, let field = lastFocused else { return }
            focused = nil
            DispatchQueue.main.async { focused = field }
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
        case .dropdown:
            FormDropdownField(model: model, field: field, isFocused: focused == field.id)
                .focusable(true, interactions: .edit)
                .focusEffectDisabled()
                .focused($focused, equals: field.id)
                .onKeyPress(keys: [.space, .return]) { _ in
                    model.openFormDropdown(field.id)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.stepFormDropdown(field.id, by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.stepFormDropdown(field.id, by: 1)
                    return .handled
                }
                .onTapGesture {
                    focused = field.id
                    model.openFormDropdown(field.id)
                }
                .anchorPreference(key: FormFieldBounds.self, value: .bounds) { [field.id: $0] }
        case .tagPicker:
            TagPickerField(model: model, field: field, isFocused: focused == field.id)
                .focusable(true, interactions: .edit)
                .focusEffectDisabled()
                .focused($focused, equals: field.id)
                .onKeyPress(keys: [.space, .return]) { _ in
                    model.openTagPicker(field.id)
                    return .handled
                }
                .onKeyPress(.delete) {
                    if let last = TagPicking.values(model.fieldValue(field.id)).last {
                        model.removeTag(last, from: field.id)
                    }
                    return .handled
                }
                // Typing starts the search for an item.
                .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters)) { press in
                    model.openTagPicker(field.id, typing: press.characters)
                    return .handled
                }
                .onTapGesture {
                    focused = field.id
                    model.openTagPicker(field.id)
                }
                .anchorPreference(key: FormFieldBounds.self, value: .bounds) { [field.id: $0] }
        case .datePicker:
            FormDateField(model: model, field: field, focused: $focused)
        case .filePicker:
            FilePickerField(model: model, field: field, isFocused: focused == field.id)
                .focusable(true, interactions: .edit)
                .focusEffectDisabled()
                .focused($focused, equals: field.id)
                .onKeyPress(keys: [.space, .return]) { _ in
                    Task { await model.chooseFiles(for: field.id) }
                    return .handled
                }
                .onTapGesture { focused = field.id }
        case .unsupported(let type):
            Text("Fudge can't show a \(type) yet.").foregroundStyle(.tertiary)
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

/// Where each Form field is drawn, so its Dropdown or TagPicker panel can open under it (`LauncherView`).
struct FormFieldBounds: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The look shared by the Dropdown and TagPicker fields: a rounded box, outlined while it has the keyboard.
private struct FieldBox: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.12),
                    lineWidth: isFocused ? 2 : 1)
            )
            .contentShape(Rectangle())
    }
}

/// A Form.Dropdown: the chosen item's icon and title, opening a searchable list under it.
private struct FormDropdownField: View {
    let model: LauncherModel
    let field: FormContent.Field
    let isFocused: Bool

    var body: some View {
        let current: SearchBarDropdown.Item? =
            if case .string(let value) = model.fieldValue(field.id) {
                field.options?.items.first { $0.value == value }
            } else { nil }
        HStack(spacing: 6) {
            if let current {
                ExtensionImage(source: current.icon, assets: model.command?.assets, size: 14)
                Text(current.title).lineLimit(1)
            } else {
                Text(field.placeholder ?? "Select…").foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if field.options?.isLoading == true { ProgressView().controlSize(.mini) }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .modifier(FieldBox(isFocused: isFocused))
    }
}

/// A Form.TagPicker: the chosen items as tokens with a ×, opening a list of the others to pick from.
private struct TagPickerField: View {
    let model: LauncherModel
    let field: FormContent.Field
    let isFocused: Bool

    var body: some View {
        let chosen = TagPicking.values(model.fieldValue(field.id)).compactMap { value in
            field.tags.first { $0.value == value }
        }
        FlowLayout(spacing: 4) {
            ForEach(chosen) { tag in
                HStack(spacing: 4) {
                    ExtensionImage(source: tag.icon, assets: model.command?.assets, size: 12)
                    Text(tag.title).lineLimit(1)
                    Button {
                        model.removeTag(tag.value, from: field.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove \(tag.title)")
                }
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            if chosen.isEmpty {
                Text(field.placeholder ?? "Add…").foregroundStyle(.tertiary).frame(height: 20)
            }
        }
        .padding(.vertical, 3)
        .modifier(FieldBox(isFocused: isFocused))
    }
}

/// A Form.DatePicker: the date, with a `DateTime`'s time beside it to edit in place, and a button that clears it.
/// Space, ↵ or a click opens its calendar under it (`DatePanelView`), which picks nothing until a day is chosen;
/// ⌫ clears it.
private struct FormDateField: View {
    let model: LauncherModel
    let field: FormContent.Field
    var focused: FocusState<Int?>.Binding
    @FocusState private var timeFocused: Bool

    var body: some View {
        let options = field.dates ?? DatePickerOptions()
        let date = FormDates.date(model.fieldValue(field.id))
        let isOpen = model.datePanel?.node == field.id
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                if let date {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                        .lineLimit(1)
                } else {
                    Text(field.placeholder ?? "No date").foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .modifier(FieldBox(isFocused: focused.wrappedValue == field.id || isOpen))
            .focusable(true, interactions: .edit)
            .focusEffectDisabled()
            .focused(focused, equals: field.id)
            .onKeyPress(keys: [.space, .return]) { _ in
                model.openDatePanel(field.id)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                model.pickDate(nil, for: field.id)
                return .handled
            }
            .onTapGesture {
                focused.wrappedValue = field.id
                if isOpen { model.closeDatePanel() } else { model.openDatePanel(field.id) }
            }
            .anchorPreference(key: FormFieldBounds.self, value: .bounds) { [field.id: $0] }
            if let date, options.type == .dateTime {
                DatePicker(
                    "",
                    selection: Binding(get: { date }, set: { model.pickDate($0, for: field.id) }),
                    in: options.range,
                    displayedComponents: [.hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .fixedSize()
                .focused($timeFocused)
                // The time box takes the keys from here, so the calendar closes.
                .onChange(of: timeFocused) { _, now in
                    if now, isOpen { model.closeDatePanel() }
                }
            }
            if date != nil {
                Button {
                    model.pickDate(nil, for: field.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear (⌫)")
            }
        }
    }
}

/// A Form.DatePicker's calendar, under its field: the month, its weeks and the highlighted day. A click on a day
/// picks it. The keys (←→↑↓, ⇞⇟, ↵, Esc) go through `LauncherModel.handleKey`, since the field keeps the keyboard.
struct DatePanelView: View {
    let model: LauncherModel
    /// Its height with the margin under or over the field: the header, the weekdays and six weeks, padded.
    static let height: CGFloat = 236

    var body: some View {
        if let panel = model.datePanel {
            MonthView(
                month: panel.calendar, move: { model.moveDatePanel(months: $0) },
                pick: { model.pickDatePanelDay($0) }
            )
            .padding(10)
            .fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }
}

/// A `DateCalendar`'s month: its name with arrows to the previous and next month (⇞⇟), the weekdays, and six weeks
/// with the highlighted day and today marked. Days outside `min` and `max` are dimmed. Form.DatePicker's calendar and
/// Action.PickDate's picker both draw it.
struct MonthView: View {
    let month: DateCalendar
    let move: (Int) -> Void
    let pick: (Date) -> Void

    var body: some View {
        let calendar = Calendar.current
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(month.day.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    move(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous month (⇞)")
                Button {
                    move(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next month (⇟)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(DateCalendar.weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                        Text(symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 30, height: 18)
                    }
                }
                ForEach(Array(month.weeks().enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(week) { day in
                            // By the day, not the instant: where DST starts at midnight, a day starts at 1:00.
                            cell(
                                day, highlighted: calendar.isDate(day.date, inSameDayAs: month.day),
                                today: calendar.isDateInToday(day.date))
                        }
                    }
                }
            }
        }
    }

    private func cell(_ day: DateCalendar.Day, highlighted: Bool, today: Bool) -> some View {
        Text("\(day.number)")
            .font(.system(size: 12, weight: today ? .bold : .regular))
            .foregroundStyle(
                highlighted
                    ? AnyShapeStyle(.white)
                    : !day.isPickable
                        ? AnyShapeStyle(.quaternary)
                        : day.inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
            )
            .frame(width: 30, height: 26)
            .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if today && !highlighted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { pick(day.date) }
    }
}

/// A Form.FilePicker: the chosen files and folders (icon and name, the path as a tooltip), each with a ×, and a
/// Select… button that opens the open panel as a sheet on the launcher.
private struct FilePickerField: View {
    let model: LauncherModel
    let field: FormContent.Field
    let isFocused: Bool

    var body: some View {
        let paths = TagPicking.values(model.fieldValue(field.id))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(paths, id: \.self) { path in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
                    Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        model.removeFile(path, from: field.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                }
                .help(path)
            }
            Button("Select…") { Task { await model.chooseFiles(for: field.id) } }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .modifier(FieldBox(isFocused: isFocused))
    }
}

/// Lays its views out in rows, wrapping to the next row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for (index, x) in row.items {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows.removeLast()
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                let next = Row(y: row.y + row.height + spacing)
                rows.append(row)
                row = next
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows.append(row)
        }
        return rows
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
