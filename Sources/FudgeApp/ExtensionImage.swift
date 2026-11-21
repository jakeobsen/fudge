import AppKit
import FudgeCore
import SwiftUI

/// An `Image.ImageLike` from an extension, resolved to something drawable.
struct ResolvedImage {
    enum Content {
        case bitmap(NSImage)
        case symbol(String)
        /// An emoji or other short text used as an icon.
        case text(String)
    }

    var content: Content
    var tint: ExtensionColor?
    /// "circle" or "roundedRectangle".
    var mask: String?
}

@MainActor
enum ExtensionImages {
    private static var cache: [String: NSImage] = [:]

    /// Resolves an image the way Raycast does: a file icon, an asset (with its `@dark` variant), a file path,
    /// one of Raycast's icons, or an emoji; `{ source, tintColor, mask, fallback }` wraps any of these.
    static func resolve(_ json: JSONValue?, assets: URL?, dark: Bool) -> ResolvedImage? {
        switch json {
        case .string(let source):
            return (content(for: source, assets: assets, dark: dark) ?? placeholder(for: source))
                .map { ResolvedImage(content: $0) }
        case .object(let object):
            if case .string(let path) = object["fileIcon"] {
                return ResolvedImage(content: .bitmap(fileIcon(path)))
            }
            var source: String?
            switch object["source"] {
            case .string(let string):
                source = string
            case .object(let themed):
                if case .string(let string) = themed[dark ? "dark" : "light"] { source = string }
            default:
                break
            }
            var resolved = source.flatMap { content(for: $0, assets: assets, dark: dark) }
            if resolved == nil, case .string(let fallback) = object["fallback"] {
                resolved = content(for: fallback, assets: assets, dark: dark)
            }
            guard let resolved = resolved ?? source.flatMap(placeholder) else { return nil }
            let mask: String? = if case .string(let mask) = object["mask"] { mask } else { nil }
            return ResolvedImage(content: resolved, tint: ExtensionColor(json: object["tintColor"]), mask: mask)
        default:
            return nil
        }
    }

    /// An NSImage for places that need one, like menu items.
    static func nsImage(_ json: JSONValue?, assets: URL?, size: CGFloat) -> NSImage? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let resolved = resolve(json, assets: assets, dark: dark) else { return nil }
        let image: NSImage
        switch resolved.content {
        case .bitmap(let bitmap):
            image = bitmap.copy() as? NSImage ?? bitmap
        case .symbol(let name):
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
            image = symbol
        case .text:
            return nil
        }
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// Shown where a remote image is still loading, or failed with no `fallback`.
    private static func placeholder(for source: String) -> ResolvedImage.Content? {
        RemoteImageURL.isURL(source) ? .symbol("photo") : nil
    }

    private static func content(for source: String, assets: URL?, dark: Bool) -> ResolvedImage.Content? {
        // A `data:` image, such as @raycast/utils' provider icons (SVG).
        if source.hasPrefix("data:") {
            if let cached = cache[source] { return .bitmap(cached) }
            guard let (_, data) = DataURL.image(source), let image = NSImage(data: data) else { return nil }
            cache[source] = image
            return .bitmap(image)
        }
        if RemoteImageURL.isURL(source) {
            // The placeholder shows while it loads; a failed one gives way to the fallback.
            let entry = RemoteImages.shared.entry(for: source)
            if let image = entry.image { return .bitmap(image) }
            return entry.failed ? nil : .symbol("photo")
        }
        if source.hasPrefix("/") || source.hasPrefix("~") {
            return bitmap(at: URL(fileURLWithPath: (source as NSString).expandingTildeInPath)).map { .bitmap($0) }
        }
        if let assets, let image = asset(source, in: assets, dark: dark) {
            return .bitmap(image)
        }
        if source.hasSuffix("-16"), let symbol = symbol(forRaycastIcon: source) {
            return .symbol(symbol)
        }
        if !source.isEmpty, source.count <= 2 {
            return .text(source)
        }
        return nil
    }

    /// An asset, preferring `name@dark.ext` in dark mode.
    private static func asset(_ name: String, in assets: URL, dark: Bool) -> NSImage? {
        let file = assets.appendingPathComponent(name)
        if dark {
            let variant =
                file.deletingPathExtension().path + "@dark"
                + (file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)")
            if let image = bitmap(at: URL(fileURLWithPath: variant)) { return image }
        }
        return bitmap(at: file)
    }

    private static func bitmap(at file: URL) -> NSImage? {
        let key = "file:" + file.path
        if let cached = cache[key] { return cached }
        guard FileManager.default.fileExists(atPath: file.path), let image = NSImage(contentsOf: file) else {
            return nil
        }
        cache[key] = image
        return image
    }

    private static func fileIcon(_ path: String) -> NSImage {
        let expanded = (path as NSString).expandingTildeInPath
        let key = "icon:" + expanded
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: expanded)
        cache[key] = image
        return image
    }

    private static var symbols: [String: String] = [:]

    /// The SF Symbol for one of Raycast's icons ("arrow-clockwise-16"). An icon newer than fudge's table, or one
    /// whose symbol this macOS lacks, gets a symbol with the same name if there is one, else a placeholder.
    private static func symbol(forRaycastIcon icon: String) -> String? {
        if let known = symbols[icon] { return known }
        func exists(_ name: String) -> Bool { NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil }
        let base = String(icon.dropLast(3))
        let candidates =
            [RaycastIcons.symbol(for: icon)].compactMap { $0 }
            + [base.replacingOccurrences(of: "-", with: "."), base.replacingOccurrences(of: "-", with: "")]
        let symbol = candidates.first(where: exists) ?? "circle.dashed"
        symbols[icon] = symbol
        return symbol
    }
}

/// Draws an extension's image at a square size.
struct ExtensionImage: View {
    let source: JSONValue?
    let assets: URL?
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let resolved = ExtensionImages.resolve(source, assets: assets, dark: colorScheme == .dark) {
            drawn(resolved)
                .frame(width: size, height: size)
                .clipShape(MaskShape(mask: resolved.mask, size: size))
        }
    }

    @ViewBuilder private func drawn(_ resolved: ResolvedImage) -> some View {
        let tint = resolved.tint?.color
        switch resolved.content {
        case .bitmap(let image):
            if let tint {
                Image(nsImage: image).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        case .symbol(let name):
            Image(systemName: name).resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(tint ?? Color.primary)
                .padding(size * 0.08)
        case .text(let text):
            Text(text).font(.system(size: size * 0.85))
        }
    }
}

private struct MaskShape: Shape {
    let mask: String?
    let size: CGFloat

    func path(in rect: CGRect) -> Path {
        switch mask {
        case "circle": Path(ellipseIn: rect)
        case "roundedRectangle": Path(roundedRect: rect, cornerRadius: size * 0.22)
        default: Path(rect)
        }
    }
}

extension ExtensionColor {
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .named(let name):
            switch name {
            case "raycast-blue": .systemBlue
            case "raycast-green": .systemGreen
            case "raycast-magenta": .systemPink
            case "raycast-orange": .systemOrange
            case "raycast-purple": .systemPurple
            case "raycast-red": .systemRed
            case "raycast-yellow": .systemYellow
            case "raycast-secondary-text": .secondaryLabelColor
            default: .labelColor
            }
        case .rgb(let red, let green, let blue, let alpha):
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let (r, g, b) = ExtensionColor.readable(red: red, green: green, blue: blue, dark: dark)
                return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
            }
        case .dynamic(let light, let dark):
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark.nsColor : light.nsColor
            }
        }
    }

    /// The SwiftUI color for a `Color.ColorLike`, if it's one fudge understands.
    static func color(_ json: JSONValue?) -> Color? {
        ExtensionColor(json: json)?.color
    }
}

extension View {
    /// A tooltip, when there's text for one.
    @ViewBuilder func tooltip(_ text: String?) -> some View {
        if let text, !text.isEmpty { help(text) } else { self }
    }
}
