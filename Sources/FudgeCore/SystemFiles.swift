import CoreServices
import Foundation

/// File and application lookups behind the extension APIs that don't need AppKit.
public enum SystemFiles {
    /// Moves each path to the Trash. Stops at the first one that fails.
    public static func trash(_ paths: [String]) throws {
        for path in paths {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: expand(path)), resultingItemURL: nil)
        }
    }

    /// Applications that can open the file or URL at `target`.
    public static func applications(forOpening target: String) -> [JSONValue] {
        let urls = LSCopyApplicationURLsForURL(url(for: target) as CFURL, .all)?.takeRetainedValue() as? [URL] ?? []
        return urls.map(ApplicationResolver.application(at:))
    }

    /// The application that opens `target` by default.
    public static func defaultApplication(forOpening target: String) -> JSONValue? {
        guard let app = LSCopyDefaultApplicationURLForURL(url(for: target) as CFURL, .all, nil)?.takeRetainedValue()
        else { return nil }
        return ApplicationResolver.application(at: app as URL)
    }

    /// A URL for an `open` target: web and custom-scheme URLs as they are, anything else as a file path.
    public static func url(for target: String) -> URL {
        if !target.hasPrefix("/"), !target.hasPrefix("~"), let url = URL(string: target), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: expand(target))
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
