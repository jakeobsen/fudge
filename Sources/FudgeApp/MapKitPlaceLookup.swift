import FudgeCore
import MapKit

/// The calculator's Apple Maps lookup (SPEC-162 B): a text search for addresses, with no region and no location, and
/// the first place with a time zone. `PlaceLookups` (core) decides what's looked up and when; this is only the call.
/// Snapshot runs and tests never make one.
struct MapKitPlaceLookup: PlaceLookup {
    func lookUp(_ name: String) async throws -> TimeZoneConversion.Place? {
        let request = MKLocalSearch.Request(naturalLanguageQuery: name)
        request.resultTypes = .address
        let search = SearchBox(MKLocalSearch(request: request))
        let response: MKLocalSearch.Response
        do {
            response = try await withTaskCancellationHandler {
                try await search.search.start()
            } onCancel: {
                search.search.cancel()
            }
        } catch let error as MKError where error.code == .placemarkNotFound {
            return nil
        }
        guard let item = response.mapItems.first(where: { $0.timeZone != nil }), let zone = item.timeZone else {
            return nil
        }
        return TimeZoneConversion.Place(zone: zone, name: item.name ?? name)
    }

    /// `cancel()` may be called from any thread, and the search is used by nothing else.
    private final class SearchBox: @unchecked Sendable {
        let search: MKLocalSearch
        init(_ search: MKLocalSearch) { self.search = search }
    }
}
