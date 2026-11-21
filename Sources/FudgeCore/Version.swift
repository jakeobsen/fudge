import Foundation

/// The Fudge version shown by the app and the `fudge` tool: what `make app` writes into Fudge.app's `Info.plist`.
///
/// `CFBundleShortVersionString` is the version tag's major, minor and patch (`0.3.0`), as macOS expects,
/// `CFBundleVersion` a build number that only goes up, and `FudgeGitDescribe` the build's whole
/// `git describe --tags --always --dirty`, which the update check reads (`RunningVersion`) and Fudge shows its own form
/// of (`display`).
public enum FudgeVersion {
    /// Outside Fudge.app, as in `swift run` or a test.
    public static let fallback = "0.0.0-dev"
    public static let bundleIdentifier = "io.github.jakeobsen.fudge"
    public static let shortVersionKey = "CFBundleShortVersionString"
    public static let describeKey = "FudgeGitDescribe"

    /// The version to show, read once: the app's own, or for the `fudge` tool the app's it's in.
    public static let current: String = {
        let plist = info(bundle: Bundle.main.infoDictionary, executable: Bundle.main.executableURL)
        if let describe = plist?[describeKey] as? String { return display(describe: describe) }
        return plist?[shortVersionKey] as? String ?? fallback
    }()

    /// The build's `git describe`, else the version shown.
    public static let describe: String =
        info(bundle: Bundle.main.infoDictionary, executable: Bundle.main.executableURL)?[describeKey] as? String
        ?? current

    /// The version Fudge shows for a build's `git describe`: a tag's own version without its `v` (`0.3.0`,
    /// `1.2.0-rc.1`); for a build after it or with changes, that version with `dev` added to its pre-release and the
    /// rest as build metadata (`v0.3.0-14-ga539cdd-dirty` is `0.3.0-dev+14.a539cdd.dirty`), which `RunningVersion` reads
    /// back as 0.3.0; and without a version tag `0.0.0-dev`, with the commit when there is one.
    public static func display(describe: String) -> String {
        var rest = describe.trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = rest.hasSuffix("-dirty")
        if dirty { rest.removeLast("-dirty".count) }
        var after: [String] = []
        if let since = rest.wholeMatch(of: /(.+)-([0-9]+)-g([0-9a-f]{4,64})/) {
            rest = String(since.1)
            after = [String(since.2), String(since.3)]
        }
        let changes = after + (dirty ? ["dirty"] : [])
        if rest.hasPrefix("v"), let version = SemanticVersion(String(rest.dropFirst())) {
            if changes.isEmpty { return String(rest.dropFirst()) }
            let preRelease = version.preRelease.map { $0 + "." }.joined()
            return "\(version.major).\(version.minor).\(version.patch)-\(preRelease)dev+"
                + changes.joined(separator: ".")
        }
        // A bare commit, a tag that isn't a version (its commit is kept), or `dev` when git can't say.
        let commit = after.count == 2 ? after[1] : rest.wholeMatch(of: /[0-9a-f]{4,64}/).map { _ in rest }
        let metadata = (commit.map { [$0] } ?? []) + (dirty ? ["dirty"] : [])
        return metadata.isEmpty ? fallback : fallback + "+" + metadata.joined(separator: ".")
    }

    /// Fudge.app's `Info.plist`: the running bundle's when it's Fudge (the app), else, for a program in
    /// `Fudge.app/Contents/Helpers/` (the `fudge` tool, through a symlink too), the app's `Contents/Info.plist`.
    /// Nil anywhere else, so a test runner's own version is never taken for Fudge's.
    public static func info(bundle: [String: Any]?, executable: URL?) -> [String: Any]? {
        if let bundle, bundle["CFBundleIdentifier"] as? String == bundleIdentifier { return bundle }
        guard let folder = executable?.resolvingSymlinksInPath().deletingLastPathComponent(),
            folder.lastPathComponent == "Helpers"
        else { return nil }
        let plist = folder.deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            info["CFBundleIdentifier"] as? String == bundleIdentifier
        else { return nil }
        return info
    }
}
