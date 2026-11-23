import Foundation

/// Looks a place up by name, for the calculator's time zones (SPEC-162 B). The app's is Apple Maps; snapshot runs
/// get `InertPlaceLookup`, and tests a fake, so neither ever asks Apple.
public protocol PlaceLookup: Sendable {
    /// The place `name` names, shown by the name the lookup gives it, or nil when there's none with a time zone.
    /// Throws when the lookup failed or was throttled, which isn't an answer.
    func lookUp(_ name: String) async throws -> TimeZoneConversion.Place?
}

/// Answers nothing and sends nothing: a snapshot run's lookup, even with the setting on in its settings.
public struct InertPlaceLookup: PlaceLookup {
    public init() {}

    public func lookUp(_ name: String) async throws -> TimeZoneConversion.Place? { nil }
}

/// Looks up the places the calculator doesn't know, while **Look up other places with Apple Maps**
/// (`appleMapsPlaces`) is on. Only the names `TimeZoneConversion.namesToLookUp(in:places:)` allows go out, once the
/// typing has stopped for `wait`, one at a time; each answer is kept for the run, in memory, found or not, so a name
/// goes at most once. An answer to the query still typed calls `onChange`, and the card is evaluated again.
@MainActor
public final class PlaceLookups {
    /// The places found, by folded name (`PlaceTable.fold`), for `TimeZoneConversion.evaluate(lookedUp:)`. Empty
    /// while it's off.
    public private(set) var found: [String: TimeZoneConversion.Place] = [:]
    /// Called when `found` changes.
    public var onChange: () -> Void = {}

    private let makeLookup: () -> any PlaceLookup
    private let wait: @Sendable () async throws -> Void
    /// Held only while it's on.
    private var lookup: (any PlaceLookup)?
    private var notFound: Set<String> = []
    private var query: String?
    private var running: Task<Void, Never>?

    /// `makeLookup` is called when it's turned on. `wait` is the pause after the last keystroke, 400 ms.
    public init(
        enabled: Bool, makeLookup: @escaping () -> any PlaceLookup,
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) }
    ) {
        self.makeLookup = makeLookup
        self.wait = wait
        if enabled { lookup = makeLookup() }
    }

    public var isEnabled: Bool { lookup != nil }

    /// Turned off, it stops the lookup under way and forgets everything it found.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        running?.cancel()
        running = nil
        query = nil
        guard !enabled else {
            lookup = makeLookup()
            return
        }
        lookup = nil
        notFound = []
        guard !found.isEmpty else { return }
        found = [:]
        onChange()
    }

    /// The root query changed: the lookup under way stops, and the new query's names are looked up once the typing
    /// has stopped. `places` is the offline table, so a name it knows never goes.
    public func queryChanged(_ query: String, places: PlaceTable?) {
        guard query != self.query else { return }
        self.query = query
        running?.cancel()
        running = nil
        guard let lookup else { return }
        let names = TimeZoneConversion.namesToLookUp(in: query, places: places, lookedUp: found).filter {
            !isAnswered($0)
        }
        guard !names.isEmpty else { return }
        let wait = wait
        running = Task { [weak self] in
            do { try await wait() } catch { return }
            for name in names {
                guard !Task.isCancelled, let self else { return }
                guard !self.isAnswered(name) else { continue }
                let place: TimeZoneConversion.Place?
                do {
                    place = try await lookup.lookUp(name)
                } catch {
                    // Throttled, failed or stopped: not an answer, so the next query asks again.
                    return
                }
                // Stopped by a new query or the switch: whatever came back isn't kept.
                guard !Task.isCancelled else { return }
                let key = PlaceTable.fold(name)
                guard let place else {
                    self.notFound.insert(key)
                    continue
                }
                self.found[key] = place
                if self.query == query { self.onChange() }
            }
        }
    }

    private func isAnswered(_ name: String) -> Bool {
        let key = PlaceTable.fold(name)
        return found[key] != nil || notFound.contains(key)
    }

    /// Until the lookups under way have finished, for tests.
    func settled() async {
        await running?.value
    }
}
