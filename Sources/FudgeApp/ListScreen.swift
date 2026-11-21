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
                let selected = model.selectedListItem
                ListDetailPane(
                    detail: selected?.detail,
                    waiting: selected?.deferred.contains(.detail) == true,
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
                                .onRowClick(
                                    select: {
                                        model.select(node: item.id)
                                        // A click can leave the first responder outside the search field.
                                        model.restoreKeyboard()
                                    },
                                    open: { model.activate() }
                                )
                                // Scrolling near the end asks for the next page.
                                .onAppear { model.loadMoreIfNeeded(near: item.id) }
                            }
                        }
                        if list.isLoading, let pagination = list.pagination, pagination.hasMore {
                            ForEach(0..<min(pagination.pageSize, 8), id: \.self) { _ in PlaceholderRow() }
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

struct SectionHeader: View {
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

struct EmptyStateView: View {
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

/// The right side of a List with `isShowingDetail`: the selected item's markdown, then its metadata. While its
/// `detail` hasn't come (`waiting`, `ItemSlots`), it shows as loading, never another row's.
private struct ListDetailPane: View {
    let detail: UINode?
    let waiting: Bool
    let assets: URL?
    let onTag: (Int) -> Void

    var body: some View {
        let markdown = detail?.string("markdown") ?? ""
        let metadata = MetadataEntry.entries(of: detail?.node("metadata"))
        VStack(spacing: 0) {
            if waiting || detail?.bool("isLoading") == true { LoadingBar() }
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

/// A row standing in for an item of the page that's loading.
private struct PlaceholderRow: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4).frame(width: 20, height: 20)
            RoundedRectangle(cornerRadius: 4).frame(width: 180, height: 10)
            Spacer()
        }
        .foregroundStyle(Color.primary.opacity(0.08))
        .padding(.horizontal, 10)
        .frame(height: 38)
    }
}

/// The dropdown at the right of the search field: the current value; a click or ⌘P opens its panel.
struct SearchBarDropdownButton: View {
    let model: LauncherModel
    let dropdown: SearchBarDropdown
    let assets: URL?

    var body: some View {
        let current = dropdown.items.first { $0.value == model.dropdownValue } ?? dropdown.items.first
        Button {
            model.toggleDropdownPanel()
        } label: {
            HStack(spacing: 6) {
                if let current {
                    ExtensionImage(source: current.icon, assets: assets, size: 14)
                    Text(current.title).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Color.primary.opacity(model.dropdownPanel == nil ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .tooltip(dropdown.tooltip.map { "\($0) (⌘P)" })
    }
}

/// The dropdown's open panel: its own search field, then its sections, with the current value checked.
/// The dropdown panel: a search field over sections of items. It serves the List's search bar dropdown (⌘P), a
/// Form.Dropdown and a TagPicker, reading what it shows from the model's open panel.
struct DropdownPanelView: View {
    @Bindable var model: LauncherModel
    let assets: URL?
    var focus: FocusState<LauncherView.Field?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField(model.dropdownPanelPlaceholder, text: $model.dropdownPanelQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(focus, equals: .dropdown)
                    .onSubmit { model.pickDropdownItem() }
                    .onKeyPress(.upArrow) {
                        model.moveDropdownSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        model.moveDropdownSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        model.escape()
                        return .handled
                    }
                    // A TagPicker takes its last tag off with ⌫ in the empty search.
                    .onKeyPress(.delete) { model.dropdownPanelDeleteBackward() ? .handled : .ignored }
                if model.dropdownPanelIsLoading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let sections = model.dropdownPanelSections
                        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                            if let title = section.title {
                                Text(title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, index == 0 ? 2 : 8)
                            } else if index > 0 {
                                Divider().padding(.vertical, 4)
                            }
                            ForEach(section.items) { item in
                                row(item)
                                    .id(item.value)
                                    .onTapGesture { model.pickDropdownItem(item.value) }
                            }
                        }
                        if sections.isEmpty {
                            Text(model.dropdownPanelIsLoading ? "Loading…" : "No results").foregroundStyle(.secondary)
                                .padding(8)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.dropdownPanel?.selected) { _, value in
                    if let value { proxy.scrollTo(value) }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func row(_ item: SearchBarDropdown.Item) -> some View {
        HStack(spacing: 8) {
            ExtensionImage(source: item.icon, assets: assets, size: 16)
            Text(item.title).lineLimit(1)
            Spacer()
            if model.dropdownPanelChecks(item.value) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            item.value == model.dropdownPanel?.selected ? Color.primary.opacity(0.1) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
}
