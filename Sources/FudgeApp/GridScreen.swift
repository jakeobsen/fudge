import AppKit
import FudgeCore
import SwiftUI

/// A command's Grid: its sections as cells, each section laid out by its `GridSectionLayout`, and the empty view.
/// Search, selection, actions and paging are the List's (`ListContent`); only the drawing differs.
struct GridScreen: View {
    let model: LauncherModel
    let command: LauncherModel.CommandScreen
    let list: ListContent

    static let spacing: CGFloat = 8

    var body: some View {
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
                            let layout = section.grid ?? GridSectionLayout()
                            LazyVGrid(columns: columns(layout), alignment: .leading, spacing: Self.spacing) {
                                ForEach(section.items) { item in
                                    GridCell(
                                        item: item, layout: layout, selected: item.id == selected,
                                        assets: command.assets
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
                            .padding(.horizontal, 2)
                            .padding(.bottom, Self.spacing)
                        }
                        if list.isLoading, let pagination = list.pagination, pagination.hasMore {
                            let layout = list.sections.last?.grid ?? GridSectionLayout()
                            LazyVGrid(columns: columns(layout), alignment: .leading, spacing: Self.spacing) {
                                ForEach(0..<min(pagination.pageSize, layout.columns * 2), id: \.self) { _ in
                                    PlaceholderCell(aspectRatio: layout.aspectRatio)
                                }
                            }
                            .padding(.horizontal, 2)
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

    private func columns(_ layout: GridSectionLayout) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: layout.columns)
    }
}

/// One cell: the content in a rounded frame of the section's aspect ratio, then the title and subtitle on a line
/// each, with the accessory beside them.
private struct GridCell: View {
    let item: ListContent.Item
    let layout: GridSectionLayout
    let selected: Bool
    let assets: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let shape = RoundedRectangle(cornerRadius: 8)
            Color.clear
                .aspectRatio(layout.aspectRatio, contentMode: .fit)
                .overlay {
                    GridCellContent(content: item.content, fit: layout.fit, assets: assets)
                        .padding(layout.insetPoints)
                }
                .clipShape(shape)
                .background(Color.primary.opacity(selected ? 0.12 : 0.05), in: shape)
                .overlay(shape.strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .tooltip(item.content?.tooltip)
            if !item.title.isEmpty || item.subtitle != nil || !item.accessories.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        if !item.title.isEmpty {
                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                .tooltip(item.titleTooltip)
                        }
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                .tooltip(item.subtitleTooltip)
                        }
                    }
                    Spacer(minLength: 0)
                    ForEach(Array(item.accessories.enumerated()), id: \.offset) { _, accessory in
                        ExtensionImage(source: accessory.icon, assets: assets, size: 12).tooltip(accessory.tooltip)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A cell's content, drawn into the space the inset leaves: an image as `fit` says, or a color filling it.
private struct GridCellContent: View {
    let content: GridItemContent?
    let fit: GridSectionLayout.Fit
    let assets: URL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            switch content?.kind {
            case .color(let json):
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: ExtensionColor(json: json)?.exactNSColor ?? .clear))
            case .image(let json):
                if let resolved = ExtensionImages.resolve(json, assets: assets, dark: colorScheme == .dark) {
                    drawn(resolved, in: size)
                        .frame(width: size.width, height: size.height)
                        .clipShape(CellMask(mask: resolved.mask))
                }
            case nil:
                EmptyView()
            }
        }
    }

    /// Pictures follow `fit`. Icons and emoji are drawn smaller, in the middle, as Raycast does.
    @ViewBuilder private func drawn(_ resolved: ResolvedImage, in size: CGSize) -> some View {
        let tint = resolved.tint?.color
        let side = min(size.width, size.height)
        switch resolved.content {
        case .bitmap(let image):
            let mode: ContentMode = fit == .fill ? .fill : .fit
            if let tint {
                Image(nsImage: image).resizable().renderingMode(.template).aspectRatio(contentMode: mode)
                    .foregroundStyle(tint)
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: mode)
            }
        case .symbol(let name):
            Image(systemName: name).resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: side * 0.5, height: side * 0.5)
        case .text(let text):
            Text(text).font(.system(size: side * 0.6))
        }
    }
}

private struct CellMask: Shape {
    let mask: String?

    func path(in rect: CGRect) -> Path {
        switch mask {
        case "circle": Path(ellipseIn: rect)
        case "roundedRectangle": Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.22)
        default: Path(rect)
        }
    }
}

/// A cell standing in for an item of the page that's loading.
private struct PlaceholderCell: View {
    let aspectRatio: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 8).aspectRatio(aspectRatio, contentMode: .fit)
            RoundedRectangle(cornerRadius: 3).frame(width: 60, height: 8)
        }
        .foregroundStyle(Color.primary.opacity(0.08))
    }
}

extension ExtensionColor {
    /// The color exactly as given, without the contrast adjustment text and icons get, so a Grid's color cells show
    /// the very color the extension means (black stays black in dark mode).
    var exactNSColor: NSColor {
        switch self {
        case .named:
            nsColor
        case .rgb(let red, let green, let blue, let alpha):
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case .dynamic(let light, let dark):
            NSColor(name: nil) { appearance in
                (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light).exactNSColor
            }
        }
    }
}
