import FudgeCore
import SwiftUI

/// The launcher: a search field, the current screen, and a bar with the main action.
struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case search, actions, dropdown
        case argument(Int)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if model.isLoading { LoadingBar() } else { Divider() }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if model.actionPanel != nil {
                ActionPanelView(model: model, focus: $focus)
                    .padding(.trailing, 10)
                    .padding(.bottom, 46)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.dropdownPanel?.source == .searchBar, let command = model.command, command.list?.dropdown != nil {
                DropdownPanelView(model: model, assets: command.assets, focus: $focus)
                    .padding(.trailing, 14)
                    .padding(.top, 50)
            }
        }
        // A Form field's panel (a Dropdown's or TagPicker's list, a DatePicker's calendar) opens under the field, or
        // above it when there's no room below.
        .overlayPreferenceValue(FormFieldBounds.self) { bounds in
            if let node = model.formPanelField ?? model.datePanel?.node, let anchor = bounds[node],
                let command = model.command
            {
                GeometryReader { proxy in
                    let field = proxy[anchor]
                    let x = max(8, min(field.minX, proxy.size.width - 288))
                    let panel = formPanel(assets: command.assets)
                    let below = proxy.size.height - field.maxY
                    // The calendar has a fixed height, so it opens where it fits; a Dropdown's list can shrink.
                    let opensBelow =
                        model.datePanel != nil
                        ? PanelPlacement.opensBelow(
                            spaceBelow: below, spaceAbove: field.minY, height: DatePanelView.height)
                        : below >= 260
                    if opensBelow {
                        panel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.leading, x).padding(.top, field.maxY + 4)
                    } else {
                        panel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(.leading, x).padding(.bottom, proxy.size.height - field.minY + 4)
                    }
                }
            }
        }
        // The panel's hidden title bar would otherwise push everything down by its height.
        .ignoresSafeArea()
        .onAppear { focus = .search }
        // `.onAppear` runs once for the panel's lifetime, so each showing (and each row click) asks for the
        // keyboard back explicitly.
        .onChange(of: model.keyboardRequests) { _, _ in restoreKeyboard() }
        .onChange(of: model.actionPanel == nil) { _, closed in focus = closed ? .search : .actions }
        .onChange(of: model.dropdownPanel == nil) { _, closed in focus = closed ? .search : .dropdown }
        // The model decides which argument field has the keyboard (Tab, ⇧Tab, a required one left empty); a click
        // into a field tells it.
        .onChange(of: model.arguments.focus) { _, index in
            let field = argumentField(index)
            focus = field
            if field == nil {
                // A dropdown argument: no text field may keep the keyboard, or typing would go into it.
                launcherPanel?.makeFirstResponder(nil)
            } else {
                placeCursorAtEnd(of: index.map { model.arguments.value(at: $0) } ?? model.searchText)
            }
        }
        .onChange(of: focus) { _, field in
            switch field {
            case .search: model.focusArgument(nil)
            case .argument(let index): model.focusArgument(index)
            default: break
            }
        }
    }

    /// Where the keyboard goes for an argument (nil: the search field). A dropdown argument takes no text, so no
    /// field has it then, and the launcher's key handling gives it ↑↓.
    private func argumentField(_ index: Int?) -> Field? {
        guard let index else { return .search }
        guard model.arguments.arguments.indices.contains(index) else { return .search }
        return model.arguments.arguments[index].type == "dropdown" ? nil : .argument(index)
    }

    /// AppKit selects all of a field's text when it takes the keyboard, so the next key would replace the query.
    /// Moving between the query and the arguments puts the cursor at the end instead, as Raycast does. SwiftUI
    /// moves the keyboard a moment later, and the fields share one field editor, so this waits until the editor
    /// holds `text`, all selected.
    private func placeCursorAtEnd(of text: String, attempts: Int = 20) {
        guard !text.isEmpty, attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            let length = (text as NSString).length
            if let editor = launcherPanel?.firstResponder as? NSTextView, editor.string == text,
                editor.selectedRange() == NSRange(location: 0, length: length)
            {
                editor.setSelectedRange(NSRange(location: length, length: 0))
            } else {
                placeCursorAtEnd(of: text, attempts: attempts - 1)
            }
        }
    }

    /// Puts the keyboard in the field the screen wants (`LauncherModel.keyboardTarget`), unless it's already there,
    /// with the cursor at the end. Setting `focus` to the value it already holds does nothing, even when AppKit's
    /// first responder has moved elsewhere, so it goes through nil first. Form fields are `FormScreen`'s.
    /// The panel of the Form field whose panel is open: a DatePicker's calendar, or the dropdown panel.
    @ViewBuilder private func formPanel(assets: URL?) -> some View {
        if model.datePanel != nil {
            DatePanelView(model: model)
        } else {
            DropdownPanelView(model: model, assets: assets, focus: $focus)
        }
    }

    private func restoreKeyboard() {
        let field: Field
        let text: String
        switch model.keyboardTarget {
        case .search: (field, text) = (.search, model.searchText)
        case .argument(let index): (field, text) = (.argument(index), model.arguments.value(at: index))
        case .actionPanel: (field, text) = (.actions, model.actionPanelQuery)
        case .dropdownPanel: (field, text) = (.dropdown, model.dropdownPanelQuery)
        case .formField, .none: return
        }
        if focus == field, let editor = launcherPanel?.firstResponder as? NSTextView, editor.string == text { return }
        focus = nil
        DispatchQueue.main.async {
            focus = field
            placeCursorAtEnd(of: text)
        }
    }

    /// The panel this view is in. Not NSApp.keyWindow: the panel doesn't activate fudge, and that's nil while fudge
    /// isn't the active app.
    private var launcherPanel: NSWindow? {
        NSApp.windows.first { $0 is LauncherPanel }
    }

    /// Root search shows the selected command's argument fields after the query.
    private var showsArguments: Bool {
        if case .root = model.screen { return !model.arguments.isEmpty }
        return false
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            if case .command = model.screen {
                Image(systemName: "chevron.left")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .semibold))
            }
            if let title = model.viewTitle {
                // Detail and Form have no search field; their title takes its place.
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                searchField
                if showsArguments, let item = model.selectedRootItem {
                    Image(nsImage: model.icon(for: item))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                    let generation = model.argumentsGeneration
                    ForEach(Array(model.arguments.arguments.enumerated()), id: \.offset) { index, argument in
                        ArgumentField(
                            model: model, generation: generation, index: index, argument: argument, focus: $focus
                        )
                        // New fields when the arguments start over, so the old ones' late writes go nowhere.
                        .id("\(generation).\(index)")
                    }
                    Spacer(minLength: 0)
                }
            }
            if let command = model.command, let dropdown = command.list?.dropdown {
                SearchBarDropdownButton(model: model, dropdown: dropdown, assets: command.assets)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    /// The search field. With argument fields after it, it's only as wide as its text, so they follow the query,
    /// and it's what gives way when the bar is full. It's the same view either way, so it keeps the keyboard when
    /// the fields come and go.
    private var searchField: some View {
        let text = model.searchText.isEmpty ? model.placeholder : model.searchText
        // A hidden copy of the text sets the width: its ideal width, or less when that doesn't fit.
        return Text(verbatim: text)
            .font(.system(size: 20))
            .lineLimit(1)
            .padding(.trailing, showsArguments ? 6 : 0)
            .hidden()
            .frame(maxWidth: showsArguments ? nil : .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                TextField(model.placeholder, text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focus, equals: .search)
                    .onSubmit { model.activate() }
                    // While an input method is composing, ↑↓ pick its candidates, as the key monitor leaves them.
                    .onKeyPress(.upArrow) {
                        guard !composing else { return .ignored }
                        model.moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !composing else { return .ignored }
                        model.moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                        gridArrow(press)
                    }
                    .onKeyPress(.escape) {
                        model.escape()
                        return .handled
                    }
            }
            // Offered the whole width first, less what the fixed-size argument fields need.
            .layoutPriority(1)
    }

    /// ← and → in a Grid move the selection when `GridNavigation.arrowMovesSelection` says so: with the field
    /// empty or its cursor at the end, and no ⇧, ⌥, ⌘ or ⌃. Otherwise the field keeps them, and while an input
    /// method is composing, it does.
    private func gridArrow(_ press: KeyPress) -> KeyPress.Result {
        let editor = fieldEditor
        let range = editor?.selectedRange()
        let length = editor?.string.utf16.count ?? model.searchText.utf16.count
        let move: GridNavigation.Move = press.key == .leftArrow ? .left : .right
        return model.moveGridSelection(
            move, modifiers: Self.names(press.modifiers), composing: editor?.hasMarkedText() == true,
            textLength: length, selection: range.map { ($0.location, $0.length) }) ? .handled : .ignored
    }

    /// The search field's editor, which holds the cursor and any marked text. The panel isn't always the key window,
    /// so it's found by type.
    private var fieldEditor: NSTextView? {
        NSApp.windows.first { $0 is LauncherPanel }?.firstResponder as? NSTextView
    }

    /// Whether an input method is composing in the search field (marked text). Its keys are its own then.
    private var composing: Bool {
        fieldEditor?.hasMarkedText() == true
    }

    /// A key press's modifiers, named as `KeyShortcut` names them. `fn`, `numpad` and `capslock` are passed on too,
    /// for the rules to ignore: arrow keys always carry the first two.
    private static func names(_ modifiers: EventModifiers) -> Set<String> {
        let all: [(EventModifiers, String)] = [
            (.shift, "shift"), (.option, "opt"), (.command, "cmd"), (.control, "ctrl"), (.function, "fn"),
            (.numericPad, "numpad"), (.capsLock, "capslock"),
        ]
        return Set(all.filter { modifiers.contains($0.0) }.map(\.1))
    }

    @ViewBuilder private var content: some View {
        switch model.screen {
        case .root:
            RootResults(model: model)
        case .command(let command):
            if let failure = command.failure {
                FailureView(failure: failure)
            } else if let list = command.list, case .grid = list.layout {
                GridScreen(model: model, command: command, list: list)
            } else if let list = command.list {
                ListScreen(model: model, command: command, list: list)
            } else if let form = command.form {
                FormScreen(model: model, form: form)
            } else if let view = command.view, view.type == "Detail" {
                DetailScreen(model: model, view: view, assets: command.assets)
            } else if let view = command.view {
                Text("Fudge can't show a \(view.type) yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
            }
        case .failure(let failure):
            if failure.notice != nil {
                NoticeView(title: failure.title)
            } else {
                FailureView(failure: failure)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let toast = model.toast {
                ToastView(toast: toast).onTapGesture { model.runToastAction() }
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16)
                Text(model.status ?? screenTitle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let label = primaryLabel {
                Text(label).foregroundStyle(.primary)
                KeyCap(model.command == nil ? "↵" : model.primaryKey.description)
            }
            if !model.currentActions.isEmpty {
                Divider().frame(height: 16)
                Button {
                    model.toggleActionPanel()
                } label: {
                    HStack(spacing: 6) {
                        Text("Actions")
                        KeyCap("⌘K")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var screenTitle: String {
        if case .command(let command) = model.screen {
            return command.view?.string("navigationTitle") ?? command.title
        }
        return "Fudge"
    }

    private var primaryLabel: String? {
        switch model.screen {
        case .root, .command:
            return model.primaryAction?.title
        case .failure:
            return model.primaryAction?.title ?? "Back"
        }
    }
}

private struct RootResults: View {
    let model: LauncherModel

    var body: some View {
        let rows = model.rootRows
        if rows.isEmpty {
            Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // In `RootSearch.rows`' order, which ↑↓ follows too.
                        ForEach(rows) { rootRow in
                            switch rootRow {
                            case .item(let item): row(item)
                            case .calculator: calculatorCard
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selectedItem) { _, id in proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private var calculatorCard: some View {
        if let calculator = model.calculator {
            Text("Calculator")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            CalculatorCard(result: calculator, selected: model.selectedItem == LauncherModel.calculatorID)
                .id(LauncherModel.calculatorID)
                .onRowClick(
                    select: {
                        model.selectedItem = LauncherModel.calculatorID
                        // A click can leave the first responder outside the search field.
                        model.restoreKeyboard()
                    },
                    open: { model.activate() }
                )
                .padding(.bottom, 6)
        }
    }

    private func row(_ item: RootItem) -> some View {
        Row(
            icon: Image(nsImage: model.icon(for: item)),
            title: item.title,
            subtitle: item.subtitle,
            accessory: kind(of: item),
            selected: item.id == model.selectedItem,
            alias: item.alias,
            hotkey: model.commandHotkeys[item.id]
        )
        .id(item.id)
        .onRowClick(
            select: {
                model.selectedItem = item.id
                // A click can leave the first responder outside the search field.
                model.restoreKeyboard()
            },
            open: { model.activate() })
    }

    private func kind(of item: RootItem) -> String {
        switch item.kind {
        case .application: "Application"
        case .command: "Command"
        case .settings, .reloadExtensions, .quit: "Fudge"
        }
    }
}

/// Root search's Calculator card: the question and the answer side by side, an arrow between them, and a label
/// under each.
private struct CalculatorCard: View {
    let result: CalculatorResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 0) {
            side(result.question, label: result.questionLabel, size: 24)
            // The dividing line, broken around the arrow, and stopping above the footnote.
            VStack(spacing: 10) {
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1)
                Image(systemName: "arrow.right").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1)
            }
            .padding(.bottom, result.footnote == nil ? 0 : 22)
            .frame(width: 32)
            side(result.answer, label: result.answerLabel, size: 28)
        }
        .frame(height: 118)
        // How fresh a currency conversion's rates are, small and grey under the arrow.
        .overlay(alignment: .bottom) {
            if let footnote = result.footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.primary.opacity(selected ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func side(_ text: String, label: String, size: CGFloat) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.system(size: size, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                // Both sides the same height, so the two labels line up.
                .frame(height: 38)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// A click selects the row at once; the second click of a double-click also opens it. A double-tap gesture
    /// beside a single-tap one would hold every single click until the double-click interval has passed.
    func onRowClick(select: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        onTapGesture {
            select()
            if NSApp.currentEvent?.clickCount == 2 { open() }
        }
    }
}

private struct Row: View {
    let icon: Image
    let title: String
    let subtitle: String?
    let accessory: String?
    let selected: Bool
    /// A command's alias, shown as an outlined tag after its title.
    var alias: String?
    /// A command's hotkey, shown as keycaps after its title.
    var hotkey: HotKeySpec?

    var body: some View {
        HStack(spacing: 10) {
            icon.resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
            Text(title).lineLimit(1)
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            if let alias {
                Text(alias)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6)))
            }
            if let hotkey { Keycaps(spec: hotkey).foregroundStyle(.secondary) }
            Spacer()
            if let accessory {
                Text(accessory).foregroundStyle(.secondary).font(.system(size: 12))
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

/// One of a command's arguments in the root search bar: a text or password field, or a dropdown, sized to its
/// placeholder or value. A required one left empty at ↵ is outlined in red until it gets a value.
private struct ArgumentField: View {
    @Bindable var model: LauncherModel
    let generation: Int
    let index: Int
    let argument: ExtensionManifest.Argument
    var focus: FocusState<LauncherView.Field?>.Binding

    private var placeholder: String { argument.placeholder ?? argument.name }
    private var value: String { model.arguments.value(at: index) }
    private var isFocused: Bool { model.arguments.focus == index }

    var body: some View {
        Group {
            if argument.type == "dropdown" {
                dropdown
            } else {
                textField
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(isFocused ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(
                model.arguments.missing == index ? Color.red : isFocused ? Color.accentColor.opacity(0.7) : .clear)
        )
        .help(argument.required == true ? "\(placeholder) (required)" : placeholder)
    }

    private var textField: some View {
        let binding = Binding(get: { value }, set: { model.setArgument($0, at: index, generation: generation) })
        let shown = argument.type == "password" ? String(repeating: "•", count: value.count) : value
        // Sized by a hidden copy of its text, so it grows as the user types, up to a limit that keeps three
        // fields and some of the query in the bar.
        return Text(verbatim: String((shown.count > placeholder.count ? shown : placeholder).prefix(18)))
            .lineLimit(1)
            .fixedSize()
            .padding(.trailing, 4)
            .hidden()
            .overlay(alignment: .leading) {
                Group {
                    if argument.type == "password" {
                        SecureField(placeholder, text: binding)
                    } else {
                        TextField(placeholder, text: binding)
                    }
                }
                .textFieldStyle(.plain)
                .focused(focus, equals: .argument(index))
                .onSubmit { model.activate() }
                // The keyboard may have been sent here before the field was on screen.
                .onAppear { if model.arguments.focus == index { focus.wrappedValue = .argument(index) } }
            }
    }

    private var dropdown: some View {
        let options = argument.data ?? []
        let title = options.first { $0.value == value }?.title
        return Menu {
            ForEach(options, id: \.value) { option in
                Button(option.title) {
                    model.setArgument(option.value, at: index, generation: generation)
                    model.focusArgument(index)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title ?? placeholder)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            // A menu's label ignores foregroundStyle, so the placeholder is dimmed this way.
            .opacity(title == nil ? 0.5 : 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A notice in place of a command, drawn as a List's empty view is: the Extension Store's "off" view.
private struct NoticeView: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let failure: LauncherModel.Failure

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                Text(failure.message).textSelection(.enabled)
                if let details = failure.details {
                    Text(details)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

/// The ⌘K panel: the actions for what's selected, searchable, with their shortcuts.
private struct ActionPanelView: View {
    @Bindable var model: LauncherModel
    var focus: FocusState<LauncherView.Field?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.actionPanelSections.enumerated()), id: \.offset) { index, section in
                            if let title = section.title {
                                Text(title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, index == 0 ? 2 : 8)
                            } else if index > 0 {
                                Divider().padding(.vertical, 4)
                            }
                            ForEach(section.entries) { entry in
                                ActionRow(entry: entry, selected: entry.id == model.actionPanel?.selected)
                                    .id(entry.id)
                                    .onTapGesture { model.run(entry) }
                            }
                        }
                        if model.actionPanelSections.isEmpty {
                            Text("No actions").foregroundStyle(.secondary).padding(8)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.actionPanel?.selected) { _, id in proxy.scrollTo(id) }
            }
            .frame(maxHeight: 280)
            Divider()
            TextField("Search for actions…", text: $model.actionPanelQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus, equals: .actions)
                .onSubmit { model.runSelectedAction() }
                .onKeyPress(.upArrow) {
                    model.moveActionSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveActionSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.escape()
                    return .handled
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

private struct ActionRow: View {
    let entry: ActionEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.title)
                .foregroundStyle(entry.destructive ? Color.red : Color.primary)
                .lineLimit(1)
            Spacer()
            if entry.isLoading {
                ProgressView().controlSize(.mini)
            }
            if let shortcut = entry.shortcut {
                KeyCap(shortcut.description)
            }
            if entry.isSubmenu {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                    .secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// A toast in the bottom bar: the style's mark, the title, the message, and the primary action's name.
private struct ToastView: View {
    let toast: LauncherModel.ToastState

    var body: some View {
        HStack(spacing: 6) {
            switch toast.style {
            case "ANIMATED":
                ProgressView().controlSize(.mini)
            case "FAILURE":
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            default:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(toast.title).fontWeight(.medium).lineLimit(1)
            if let message = toast.message {
                Text(message).foregroundStyle(.secondary).lineLimit(1)
            }
            if let action = toast.primaryAction {
                Text("· \(action)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .help(toast.primaryAction.map { "Click to \($0)" } ?? "")
    }
}

private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}
