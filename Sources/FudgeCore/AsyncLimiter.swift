import Foundation

/// Lets at most `limit` callers hold a slot at once; the others wait their turn, first come first served. Remote
/// images decode through one, so a burst of large images can't decode all at once.
public actor AsyncLimiter {
    public let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func acquire() async {
        if active < limit {
            active += 1
            return
        }
        // A caller that releases hands its slot straight to the first one waiting.
        await withCheckedContinuation { waiting.append($0) }
    }

    public func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
