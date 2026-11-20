import AppKit
import FudgeCore
import SwiftUI

/// Markdown from an extension, drawn natively block by block.
struct MarkdownView: View {
    let markdown: String
    let assets: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, assets: assets)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown (emphasis, code, links, strikethrough) as attributed text.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let assets: URL?

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownView.inline(text))
                .font(.system(size: [22, 18, 15, 14, 13, 13][level - 1], weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            Text(MarkdownView.inline(text)).font(.system(size: 13)).lineSpacing(2)
        case .code(_, let text):
            // Wraps to the pane: at spaces where it can, and inside a token longer than the width.
            Text(text).font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(.secondary)
                        } else {
                            Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(MarkdownView.inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.level) * 14)
                }
            }
            .font(.system(size: 13))
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(MarkdownView.inline(text)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        case .image(let alt, let source):
            MarkdownImage(alt: alt, source: source, assets: assets)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        }
    }
}

/// A table scrolls sideways rather than wrap, which would wreck its columns. Its scroll indicator shows, and while
/// columns run past the right edge, that edge fades out: with macOS's overlay scroll bars the indicator only appears
/// while scrolling, so the fade is what shows there's more.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    /// The visible width, and where the table's right end is in the same coordinates (past `width` while columns
    /// are hidden to the right).
    @State private var width: CGFloat = 0
    @State private var contentEnd: CGFloat = 0

    private static let space = "markdown-table"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownView.inline(cell)).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownView.inline(cell))
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.frame(in: .named(Self.space)).maxX, initial: true) { _, end in
                        contentEnd = end
                    }
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, new in width = new }
            }
        }
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: contentEnd > width + 1 ? 40 : 0)
            }
        }
    }
}

/// An image in markdown: an https URL, a local file or an asset. Raycast's `raycast-width`, `raycast-height` and
/// `raycast-tint-color` query parameters size and tint it; until a remote one arrives, its description shows.
private struct MarkdownImage: View {
    let alt: String
    let source: String
    let assets: URL?
    /// The most room a markdown image takes, hinted or not.
    static let bounds = CGSize(width: 560, height: 320)

    var body: some View {
        if let image {
            let hints = MarkdownImageHints(source: source)
            let tint = hints.tintColor.flatMap { ExtensionColor.color(.string($0)) }
            let drawn = Group {
                if let tint {
                    Image(nsImage: image).resizable().renderingMode(.template).foregroundStyle(tint)
                } else {
                    Image(nsImage: image).resizable()
                }
            }
            if let size = hints.displaySize(natural: image.size, fitting: Self.bounds) {
                drawn.frame(width: size.width, height: size.height)
            } else {
                drawn.aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: min(image.size.width, Self.bounds.width), maxHeight: Self.bounds.height,
                        alignment: .leading)
            }
        } else {
            Label(alt.isEmpty ? source : alt, systemImage: "photo").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var image: NSImage? {
        if RemoteImageURL.isURL(source) {
            return RemoteImages.shared.entry(for: source).image
        }
        // Raycast's size hints (`?raycast-width=…`) don't name a different file.
        var path = source.components(separatedBy: "?")[0]
        if path.hasPrefix("file://") { path = URL(string: path)?.path ?? path }
        let file: URL
        if path.hasPrefix("/") || path.hasPrefix("~") {
            file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let assets {
            file = assets.appendingPathComponent(path.removingPercentEncoding ?? path)
        } else {
            return nil
        }
        return NSImage(contentsOf: file)
    }
}

/// A Metadata node's rows: the title on the left, the value on the right.
struct MetadataView: View {
    let entries: [MetadataEntry]
    let assets: URL?
    var layout: Layout = .rows
    /// Runs a tag's `onAction`, by node id.
    let onTag: (Int) -> Void

    enum Layout {
        /// The title on the left, the value on the right (under a List's detail).
        case rows
        /// The title above the value (in a Detail's side column).
        case stacked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout == .stacked ? 10 : 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                row(entry)
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private func row(_ entry: MetadataEntry) -> some View {
        switch entry {
        case .label(let title, let text, let color, let icon):
            line(title) {
                ExtensionImage(source: icon, assets: assets, size: 14)
                if let text {
                    Text(text).foregroundStyle(ExtensionColor.color(color) ?? .primary).lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        case .link(let title, let text, let target):
            line(title) {
                if let url = URL(string: target) {
                    Link(text, destination: url).lineLimit(1)
                } else {
                    Text(text).lineLimit(1)
                }
            }
        case .tags(let title, let tags):
            line(title) {
                ForEach(tags) { tag in
                    TagView(text: tag.text, icon: tag.icon, color: tag.color, assets: assets)
                        .onTapGesture { if tag.hasAction { onTag(tag.id) } }
                }
            }
        case .separator:
            Divider().padding(.vertical, 4)
        }
    }

    @ViewBuilder private func line(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        switch layout {
        case .rows:
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 12)
                value()
            }
            .frame(minHeight: 26)
        case .stacked:
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) { value() }.font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A colored tag, as in accessories and metadata tag lists.
struct TagView: View {
    let text: String?
    let icon: JSONValue?
    let color: JSONValue?
    let assets: URL?

    var body: some View {
        let tint = ExtensionColor.color(color) ?? .secondary
        HStack(spacing: 4) {
            ExtensionImage(source: icon, assets: assets, size: 12)
            if let text { Text(text).lineLimit(1) }
        }
        .font(.system(size: 12))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The thin animated bar shown under the search field while a view loads.
struct LoadingBar: View {
    @State private var moving = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Capsule()
                .fill(Color.accentColor)
                .frame(width: width * 0.25, height: 2)
                .offset(x: moving ? width : -width * 0.25)
        }
        .frame(height: 2)
        .clipped()
        .background(Color.primary.opacity(0.08))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { moving = true }
        }
    }
}
