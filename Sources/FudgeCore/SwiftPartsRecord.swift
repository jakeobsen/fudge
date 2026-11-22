import Foundation

/// What `fudge build` did with an extension's parts written in Swift (SPEC-145 §2), kept in the install as
/// `swift-parts.json` (`{"swiftParts": "build"}` or `"leave-out"`), so the Extension Store can say an extension was
/// installed without them. An install with no such part has no file.
public struct SwiftPartsRecord: Sendable, Equatable {
    public static let fileName = "swift-parts.json"

    public var swiftParts: BuildArguments.SwiftParts

    public init(swiftParts: BuildArguments.SwiftParts) {
        self.swiftParts = swiftParts
    }

    /// The record for the `swift:` plugin's report (`{ "<package folder>": "build" | "leave-out" }`): left out when any
    /// package was, else built; nil when the report is missing, empty or unreadable, since then no package was bundled.
    init?(report: URL) {
        guard let data = try? Data(contentsOf: report),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let modes = object.values.compactMap { ($0 as? String).flatMap(BuildArguments.SwiftParts.init(rawValue:)) }
        guard !modes.isEmpty else { return nil }
        self.init(swiftParts: modes.contains(.leaveOut) ? .leaveOut : .build)
    }

    /// The record in the install at `directory`, or nil when it has none or can't be read.
    public static func load(from directory: URL) -> SwiftPartsRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let mode = (object["swiftParts"] as? String).flatMap(BuildArguments.SwiftParts.init(rawValue:))
        else { return nil }
        return SwiftPartsRecord(swiftParts: mode)
    }

    func write(to directory: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["swiftParts": swiftParts.rawValue], options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(Self.fileName))
    }
}
