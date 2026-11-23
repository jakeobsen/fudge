import Foundation

/// The towns and countries the calculator knows besides its own tables (SPEC-162): GeoNames' towns of 15,000 people
/// or more, and the countries one clock covers. It's read from `places.tsv` and `countries.tsv`, which
/// `scripts/geonames/make-places.py` writes into `runtime/vendor/geonames/` and `make app` copies into
/// `Contents/Resources/places/`.
///
/// Names are matched folded (`fold`), so `malmo` finds Malmö, and a town's ASCII name is a name too (`hillerod`).
/// A town is shown by its own name. When towns share a name, the bigger one has it, but a town's own name always
/// beats another town's alternate name.
public struct PlaceTable: Sendable {
    /// A place the table knows, as shown.
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var zone: TimeZone
        public var population: Int
    }

    /// By the folded name and ASCII name of each town.
    private var names: [String: Entry] = [:]
    /// By the folded alternate names of each town.
    private var alternates: [String: Entry] = [:]
    /// By the folded English name of each country that one clock covers.
    private var countries: [String: Entry] = [:]

    /// A country answers when the zones sharing one clock hold at least this share of its towns' people.
    static let countryShare = 0.9

    /// The table from the two files' text. `now` sets the year whose clocks decide which zones keep the same time.
    /// A row with a missing column, a population that isn't a number or a zone Foundation doesn't know is skipped.
    public init(places: String, countries countryText: String, now: Date) {
        var zones: [Substring: TimeZone?] = [:]
        // Each country's people by zone, for the countries below.
        var people: [Substring: [String: Int]] = [:]
        for line in places.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 6, !columns[0].isEmpty, !columns[2].isEmpty, let population = Int(columns[3])
            else { continue }
            let zone: TimeZone
            if let known = zones[columns[4]] {
                guard let known else { continue }
                zone = known
            } else {
                let found = TimeZone(identifier: String(columns[4]))
                zones[columns[4]] = found
                guard let found else { continue }
                zone = found
            }
            let entry = Entry(name: String(columns[0]), zone: zone, population: population)
            Self.add(entry, as: columns[0], to: &names)
            if !columns[1].isEmpty { Self.add(entry, as: columns[1], to: &names) }
            for alternate in columns[5].split(separator: "|") { Self.add(entry, as: alternate, to: &alternates) }
            people[columns[2], default: [:]][zone.identifier, default: 0] += population
        }
        var countryNames: [Substring: String] = [:]
        for line in countryText.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 2, !columns[0].isEmpty, !columns[1].isEmpty else { continue }
            countryNames[columns[0]] = String(columns[1])
        }
        var clocks: [String: Clock] = [:]
        for (code, byZone) in people {
            guard let name = countryNames[code],
                let identifier = Self.zoneOfCountry(byZone, now: now, clocks: &clocks),
                let zone = TimeZone(identifier: identifier)
            else { continue }
            countries[Self.fold(name)] = Entry(name: name, zone: zone, population: byZone.values.reduce(0, +))
        }
    }

    /// The table in `folder` (`places.tsv` and `countries.tsv`), or nil when either can't be read, as in `swift run`,
    /// where the app has no `Contents/Resources/places/`.
    public static func load(from folder: URL, now: Date) -> PlaceTable? {
        guard let places = try? String(contentsOf: folder.appendingPathComponent("places.tsv"), encoding: .utf8),
            let countries = try? String(contentsOf: folder.appendingPathComponent("countries.tsv"), encoding: .utf8)
        else { return nil }
        return PlaceTable(places: places, countries: countries, now: now)
    }

    /// How names are matched: without case or diacritics, so `Malmö`, `malmo` and `MALMÖ` are one name.
    public static func fold(_ name: some StringProtocol) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The country called `name` (folded), when one clock covers it.
    public func country(_ name: String) -> Entry? { countries[name] }

    /// The town whose own name or ASCII name is `name` (folded).
    public func town(_ name: String) -> Entry? { names[name] }

    /// The town that has `name` (folded) as an alternate name.
    public func townByAlternateName(_ name: String) -> Entry? { alternates[name] }

    /// The number of countries one clock covers.
    public var countryCount: Int { countries.count }

    private static func add(_ entry: Entry, as name: Substring, to table: inout [String: Entry]) {
        let key = fold(name)
        // The first of equal towns keeps the name, so the file's order decides a tie.
        if let held = table[key], held.population >= entry.population { return }
        table[key] = entry
    }

    /// What a zone's clock does in a year: its offset at the start and each change, with the offset after it. Two
    /// zones with the same `Clock` show the same time all year.
    struct Clock: Hashable {
        var offset: Int
        var changes: [Int]

        init(_ zone: TimeZone, year: DateInterval) {
            offset = zone.secondsFromGMT(for: year.start)
            changes = []
            var date = year.start
            while let change = zone.nextDaylightSavingTimeTransition(after: date), change < year.end {
                changes += [Int(change.timeIntervalSince1970), zone.secondsFromGMT(for: change)]
                date = change
            }
        }
    }

    /// The zone a country answers with: the most populous zone of the clock that covers at least `countryShare` of
    /// its people, or nil when no clock does.
    static func zoneOfCountry(_ people: [String: Int], now: Date, clocks: inout [String: Clock]) -> String? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let year = utc.dateInterval(of: .year, for: now) else { return nil }
        var byClock: [Clock: [String: Int]] = [:]
        for (identifier, population) in people {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            let clock = clocks[identifier] ?? Clock(zone, year: year)
            clocks[identifier] = clock
            byClock[clock, default: [:]][identifier] = population
        }
        let total = people.values.reduce(0, +)
        guard total > 0,
            let covering = byClock.values.first(where: {
                Double($0.values.reduce(0, +)) >= countryShare * Double(total)
            })
        else { return nil }
        // The most populous zone, and of equal ones the first by identifier, so the answer never depends on order.
        return covering.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }
}
