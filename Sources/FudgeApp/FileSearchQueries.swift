import Foundation
import FudgeCore

/// `files.search`'s Spotlight query (SPEC-069 §2): an `NSMetadataQuery` on its own `OperationQueue`, so it's set up,
/// gathers and is read off the main thread. Its results are sorted by last use, so `finish(cap:)` reads the most
/// recently used first. Used once.
final class SpotlightFileQuery: FileMetadataQuery, @unchecked Sendable {
    // Everything below is touched only on `queue`.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Search Files"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?

    func start(
        _ request: FileSearchRequest, now: Date, scope: FileSearchScope,
        finished: @escaping @Sendable (_ failure: String?) -> Void
    ) {
        queue.addOperation { [self] in
            query.operationQueue = queue
            query.predicate = FileSearchPredicate.make(request, now: now)
            query.searchScopes = [scope == .mac ? NSMetadataQueryLocalComputerScope : NSMetadataQueryUserHomeScope]
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: queue
            ) { _ in finished(nil) }
            if !query.start() {
                stop()
                finished("Spotlight couldn't search. Check that Spotlight is on.")
            }
        }
    }

    func finish(cap: Int) async -> [FoundFile] {
        await withCheckedContinuation { continuation in
            queue.addOperation { [self] in
                query.disableUpdates()
                var found: [FoundFile] = []
                for index in 0..<min(query.resultCount, cap) {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                        let file = FoundFile(attribute: { item.value(forAttribute: $0) })
                    else { continue }
                    found.append(file)
                }
                stop()
                continuation.resume(returning: found)
            }
        }
    }

    func cancel() {
        queue.addOperation { [self] in stop() }
    }

    private func stop() {
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// Snapshot runs' query: the fixed results `--found-files` names (none without it), never Spotlight, so a snapshot
/// can't show the user's own files.
final class FixedFileQuery: FileMetadataQuery {
    let files: [FoundFile]

    init(_ files: [FoundFile]) { self.files = files }

    /// Reads `file`: a JSON array of entries as `files.search` answers them, with `~/` paths inside `home`.
    static func load(_ file: URL, home: String) -> [FoundFile] {
        guard let data = try? Data(contentsOf: file), case .array(let entries) = try? JSONValue.parse(data) else {
            return []
        }
        return entries.compactMap { FoundFile(json: $0, home: home) }
    }

    func start(
        _ request: FileSearchRequest, now: Date, scope: FileSearchScope,
        finished: @escaping @Sendable (_ failure: String?) -> Void
    ) {
        finished(nil)
    }

    func finish(cap: Int) async -> [FoundFile] { Array(files.prefix(cap)) }

    func cancel() {}
}
