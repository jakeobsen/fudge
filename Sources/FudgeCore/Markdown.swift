import Foundation

/// A block of a markdown document. Text inside blocks is still inline markdown (emphasis, code, links),
/// which the app renders with `AttributedString`.
public enum MarkdownBlock: Sendable, Equatable {
    public struct ListItem: Sendable, Equatable {
        /// "•" for bullets, "1." for numbered items.
        public var marker: String
        /// Nesting, from 0.
        public var level: Int
        /// Set for task list items (`- [ ]`, `- [x]`).
        public var checked: Bool?
        public var text: String
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case list([ListItem])
    case quote(String)
    case rule
    case image(alt: String, source: String)
    case table(header: [String], rows: [[String]])
}

/// Splits CommonMark into blocks: the subset extensions use in Detail views, without HTML.
public enum Markdown {
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
            } else if let fence = fence(trimmed) {
                index = code(lines, from: index, fence: fence, into: &blocks)
            } else if let heading = heading(trimmed) {
                blocks.append(heading)
                index += 1
            } else if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
            } else if index + 1 < lines.count, trimmed.contains("|"), isDelimiterRow(lines[index + 1]) {
                index = table(lines, from: index, into: &blocks)
            } else if trimmed.hasPrefix(">") {
                index = quote(lines, from: index, into: &blocks)
            } else if listItem(line) != nil {
                index = list(lines, from: index, into: &blocks)
            } else if let image = image(trimmed) {
                blocks.append(image)
                index += 1
            } else {
                index = paragraph(lines, from: index, into: &blocks)
            }
        }
        return blocks
    }

    // MARK: - Blocks

    private static func code(
        _ lines: [String], from start: Int, fence: (String, String?), into blocks: inout [MarkdownBlock]
    )
        -> Int
    {
        var body: [String] = []
        var index = start + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence.0), trimmed.allSatisfy({ $0 == fence.0.first }) {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        blocks.append(.code(language: fence.1, text: body.joined(separator: "\n")))
        return index
    }

    private static func table(_ lines: [String], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        let header = cells(lines[start])
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            var row = cells(trimmed)
            row += Array(repeating: "", count: max(0, header.count - row.count))
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }
        blocks.append(.table(header: header, rows: rows))
        return index
    }

    private static func quote(_ lines: [String], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var body: [String] = []
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var content = trimmed.dropFirst()
            if content.first == " " { content = content.dropFirst() }
            body.append(String(content))
            index += 1
        }
        blocks.append(.quote(joinLines(body)))
        return index
    }

    private static func list(_ lines: [String], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var items: [MarkdownBlock.ListItem] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            if let item = listItem(line) {
                items.append(item)
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line ends the list unless another item of the same kind follows it.
                guard index + 1 < lines.count, let next = listItem(lines[index + 1]),
                    (next.marker == "•") == (items.last?.marker == "•")
                else { break }
                index += 1
            } else if line.first == " " || line.first == "\t", !items.isEmpty {
                // An indented line continues the item above.
                items[items.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
                index += 1
            } else {
                break
            }
        }
        blocks.append(.list(items))
        return index
    }

    private static func paragraph(_ lines: [String], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var body: [String] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if index > start, !trimmed.contains(" "), let mark = trimmed.first, "=-".contains(mark),
                trimmed.allSatisfy({ $0 == mark })
            {
                // A setext heading: the paragraph so far, underlined.
                blocks.append(.heading(level: mark == "=" ? 1 : 2, text: joinLines(body)))
                return index + 1
            }
            if index > start {
                let interrupts =
                    fence(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">")
                    || bullet(line)
                if interrupts { break }
            }
            body.append(line)
            index += 1
        }
        blocks.append(.paragraph(joinLines(body)))
        return index
    }

    // MARK: - Lines

    /// The fence characters and the info string's first word, for a line that opens a code block.
    private static func fence(_ trimmed: String) -> (String, String?)? {
        for character in ["`", "~"] {
            let run = trimmed.prefix { String($0) == character }
            guard run.count >= 3 else { continue }
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            if character == "`", info.contains("`") { return nil }
            let language = info.split(separator: " ").first.map(String.init)
            return (String(run), language)
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s is decoration.
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text.removeSubrange(closing)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return .heading(level: hashes.count, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        let marks = trimmed.filter { $0 != " " }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }

    private static func isDelimiterRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        return cells(trimmed).allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
                current.append(character)
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current)
        return cells.map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|")
        }
    }

    private static func bullet(_ line: String) -> Bool {
        guard let item = listItem(line) else { return false }
        return item.marker == "•"
    }

    static func listItem(_ line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        var marker: String
        var text: Substring
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            marker = "•"
            text = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            let after = rest.dropFirst(digits.count)
            guard (1...9).contains(digits.count), let delimiter = after.first, ".)".contains(delimiter),
                after.dropFirst().first == " "
            else { return nil }
            marker = "\(Int(digits) ?? 1)."
            text = after.dropFirst(2)
        }
        text = text.drop { $0 == " " }
        var checked: Bool?
        if marker == "•", text.count >= 3, text.hasPrefix("["), text.dropFirst(2).first == "]",
            let mark = text.dropFirst().first, " xX".contains(mark)
        {
            checked = mark != " "
            text = text.dropFirst(3).drop { $0 == " " }
        }
        return MarkdownBlock.ListItem(marker: marker, level: min(indent / 2, 6), checked: checked, text: String(text))
    }

    /// `![alt](source "title")` on a line by itself.
    private static func image(_ trimmed: String) -> MarkdownBlock? {
        let pattern = #"^!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let alt = Range(match.range(at: 1), in: trimmed),
            let source = Range(match.range(at: 2), in: trimmed)
        else { return nil }
        return .image(alt: String(trimmed[alt]), source: String(trimmed[source]))
    }

    /// Joins a paragraph's lines: a soft break is a space, and a line ending in two spaces or `\` breaks.
    private static func joinLines(_ lines: [String]) -> String {
        var text = ""
        for (index, line) in lines.enumerated() {
            var content = line.trimmingCharacters(in: .whitespaces)
            let last = index == lines.count - 1
            if !last, line.hasSuffix("  ") {
                text += content + "\n"
            } else if !last, content.hasSuffix("\\") {
                content.removeLast()
                text += content + "\n"
            } else {
                text += content + (last ? "" : " ")
            }
        }
        return text
    }
}
