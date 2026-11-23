import Foundation

/// Converts a time between places: `13.00 copenhagen time to new york time`, `3pm cet in pst`, `time in tokyo`,
/// `now in london`, `gmt+2 to utc`, `denmark time`. `13.00` and `13:00` are always 13:00; a time without a date is
/// today in the source zone. Places are, in this order: a fixed table of abbreviations, offsets from UTC, IANA zone
/// cities (`Europe/Copenhagen` is "copenhagen"), some big cities that aren't zones, and with a `PlaceTable`, the
/// countries one clock covers and GeoNames' towns. Summer time comes from the zone on the date in question, never
/// from the abbreviation. The clock and the current zone are parameters; nothing here reads them.
public enum TimeZoneConversion {
    public struct Place: Sendable, Equatable {
        public var zone: TimeZone
        /// As shown: "New York", an abbreviation as typed, "PST", or an offset, "GMT+5:30".
        public var name: String
        public var isAbbreviation = false
        /// An offset from UTC, shown by its name alone.
        public var isOffset = false
    }

    public struct Result: Sendable, Equatable {
        public var source: Place
        public var target: Place
        /// The moment converted.
        public var date: Date
        /// No time was given: it's now.
        public var isNow: Bool
    }

    /// `places` adds the countries and towns; without it, only the abbreviations, offsets and cities are known.
    public static func evaluate(_ text: String, now: Date, timeZone: TimeZone, places: PlaceTable? = nil) -> Result? {
        let query = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let here = Place(zone: timeZone, name: cityName(of: timeZone.identifier))
        // `time in tokyo`, `now in london`
        if let match = nowIn.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
            let range = Range(match.range(at: 1), in: query), let target = place(String(query[range]), places: places)
        {
            return Result(source: here, target: target, date: now, isNow: true)
        }
        // `<time> <place> (to|in) <place>`, with an optional `time` after each place.
        for match in separator.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            guard let split = Range(match.range, in: query) else { continue }
            var left = withoutTimeWord(String(query[..<split.lowerBound]).trimmingCharacters(in: .whitespaces))
            let right = withoutTimeWord(String(query[split.upperBound...]).trimmingCharacters(in: .whitespaces))
            let time = clockTime(in: &left)
            // Without a time or the word "time", `copenhagen to new york` is a search, not a conversion, but
            // `gmt+2 to utc` and `cet to pst` name nothing else.
            guard
                time != nil || query.split(separator: " ").contains("time")
                    || (!left.isEmpty && !right.isEmpty && isZoneName(left) && isZoneName(right))
            else { continue }
            guard let target = place(right, places: places) else { continue }
            let source: Place
            if left.isEmpty {
                source = here
            } else if let place = place(left, places: places) {
                source = place
            } else {
                continue
            }
            guard let time else { return Result(source: source, target: target, date: now, isNow: true) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = source.zone
            var day = calendar.dateComponents([.year, .month, .day], from: now)
            day.hour = time.hour
            day.minute = time.minute
            guard let date = calendar.date(from: day) else { continue }
            return Result(source: source, target: target, date: date, isNow: false)
        }
        // `denmark time`, `utc time`: the time there now, but never in a town, since `sunrise time`, `spring time`
        // and `tea time` would each find one.
        if query.hasSuffix(" time"),
            let target = place(String(query.dropLast(" time".count)), places: places, towns: false)
        {
            return Result(source: here, target: target, date: now, isNow: true)
        }
        return nil
    }

    private static let nowIn = try! NSRegularExpression(pattern: #"^(?:time|now)\s+in\s+(.+)$"#)
    // Lookarounds, so neither match uses up the spaces around it.
    private static let separator = try! NSRegularExpression(pattern: #"(?<=\s)(?:to|in)(?=\s)"#)
    private static let clock = try! NSRegularExpression(
        pattern: #"(?:^|\s)(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?(?=\s|$)"#)

    private static func withoutTimeWord(_ text: String) -> String {
        text.split(separator: " ").filter { $0 != "time" }.joined(separator: " ")
    }

    /// Takes a clock time (`13.00`, `13:00`, `3pm`, `3:30 pm`, `9`) out of `text`.
    private static func clockTime(in text: inout String) -> (hour: Int, minute: Int)? {
        guard let match = clock.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let whole = Range(match.range, in: text), let hourRange = Range(match.range(at: 1), in: text),
            var hour = Int(text[hourRange])
        else { return nil }
        let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let meridiem = Range(match.range(at: 3), in: text).map { String(text[$0]) }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        text.removeSubrange(whole)
        text = text.trimmingCharacters(in: .whitespaces)
        return (hour, minute)
    }

    /// A place by its lowercased name, the first of: an abbreviation from the table, an offset (`gmt+2`), a zone's
    /// city, a big city that isn't a zone, and from `places`, a country, then (unless `towns` is false) a town's own or
    /// ASCII name and a town's alternate name. A word the unit or currency conversions know is only ever one of the
    /// first four, so `places` never takes `5 kgs to lbs` or `10 cad to hkd` away (SPEC-162, note 7.1), and neither
    /// is a state or province name (`states`).
    public static func place(_ text: String, places: PlaceTable? = nil, towns: Bool = true) -> Place? {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let identifier = abbreviations[name], let zone = TimeZone(identifier: identifier) {
            return Place(zone: zone, name: name.uppercased(), isAbbreviation: true)
        }
        if let offset = offset(name) { return offset }
        if let identifier = cities[name], let zone = TimeZone(identifier: identifier) {
            return Place(zone: zone, name: cityName(of: identifier))
        }
        if let identifier = otherCities[name], let zone = TimeZone(identifier: identifier) {
            return Place(zone: zone, name: name.split(separator: " ").map(\.capitalized).joined(separator: " "))
        }
        guard let places, !UnitConversion.knows(name), !CurrencyConversion.knows(name) else { return nil }
        let key = PlaceTable.fold(name)
        guard !states.contains(key),
            let found = places.country(key) ?? (towns ? places.town(key) ?? places.townByAlternateName(key) : nil)
        else { return nil }
        return Place(zone: found.zone, name: found.name)
    }

    /// The states and provinces of the US, Canada and Australia, folded (`PlaceTable.fold`). They have several
    /// clocks or share a name with a town elsewhere (`arizona` is in Honduras, `ontario` in California, `georgia`
    /// is a country), so the table never answers for them, and they give no card unless an earlier table knows them.
    static let states: Set<String> = Set(
        [
            "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado", "Connecticut", "Delaware",
            "District of Columbia", "Florida", "Georgia", "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa", "Kansas",
            "Kentucky", "Louisiana", "Maine", "Maryland", "Massachusetts", "Michigan", "Minnesota", "Mississippi",
            "Missouri", "Montana", "Nebraska", "Nevada", "New Hampshire", "New Jersey", "New Mexico", "New York",
            "North Carolina", "North Dakota", "Ohio", "Oklahoma", "Oregon", "Pennsylvania", "Rhode Island",
            "South Carolina", "South Dakota", "Tennessee", "Texas", "Utah", "Vermont", "Virginia", "Washington",
            "West Virginia", "Wisconsin", "Wyoming",
            // Canada
            "Alberta", "British Columbia", "Manitoba", "New Brunswick", "Newfoundland and Labrador",
            "Northwest Territories", "Nova Scotia", "Nunavut", "Ontario", "Prince Edward Island", "Quebec",
            "Saskatchewan", "Yukon",
            // Australia
            "Australian Capital Territory", "New South Wales", "Northern Territory", "Queensland", "South Australia",
            "Tasmania", "Victoria", "Western Australia",
        ].map(PlaceTable.fold))

    /// Whether `name` is an abbreviation or an offset, the names that convert without a time or the word "time".
    private static func isZoneName(_ name: String) -> Bool {
        abbreviations[name] != nil || offset(name) != nil
    }

    // `utc` or `gmt`, a sign, then `h`, `hh`, `h:mm`, `hh:mm` or `hhmm`, with no space after the sign.
    private static let offsetPattern = try! NSRegularExpression(
        pattern: #"^(utc|gmt)\s*([+\-\x{2212}])(?:(\d{1,2})(?::(\d{2}))?|(\d{2})(\d{2}))$"#)

    /// An offset from UTC (`gmt+2`, `utc-0530`, `utc+5:30`), hours 0 to 14 and minutes 0 to 59, named as typed but
    /// normalized: `GMT+5:30`, `UTC+0`. It's a fixed offset, never `Etc/GMT-2`, whose sign is the other way round.
    static func offset(_ name: String) -> Place? {
        guard let match = offsetPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: name).map { String(name[$0]) }
        }
        guard let prefix = group(1), let sign = group(2), let hours = Int(group(3) ?? group(5) ?? ""),
            let minutes = Int(group(4) ?? group(6) ?? "0"), (0...14).contains(hours), (0...59).contains(minutes)
        else { return nil }
        let negative = sign != "+" && hours * 60 + minutes != 0
        guard let zone = TimeZone(secondsFromGMT: (negative ? -1 : 1) * (hours * 3600 + minutes * 60)) else {
            return nil
        }
        let shownMinutes = minutes == 0 ? "" : minutes < 10 ? ":0\(minutes)" : ":\(minutes)"
        let shown = prefix.uppercased() + (negative ? "-" : "+") + "\(hours)\(shownMinutes)"
        return Place(zone: zone, name: shown, isOffset: true)
    }

    /// The city of a zone identifier, as shown: `America/New_York` is "New York".
    static func cityName(of identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// The abbreviation a zone goes by at `date`: its standard or summer one from `named` (CET or CEST, PST or PDT),
    /// else Foundation's, which for many zones is an offset (`GMT+1`).
    public static func abbreviation(of zone: TimeZone, at date: Date) -> String {
        if let (standard, summer) = named[zone.identifier] {
            return zone.isDaylightSavingTime(for: date) ? summer : standard
        }
        return zone.abbreviation(for: date) ?? zone.identifier
    }

    /// The abbreviation a place typed as one shows at `date`: the standard or summer one of the zone the table maps it
    /// to (`pst` in July is PDT). It's looked up by the table's identifier, not the zone's, since Foundation names the
    /// `UTC` zone `GMT`. Any other place shows its zone's (`abbreviation(of:at:)`).
    public static func abbreviation(of place: Place, at date: Date) -> String {
        guard place.isAbbreviation, let identifier = abbreviations[place.name.lowercased()],
            let (standard, summer) = named[identifier]
        else { return abbreviation(of: place.zone, at: date) }
        return place.zone.isDaylightSavingTime(for: date) ? summer : standard
    }

    /// The standard and summer abbreviations of the zones `abbreviations` maps to, and of other zones for which
    /// Foundation only has an offset (`GMT+1`). Only for display: `abbreviations` decides what can be typed. Asia/
    /// Shanghai stays `GMT+8`, because "CST" reads as US Central.
    static let named: [String: (String, String)] = {
        var named: [String: (String, String)] = [
            "UTC": ("UTC", "UTC"), "GMT": ("GMT", "GMT"), "Europe/Athens": ("EET", "EEST"),
            "Europe/Lisbon": ("WET", "WEST"), "Europe/London": ("GMT", "BST"), "America/New_York": ("EST", "EDT"),
            "America/Chicago": ("CST", "CDT"), "America/Denver": ("MST", "MDT"), "America/Los_Angeles": ("PST", "PDT"),
            "Asia/Tokyo": ("JST", "JST"), "Asia/Kolkata": ("IST", "IST"), "Australia/Sydney": ("AEST", "AEDT"),
            "America/Toronto": ("EST", "EDT"), "America/Detroit": ("EST", "EDT"), "America/Vancouver": ("PST", "PDT"),
            "America/Phoenix": ("MST", "MST"), "Australia/Melbourne": ("AEST", "AEDT"),
            "Australia/Brisbane": ("AEST", "AEST"), "Pacific/Auckland": ("NZST", "NZDT"), "Asia/Seoul": ("KST", "KST"),
            "Asia/Singapore": ("SGT", "SGT"), "Asia/Hong_Kong": ("HKT", "HKT"),
        ]
        let central = [
            "Amsterdam", "Andorra", "Belgrade", "Berlin", "Bratislava", "Brussels", "Budapest", "Copenhagen",
            "Ljubljana", "Luxembourg", "Madrid", "Malta", "Monaco", "Oslo", "Paris", "Prague", "Rome", "Stockholm",
            "Tirane", "Vienna", "Warsaw", "Zagreb", "Zurich",
        ]
        // Kyiv also goes by its old identifier, which macOS still lists and may report as the current zone.
        let eastern = ["Bucharest", "Helsinki", "Kyiv", "Kiev", "Riga", "Sofia", "Tallinn", "Vilnius"]
        for city in central { named["Europe/\(city)"] = ("CET", "CEST") }
        for city in eastern { named["Europe/\(city)"] = ("EET", "EEST") }
        return named
    }()

    /// Each abbreviation maps to one zone. IST is India's, and CST is the US's Central time.
    static let abbreviations: [String: String] = [
        "utc": "UTC", "gmt": "GMT", "cet": "Europe/Berlin", "cest": "Europe/Berlin", "eet": "Europe/Athens",
        "eest": "Europe/Athens", "wet": "Europe/Lisbon", "bst": "Europe/London", "est": "America/New_York",
        "edt": "America/New_York", "cst": "America/Chicago", "cdt": "America/Chicago", "mst": "America/Denver",
        "mdt": "America/Denver", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "jst": "Asia/Tokyo",
        "ist": "Asia/Kolkata", "aest": "Australia/Sydney", "aedt": "Australia/Sydney",
    ]

    /// Every IANA zone by its city, lowercased: "new york" → America/New_York.
    static let cities: [String: String] = {
        var cities: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers where identifier.contains("/") {
            let city = cityName(of: identifier).lowercased()
            if cities[city] == nil { cities[city] = identifier }
        }
        return cities
    }()

    /// Big cities that aren't zone names.
    static let otherCities: [String: String] = [
        "san francisco": "America/Los_Angeles", "seattle": "America/Los_Angeles",
        "las vegas": "America/Los_Angeles", "san diego": "America/Los_Angeles", "boston": "America/New_York",
        "washington": "America/New_York", "washington dc": "America/New_York", "miami": "America/New_York",
        "nyc": "America/New_York", "philadelphia": "America/New_York", "atlanta": "America/New_York",
        "dallas": "America/Chicago", "houston": "America/Chicago", "austin": "America/Chicago",
        "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "beijing": "Asia/Shanghai",
        "shenzhen": "Asia/Shanghai", "osaka": "Asia/Tokyo", "kyoto": "Asia/Tokyo", "aarhus": "Europe/Copenhagen",
        "odense": "Europe/Copenhagen", "munich": "Europe/Berlin", "hamburg": "Europe/Berlin",
        "frankfurt": "Europe/Berlin", "barcelona": "Europe/Madrid", "milan": "Europe/Rome",
        "geneva": "Europe/Zurich", "gothenburg": "Europe/Stockholm", "manchester": "Europe/London",
        "edinburgh": "Europe/London", "montreal": "America/Toronto", "kiev": "Europe/Kyiv",
    ]
}
