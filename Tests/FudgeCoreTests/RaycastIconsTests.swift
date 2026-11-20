import AppKit
import Foundation
import Testing

@testable import FudgeCore

/// Raycast's icon values, read from the enums generated from its type definitions.
private func raycastIconValues() throws -> [String] {
    let generated = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("runtime/src/api/raycast-enums.generated.ts")
    let source = try String(contentsOf: generated, encoding: .utf8)
    guard let start = source.range(of: "    Icon: {\n"),
        let end = source.range(of: "    },", range: start.upperBound..<source.endIndex)
    else { return [] }
    let regex = try NSRegularExpression(pattern: #""([a-z0-9-]+-16)""#)
    let block = String(source[start.upperBound..<end.lowerBound])
    return regex.matches(in: block, range: NSRange(block.startIndex..., in: block)).compactMap {
        Range($0.range(at: 1), in: block).map { String(block[$0]) }
    }
}

@Test func everyRaycastIconHasASymbol() throws {
    let icons = try raycastIconValues()
    #expect(icons.count > 400, "the generated enums were found")
    let missing = icons.filter { RaycastIcons.symbol(for: $0) == nil }
    #expect(missing.isEmpty, "no symbol for \(missing)")
}

@Test func everySymbolExists() {
    let symbols = Set(RaycastIcons.symbols.values).union((0...50).map { String(format: "%02d.square", $0) })
    let unknown = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }.sorted()
    #expect(unknown.isEmpty, "not SF Symbols on this system: \(unknown)")
}

@Test func mapsIconsAndNumbers() {
    #expect(RaycastIcons.symbol(for: "arrow-clockwise-16") == "arrow.clockwise")
    #expect(RaycastIcons.symbol(for: "globe-01-16") == "globe")
    #expect(RaycastIcons.symbol(for: "number-07-16") == "07.square")
    #expect(RaycastIcons.symbol(for: "number-73-16") == "number.square")
    #expect(RaycastIcons.symbol(for: "folder") == nil, "not an icon value")
    #expect(RaycastIcons.symbol(for: "no-such-icon-16") == nil)
}
