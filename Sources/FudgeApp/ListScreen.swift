import AppKit
import FudgeCore
import SwiftUI

/// A command's List: sections of items, the empty view, and the detail pane when the List shows one.
struct ListScreen: View {
    let model: LauncherModel
    let command: LauncherModel.CommandScreen
    let list: ListContent

    var body: some View {
        if list.isShowingDetail {
            HStack(spacing: 0) {
                items(compact: true).frame(width: 300)
                Divider()
                ListDetailPane(
                    detail: model.selectedListItem?.detail,
                    assets: command.assets,
                    onTag: { model.call(node: $0, ["onAction"]) }
                )
            }
        } else {
            items(compact: false)
        }
    }

    @ViewBuilder private func items(compact: Bool) -> some View {
        if let empty = list.emptyView {
            EmptyStateView(empty: empty, assets: command.assets)
        } else {
            let selected = model.selectedListItem?.id
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.sections.enumerated()), id: \.element.id) { index, section in
                            if let title = section.title {
                                SectionHeader(title: title, subtitle: section.subtitle, first: index == 0)
                            }
                            ForEach(section.items) { item in
                                ListRow(
                                    item: item, selected: item.id == selected, compact: compact, assets: command.assets
                                )
                                .id(item.id)
                                .onTapGesture(count: 2) {
                                    model.select(node: item.id)
                                    model.activate()
                                }
                                .onTapGesture { model.select(node: item.id) }
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selected) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String?
    let first: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.medium).foregroundStyle(.secondary)
            if let subtitle { Text(subtitle).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.top, first ? 4 : 12)
        .padding(.bottom, 4)
    }
}

private struct ListRow: View {
    let item: ListContent.Item
    let selected: Bool
    /// Beside a detail pane, rows show only the icon and title, as in Raycast.
    let compact: Bool
    let assets: URL?

    var body: some View {
        HStack(spacing: 10) {
            ExtensionImage(source: item.icon, assets: assets, size: 20).tooltip(item.iconTooltip)
            Text(item.title).lineLimit(1).tooltip(item.titleTooltip)
            if !compact, let subtitle = item.subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1).tooltip(item.subtitleTooltip)
            }
            Spacer(minLength: 8)
            if !compact {
                ForEach(Array(item.accessories.enumerated()), id: \.offset) { _, accessory in
                    AccessoryView(accessory: accessory, assets: assets)
                }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

private struct AccessoryView: View {
    let accessory: ListContent.Accessory
    let assets: URL?

    var body: some View {
        Group {
            if accessory.isTag {
                TagView(text: accessory.text, icon: accessory.icon, color: accessory.color, assets: assets)
            } else {
                HStack(spacing: 4) {
                    ExtensionImage(source: accessory.icon, assets: assets, size: 14)
                    if let text = accessory.text {
                        Text(text)
                            .foregroundStyle(ExtensionColor.color(accessory.color) ?? .secondary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12))
            }
        }
        .tooltip(accessory.tooltip)
    }
}

private struct EmptyStateView: View {
    let empty: ListContent.EmptyView
    let assets: URL?

    var body: some View {
        VStack(spacing: 8) {
            if empty.icon != nil {
                ExtensionImage(source: empty.icon, assets: assets, size: 48)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            if !empty.title.isEmpty {
                Text(empty.title).font(.system(size: 15, weight: .semibold))
            }
            if let description = empty.description {
                Text(description).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right side of a List with `isShowingDetail`: the selected item's markdown, then its metadata.
private struct ListDetailPane: View {
    let detail: UINode?
    let assets: URL?
    let onTag: (Int) -> Void

    var body: some View {
        let markdown = detail?.string("markdown") ?? ""
        let metadata = MetadataEntry.entries(of: detail?.node("metadata"))
        VStack(spacing: 0) {
            if detail?.bool("isLoading") == true { LoadingBar() }
            if !markdown.isEmpty {
                ScrollView {
                    MarkdownView(markdown: markdown, assets: assets).padding(16)
                }
                .frame(maxHeight: .infinity)
            }
            if !metadata.isEmpty {
                if markdown.isEmpty {
                    ScrollView {
                        MetadataView(entries: metadata, assets: assets, onTag: onTag).padding(16)
                    }
                } else {
                    Divider()
                    MetadataView(entries: metadata, assets: assets, onTag: onTag)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The dropdown at the right of the search field, as a native pop-up button so ⌘P can open it.
struct SearchBarDropdownButton: NSViewRepresentable {
    let dropdown: SearchBarDropdown
    let value: String?
    /// Opens the menu whenever this changes.
    let openRequests: Int
    let assets: URL?
    let onSelect: (String) -> Void

    @MainActor final class Coordinator: NSObject {
        var onSelect: (String) -> Void = { _ in }
        var shown: SearchBarDropdown?
        var openRequests = 0

        @objc func changed(_ sender: NSPopUpButton) {
            if let value = sender.selectedItem?.representedObject as? String { onSelect(value) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.autoenablesItems = false
        // Keep typing in the search field after picking a value.
        button.refusesFirstResponder = true
        button.font = .systemFont(ofSize: 13)
        context.coordinator.openRequests = openRequests
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        if coordinator.shown != dropdown {
            coordinator.shown = dropdown
            let menu = NSMenu()
            for (index, section) in dropdown.sections.enumerated() {
                if let title = section.title {
                    menu.addItem(.sectionHeader(title: title))
                } else if index > 0 {
                    menu.addItem(.separator())
                }
                for item in section.items {
                    let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    menuItem.representedObject = item.value
                    menuItem.image = ExtensionImages.nsImage(item.icon, assets: assets, size: 16)
                    menu.addItem(menuItem)
                }
            }
            button.menu = menu
        }
        let values = button.itemArray.map { $0.representedObject as? String }
        if let index = values.firstIndex(where: { $0 != nil && $0 == value }) ?? values.firstIndex(where: { $0 != nil })
        {
            button.selectItem(at: index)
        }
        button.toolTip = dropdown.tooltip
        if openRequests != coordinator.openRequests {
            coordinator.openRequests = openRequests
            DispatchQueue.main.async { button.performClick(nil) }
        }
    }
}
