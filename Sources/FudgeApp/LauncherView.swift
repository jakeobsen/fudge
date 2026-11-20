import FudgeCore
import SwiftUI

/// The launcher: a search field, the current screen, and a bar with the main action.
struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var focus: Field?

    enum Field { case search, actions }

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
        // The panel's hidden title bar would otherwise push everything down by its height.
        .ignoresSafeArea()
        .onAppear { focus = .search }
        .onChange(of: model.actionPanel == nil) { _, closed in focus = closed ? .search : .actions }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            if case .command = model.screen {
                Image(systemName: "chevron.left")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .semibold))
            }
            TextField(model.placeholder, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focus, equals: .search)
                .onSubmit { model.activate() }
                .onKeyPress(.upArrow) {
                    model.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.escape()
                    return .handled
                }
            if let command = model.command, let dropdown = command.list?.dropdown {
                SearchBarDropdownButton(
                    dropdown: dropdown,
                    value: model.dropdownValue,
                    openRequests: model.dropdownOpenRequests,
                    assets: command.assets,
                    onSelect: { model.selectDropdownValue($0) }
                )
                .fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    @ViewBuilder private var content: some View {
        switch model.screen {
        case .root:
            RootResults(model: model)
        case .command(let command):
            if let failure = command.failure {
                FailureView(failure: failure)
            } else if let list = command.list {
                ListScreen(model: model, command: command, list: list)
            } else if let view = command.view {
                CommandContent(view: view, assets: command.assets)
            } else {
                ProgressView().controlSize(.small)
            }
        case .failure(let failure):
            FailureView(failure: failure)
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
                KeyCap("↵")
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
        return "fudge"
    }

    private var primaryLabel: String? {
        switch model.screen {
        case .root:
            guard let item = model.results.first(where: { $0.id == model.selectedItem }) else { return nil }
            if case .application = item.kind { return "Open Application" }
            return "Open Command"
        case .command:
            return model.primaryAction?.title
        case .failure:
            return "Back"
        }
    }
}

private struct RootResults: View {
    let model: LauncherModel

    var body: some View {
        if model.results.isEmpty {
            Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.results) { item in
                            Row(
                                icon: Image(nsImage: model.icon(for: item)),
                                title: item.title,
                                subtitle: item.subtitle,
                                accessory: kind(of: item),
                                selected: item.id == model.selectedItem
                            )
                            .id(item.id)
                            .onTapGesture(count: 2) { model.open(item) }
                            .onTapGesture { model.selectedItem = item.id }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selectedItem) { _, id in proxy.scrollTo(id) }
            }
        }
    }

    private func kind(of item: RootItem) -> String {
        if case .application = item.kind { return "Application" }
        return "Command"
    }
}

/// A command's view other than a List. Details render simply here; their full look comes with later work.
private struct CommandContent: View {
    let view: UINode
    let assets: URL?

    var body: some View {
        switch view.type {
        case "Detail":
            ScrollView {
                MarkdownView(markdown: view.string("markdown") ?? "", assets: assets).padding(20)
            }
        default:
            Text("fudge can't show a \(view.type) yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Row: View {
    let icon: Image
    let title: String
    let subtitle: String?
    let accessory: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
            Text(title).lineLimit(1)
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
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
