import Foundation

/// Converts a time between places: `13.00 copenhagen time to new york time`, `3pm cet in pst`, `time in tokyo`,
/// `now in london`. `13.00` and `13:00` are always 13:00; a time without a date is today in the source zone. Places
/// are IANA zone cities (`Europe/Copenhagen` is "copenhagen"), some big cities that aren't zones, and a fixed table
/// of abbreviations. Summer time comes from the zone on the date in question, never from the abbreviation. The
/// clock and the current zone are parameters; nothing here reads them.
public enum TimeZoneConversion {
    public struct Place: Sendable, Equatable {
        public var zone: TimeZone
        /// As shown: "New York", or an abbreviation as typed, "PST".
        public var name: String
        public var isAbbreviation = false
    }

    public struct Result: Sendable, Equatable {
        public var source: Place
        public var target: Place
        /// The moment converted.
        public var date: Date
        /// No time was given: it's now.
        public var isNow: Bool
    }

    public static func evaluate(_ text: String, now: Date, timeZone: TimeZone) -> Result? {
        let query = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let here = Place(zone: timeZone, name: cityName(of: timeZone.identifier))
        // `time in tokyo`, `now in london`
        if let match = nowIn.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
            let range = Range(match.range(at: 1), in: query), let target = place(String(query[range]))
        {
            return Result(source: here, target: target, date: now, isNow: true)
        }
        // `<time> <place> (to|in) <place>`, with an optional `time` after each place.
        for match in separator.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            guard let split = Range(match.range, in: query) else { continue }
            var left = withoutTimeWord(String(query[..<split.lowerBound]).trimmingCharacters(in: .whitespaces))
            let right = withoutTimeWord(String(query[split.upperBound...]).trimmingCharacters(in: .whitespaces))
            let time = clockTime(in: &left)
            // Without a time or the word "time", `copenhagen to new york` is a search, not a conversion.
            guard time != nil || query.split(separator: " ").contains("time") else { continue }
            guard let target = place(right) else { continue }
            let source: Place
            if left.isEmpty {
                source = here
            } else if let place = place(left) {
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
        return nil
    }

    nonisolated(unsafe) private static let nowIn = try! NSRegularExpression(pattern: #"^(?:time|now)\s+in\s+(.+)$"#)
    // Lookarounds, so neither match uses up the spaces around it.
    nonisolated(unsafe) private static let separator = try! NSRegularExpression(pattern: #"(?<=\s)(?:to|in)(?=\s)"#)
    nonisolated(unsafe) private static let clock = try! NSRegularExpression(
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

    /// A place by name: an abbreviation from the table, a zone's city, or a big city that isn't a zone.
    public static func place(_ text: String) -> Place? {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let identifier = abbreviations[name], let zone = TimeZone(identifier: identifier) {
            return Place(zone: zone, name: name.uppercased(), isAbbreviation: true)
        }
        if let identifier = cities[name], let zone = TimeZone(identifier: identifier) {
            return Place(zone: zone, name: cityName(of: identifier))
        }
        if let identifier = otherCities[name], let zone = TimeZone(identifier: identifier) {
            return Place(zone: zone, name: name.split(separator: " ").map(\.capitalized).joined(separator: " "))
        }
        return nil
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
