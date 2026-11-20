import Foundation

/// Temporary timing logs for FUD-81, on stderr while FUDGE_TIMING is set.
public enum Timing {
    public static let enabled = ProcessInfo.processInfo.environment["FUDGE_TIMING"] != nil
    public static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    public static func log(_ stage: String, _ fields: String = "") {
        guard enabled else { return }
        FileHandle.standardError.write(Data("fudge-timing \(String(format: "%.1f", now())) \(stage) \(fields)\n".utf8))
    }
    public static func ms(since start: Double) -> String { String(format: "%.1f", now() - start) }
}
