import CoreFoundation
import Foundation

/// The Extension Store's record of a running `fudge build`, `installing/<pid>.json` (SPEC-153 C.1), as the app reads it
/// to name a build in its notification (SPEC-156 C.2). It's read by the store reader's rules (`parseBuildRecord` in
/// `build-records.ts`), and `runtime/test/fixtures/build-records.json` pins both readers to the same cases.
public struct StoreBuildRecord: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var dir: String
    public var title: String
    public var updating: Bool
    /// As written, so it matches the store's report of the same build (`build.startedAt`) exactly.
    public var startedAt: String
    /// For an added repository's build (SPEC-157 E.3): the id the extension gets there. Raycast's has none.
    public var id: String?
    /// The folder of the repository the build is from; only an added repository's.
    public var repository: String?

    public init(
        pid: Int32, name: String, dir: String, title: String, updating: Bool, startedAt: String, id: String? = nil,
        repository: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.dir = dir
        self.title = title
        self.updating = updating
        self.startedAt = startedAt
        self.id = id
        self.repository = repository
    }

    /// The build this record is of.
    public var build: InstallBuild { InstallBuild(pid: pid, startedAt: startedAt) }

    /// The record in `data`, read from the file `fileName`, or nil when the name isn't `<pid>.json` or a field isn't
    /// valid: `pid` that number, a valid name and folder, `title` and `commit` strings, `updating` a boolean, `tree` a
    /// string when it's there, `startedAt` and `deadline` times, and `command` a list of strings that isn't empty.
    /// `id` and `repository` come together or not at all: a repository folder other than Raycast's, and the id the name
    /// gets in it.
    public static func parse(fileName: String, data: Data) -> StoreBuildRecord? {
        guard let pid = BuildOutcomeFile.pid(ofCompanion: fileName, suffix: ".json"),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let filePID = integer(object["pid"]), filePID == Int(pid),
            let name = object["name"] as? String, ExtensionManifest.isValidName(name),
            let dir = object["dir"] as? String, isValidFolder(dir),
            let title = object["title"] as? String, object["commit"] is String,
            let updating = boolean(object["updating"]),
            object["tree"] == nil || object["tree"] is String,
            let startedAt = object["startedAt"] as? String, time(startedAt) != nil, time(object["deadline"]) != nil,
            let command = object["command"] as? [Any], !command.isEmpty, command.allSatisfy({ $0 is String }),
            let source = repositorySource(id: object["id"], repository: object["repository"], name: name)
        else { return nil }
        return StoreBuildRecord(
            pid: pid, name: name, dir: dir, title: title, updating: updating, startedAt: startedAt, id: source.id,
            repository: source.repository)
    }

    /// A record's `id` and `repository`, as `parseBuildRecord` reads them: both missing (Raycast's), or a repository
    /// folder other than Raycast's with the id `name` gets there. Nil when they don't fit.
    static func repositorySource(id: Any?, repository: Any?, name: String) -> (id: String?, repository: String?)? {
        switch (id, repository) {
        case (nil, nil):
            return (nil, nil)
        case (let id as String, let folder as String):
            guard ExtensionRepositoryFolder.isValid(folder), folder != ExtensionRepositoryFolder.raycast,
                ExtensionID(name: name, repositoryFolder: folder)?.key == id
            else { return nil }
            return (id, folder)
        default:
            return nil
        }
    }

    /// A folder in Raycast's repository, as `catalog.ts`'s `isValidFolder` has it: one segment of ASCII letters,
    /// digits, `.`, `_` and `-`, starting with a letter or digit.
    public static func isValidFolder(_ folder: String) -> Bool {
        let scalars = Array(folder.unicodeScalars)
        guard let first = scalars.first, isAlphanumeric(first) else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    /// A JSON number that's a safe integer, as `Number.isSafeInteger` takes it (`12.0` counts); never a boolean.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
    }

    /// A JSON boolean, never a number.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A time written exactly as JavaScript's `toISOString()` writes it, as the store's `isTime` takes it.
    static func time(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}

/// One build, as the app tells builds apart (SPEC-156 C.1): its pid and its record's `startedAt`, since Node reaps the
/// store's own builds and a pid can come back for a later build in the same run.
public struct InstallBuild: Sendable, Hashable {
    public var pid: Int32
    public var startedAt: String

    public init(pid: Int32, startedAt: String) {
        self.pid = pid
        self.startedAt = startedAt
    }
}
