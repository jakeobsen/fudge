import FudgeCore
import SwiftUI

/// A command's Form: a label column and the fields, as in Raycast.
struct FormScreen: View {
    let model: LauncherModel
    let form: FormContent
    @FocusState private var focused: Int?
    /// The DateTime field whose time box has the keyboard, if any: a Tab stop of its own, after the field's date.
    @FocusState private var timeBox: Int?

    var body: some View {
        ScrollViewReader { scroller in
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
            // Tab and ⇧Tab, which the launcher takes for every field and turns into the place to go
            // (`LauncherModel.moveInForm`). The field is scrolled into view too, since giving it the keyboard here
            // doesn't scroll as AppKit's key view loop would.
            .onChange(of: model.formMove) { _, move in
                guard let place = move.to else { return }
                give(place)
                scroller.scrollTo(place.field)
            }
        }
        .font(.system(size: 13))
        // Through `give`: the launcher swaps its search field for the form's title in the same update, and the
        // search field going away would take the keyboard from a field given it at once (FUD-185). A form that comes
        // back from the sign-in prompt, which took its place on screen, gets the place it was last in, a time box
        // included; any other starts in its first field.
        .onAppear {
            if let place = KeyboardFocus.formPlaceOnAppear(
                last: model.command?.formKeyboard.last, fields: tabFields, autoFocus: form.autoFocusID,
                overlayOpen: overlayHoldsKeyboard)
            {
                give(place)
            }
        }
        // Fields that arrive after the form (loaded text, a remounted field) take focus if nothing has it, unless an
        // overlay holds the keyboard: then they take it when the overlay closes.
        .onChange(of: editableIDs) { _, ids in
            if let field = KeyboardFocus.formFieldAfterFieldsChange(
                focused: focused, editable: ids, first: firstField, overlayOpen: overlayHoldsKeyboard)
            {
                focused = field
            }
        }
        // The model hears every move, nowhere included, so Tab goes on from where the keyboard is now.
        .onChange(of: focused) { _, field in
            model.formKeyboardMoved(to: place)
            // Another field took the keyboard: a DatePicker's calendar closes.
            if let field, let open = model.datePanel?.node, open != field { model.closeDatePanel() }
        }
        .onChange(of: timeBox) { _, _ in model.formKeyboardMoved(to: place) }
        // A time box that had the keyboard went (its date was cleared): its field takes it, unless an overlay holds
        // it. `onBlur` and `onFocus` don't fire, since a time box counts as its field. SwiftUI doesn't report the
        // time box's focus going with it, so that's cleared first, or `place` would still name the time box.
        .onChange(of: tabFields) { _, fields in
            guard let keyboard = model.command?.formKeyboard,
                let field = KeyboardFocus.formFieldAfterTimeBoxGone(
                    keyboard: keyboard, fields: fields, overlayOpen: overlayHoldsKeyboard)
            else { return }
            timeBox = nil
            give(.field(field))
        }
        // Each showing of the panel puts the keyboard back in the place the model names (the last one, or the first
        // field). Through nil, since setting what `focused` already says does nothing.
        .onChange(of: model.keyboardRequests) { _, _ in
            switch model.keyboardTarget {
            case .formField(let field): give(.field(field))
            case .formTimeBox(let field): give(.timeBox(field))
            default: break
            }
        }
        // The action panel takes the keyboard; give it back to the place it came from after, a time box included.
        .onChange(of: model.actionPanel == nil) { _, closed in
            if closed, let place = placeAfterOverlay { give(place) }
        }
        // An Action.PickDate picker has no field of its own to take the keyboard (its keys come through the
        // launcher's key monitor), so the field or time box lets go of it here, or ⌘V and ⌥⌫ would still edit it. It
        // comes back when the overlay closes, above.
        .onChange(of: model.actionPanel?.pick != nil) { _, open in
            if open {
                focused = nil
                timeBox = nil
            }
        }
        // So does a Dropdown's or TagPicker's panel. The launcher view moves its own focus as the panel closes, so
        // this goes after it, through nil.
        .onChange(of: model.dropdownPanel == nil) { _, closed in
            guard closed, let place = placeAfterOverlay else { return }
            give(place)
        }
    }

    private var editableIDs: [Int] { form.editableIDs }

    /// The editable fields as Tab sees them now: whether each shows a time box goes by its value.
    private var tabFields: [KeyboardFocus.TabField] { form.tabFields { model.fieldValue($0) } }

    /// The field the form starts in: the first with `autoFocus`, else the first.
    private var firstField: Int? {
        KeyboardFocus.formFieldOnAppear(editable: editableIDs, first: form.autoFocusID, overlayOpen: false)
    }

    /// Where the keyboard is now: a field, a DateTime field's time box, or nowhere.
    private var place: KeyboardFocus.FormStop? {
        timeBox.map(KeyboardFocus.FormStop.timeBox) ?? focused.map(KeyboardFocus.FormStop.field)
    }

    /// Gives `place` the keyboard, as `refocus` does.
    private func give(_ place: KeyboardFocus.FormStop) {
        switch place {
        case .field(let field): refocus(field)
        case .timeBox(let field):
            timeBox = nil
            DispatchQueue.main.async {
                if !overlayHoldsKeyboard { timeBox = field }
            }
        }
    }

    /// The action panel (with or without an Action.PickDate picker in it) or a dropdown's panel has the keyboard: no
    /// field takes it until that closes.
    private var overlayHoldsKeyboard: Bool {
        model.actionPanel != nil || model.dropdownPanel != nil
    }

    /// The place that takes the keyboard back when an overlay closes: the one the model says it was last in, a time
    /// box while its field still shows one, or the first field if that's gone.
    private var placeAfterOverlay: KeyboardFocus.FormStop? {
        KeyboardFocus.formPlaceAfterOverlay(
            last: model.command?.formKeyboard.last, fields: tabFields, first: firstField)
    }

    /// Gives `field` the keyboard through nil, since setting what `focused` already says does nothing. That lands a
    /// turn later, so it's skipped if an overlay has taken the keyboard meanwhile (⌘K or an Action.PickDate's
    /// shortcut pressed as the panel shows).
    private func refocus(_ field: Int) {
        focused = nil
        DispatchQueue.main.async {
            if !overlayHoldsKeyboard { focused = field }
        }
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
                .id(field.id)
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
            // Focusable for editing, as the pickers are, so it can take the keyboard with macOS's Keyboard navigation
            // off (the default): asked for without it, the keyboard lands in the first text field instead.
            Toggle(field.text ?? "", isOn: bool(field))
                .toggleStyle(.checkbox)
                .focusable(true, interactions: .edit)
                .focused($focused, equals: field.id)
                .onKeyPress(.space) {
                    bool(field).wrappedValue.toggle()
                    return .handled
                }
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
            FormDateField(model: model, field: field, focused: $focused, timeBox: $timeBox)
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
    var timeBox: FocusState<Int?>.Binding

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
            if let date, field.showsTimeBox(value: model.fieldValue(field.id)) {
                DatePicker(
                    "",
                    selection: Binding(get: { date }, set: { model.pickDate($0, for: field.id) }),
                    in: options.range,
                    displayedComponents: [.hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .fixedSize()
                .focused(timeBox, equals: field.id)
                // The time box takes the keys from here, so the calendar closes.
                .onChange(of: timeBox.wrappedValue == field.id) { _, now in
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
