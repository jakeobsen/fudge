import FudgeCore
import SwiftUI

/// The launcher: a search field, the current screen, and a bar with the main action.
struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel's hidden title bar would otherwise push everything down by its height.
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
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
                .focused($searchFocused)
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
            } else if let view = command.view {
                CommandContent(view: view, rows: model.commandItems, selected: command.selectedNode)
            } else {
                ProgressView().controlSize(.small)
            }
        case .failure(let failure):
            FailureView(failure: failure)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16)
            Text(model.status ?? screenTitle)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if let label = primaryLabel {
                Text(label).foregroundStyle(.primary)
                KeyCap("↵")
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
            return model.primaryAction?.string("title")
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

/// A command's view. Lists and details render simply here; their full look comes with later work.
private struct CommandContent: View {
    let view: UINode
    let rows: [UINode]
    let selected: Int?

    var body: some View {
        switch view.type {
        case "List":
            if rows.isEmpty {
                Text(view.bool("isLoading") == true ? "Loading…" : "No results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { row in
                                Row(
                                    icon: Image(systemName: "circle.fill"),
                                    title: row.string("title") ?? "",
                                    subtitle: row.string("subtitle"),
                                    accessory: nil,
                                    selected: row.id == (selected ?? rows.first?.id)
                                )
                                .id(row.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selected) { _, id in proxy.scrollTo(id) }
                }
            }
        case "Detail":
            ScrollView {
                Text((try? AttributedString(markdown: view.string("markdown") ?? "")) ?? "")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
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
