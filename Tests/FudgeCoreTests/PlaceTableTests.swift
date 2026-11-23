import Foundation
import Testing

@testable import FudgeCore

private let enGB = Locale(identifier: "en_GB")
private let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!

/// 10:00 UTC on 15 January 2026.
private let january: Date = {
    var components = DateComponents(year: 2026, month: 1, day: 15, hour: 10)
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components)!
}()

/// The committed files in `runtime/vendor/geonames/`.
private let vendorFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("runtime/vendor/geonames", isDirectory: true)

/// The committed table, read once for all the tests (about 20 MB, and 0.2 s or more each time it's read).
private let committed: PlaceTable = PlaceTable.load(from: vendorFolder, now: january)!

private func card(_ query: String, places: PlaceTable? = committed) -> CalculatorResult? {
    Calculator.evaluate(query, locale: enGB, now: january, timeZone: copenhagen, places: places)
}

private func zone(_ name: String, in places: PlaceTable = committed) -> String? {
    TimeZoneConversion.place(name, places: places)?.zone.identifier
}

struct PlaceTableTests {
    // MARK: - PlaceTable on small tables

    private func table(_ places: [String], countries: [String] = []) -> PlaceTable {
        PlaceTable(
            places: places.joined(separator: "\n") + "\n", countries: countries.joined(separator: "\n") + "\n",
            now: january)
    }

    @Test func namesAreFoldedAndTheASCIINameIsAName() throws {
        let places = table([
            "Malmö\t\tSE\t362133\tEurope/Stockholm\t",
            "São Paulo\tSao Paulo\tBR\t12400232\tAmerica/Sao_Paulo\t",
            "Hillerød\tHillerod\tDK\t35357\tEurope/Copenhagen\t",
        ])
        #expect(zone("malmo", in: places) == "Europe/Stockholm", "folded: no diacritics")
        #expect(zone("malmö", in: places) == "Europe/Stockholm")
        #expect(zone("são paulo", in: places) == "America/Sao_Paulo")
        #expect(zone("sao paulo", in: places) == "America/Sao_Paulo")
        #expect(zone("hillerød", in: places) == "Europe/Copenhagen")
        #expect(zone("hillerod", in: places) == "Europe/Copenhagen", "ø isn't a diacritic: the ASCII name finds it")
        #expect(TimeZoneConversion.place("hillerod", places: places)?.name == "Hillerød", "shown by its own name")
        #expect(PlaceTable.fold("MALMÖ") == PlaceTable.fold("malmo"))
    }

    @Test func theBiggerTownHasASharedName() throws {
        // Each pair in both orders, so neither the file's order nor the smaller town decides.
        let places = table([
            "Paris\t\tUS\t25171\tAmerica/Chicago\t",
            "Paris\t\tFR\t2138551\tEurope/Paris\t",
            "Springfield\t\tUS\t169176\tAmerica/Chicago\t",
            "Springfield\t\tUS\t155929\tAmerica/New_York\t",
        ])
        #expect(zone("paris", in: places) == "Europe/Paris")
        #expect(zone("springfield", in: places) == "America/Chicago")
    }

    @Test func aTownsOwnNameBeatsABiggerTownsAlternateName() throws {
        let places = table([
            "Big City\t\tXX\t5000000\tAsia/Tokyo\tSunrise|Old Town",
            "Sunrise\t\tUS\t84439\tAmerica/New_York\t",
        ])
        #expect(zone("sunrise", in: places) == "America/New_York")
        #expect(zone("old town", in: places) == "Asia/Tokyo", "an alternate name finds its town")
        #expect(TimeZoneConversion.place("old town", places: places)?.name == "Big City")
    }

    @Test func badRowsAreSkipped() throws {
        let places = table([
            "Short\t\tDK\t1000\tEurope/Copenhagen",
            "Nowhere\t\tDK\t1000\tMars/Olympus_Mons\t",
            "Uncounted\t\tDK\tmany\tEurope/Copenhagen\t",
            "\t\tDK\t1000\tEurope/Copenhagen\tNameless",
            "Roskilde\t\tDK\t51916\tEurope/Copenhagen\t",
        ])
        #expect(zone("short", in: places) == nil, "a missing column")
        #expect(zone("nowhere", in: places) == nil, "a zone Foundation doesn't know")
        #expect(zone("uncounted", in: places) == nil, "a population that isn't a number")
        #expect(zone("nameless", in: places) == nil, "no name")
        #expect(zone("roskilde", in: places) == "Europe/Copenhagen")
    }

    @Test func aCountryAnswersWhenOneClockCoversNinetyPercentOfItsPeople() throws {
        let places = table(
            [
                "Roskilde\t\tDK\t51916\tEurope/Copenhagen\t",
                "A\t\tXA\t90\tEurope/Paris\t", "B\t\tXA\t10\tAmerica/New_York\t",
                "C\t\tXB\t89\tEurope/Paris\t", "D\t\tXB\t11\tAmerica/New_York\t",
                // Bangkok and Ho Chi Minh City keep the same clock, so together they're 95%.
                "E\t\tXC\t50\tAsia/Bangkok\t", "F\t\tXC\t45\tAsia/Ho_Chi_Minh\t", "G\t\tXC\t5\tAsia/Tokyo\t",
            ],
            countries: [
                "DK\tDenmark", "XA\tNinety Land", "XB\tEighty-Nine Land", "XC\tTwo Zones Land", "XD\tEmpty Land",
            ])
        #expect(zone("denmark", in: places) == "Europe/Copenhagen")
        #expect(TimeZoneConversion.place("denmark", places: places)?.name == "Denmark")
        #expect(zone("ninety land", in: places) == "Europe/Paris", "90% is enough")
        #expect(zone("eighty-nine land", in: places) == nil, "89% isn't")
        #expect(zone("two zones land", in: places) == "Asia/Bangkok", "one clock, its most populous zone")
        #expect(zone("empty land", in: places) == nil, "no towns")
        #expect(places.countryCount == 3)
    }

    @Test func theTableIsntThereWithoutItsFiles() {
        #expect(PlaceTable.load(from: URL(fileURLWithPath: "/nonexistent/places"), now: january) == nil)
    }

    // MARK: - The committed files

    @Test func theCommittedFilesAreWhole() throws {
        let places = try String(contentsOf: vendorFolder.appendingPathComponent("places.tsv"), encoding: .utf8)
        let countries = try String(contentsOf: vendorFolder.appendingPathComponent("countries.tsv"), encoding: .utf8)
        #expect(!places.contains("\u{2014}") && !countries.contains("\u{2014}"), "Fudge never shows an em dash")
        let rows = places.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(rows.count >= 30_000)
        var zones: Set<Substring> = []
        for row in rows {
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
            #expect(columns.count == 6 && !columns[0].isEmpty && Int(columns[3]) != nil, "\(row)")
            if columns.count == 6 { zones.insert(columns[4]) }
        }
        #expect(zones.filter { TimeZone(identifier: String($0)) == nil }.isEmpty, "every zone resolves")
        let countryRows = countries.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(countryRows.count >= 240)
        #expect(countryRows.allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 2 })
        #expect(committed.countryCount > 200)
    }

    @Test func theOrderOfTheTables() throws {
        #expect(zone("armenia") == "Asia/Yerevan", "the country, before the town in Colombia")
        #expect(zone("jamaica") == "America/Jamaica", "the zone's city, before the town in New York")
        #expect(zone("london") == "Europe/London")
        #expect(committed.town("london")?.zone.identifier == "Europe/London", "London, England, over London, Ontario")
        #expect(zone("china") == "Asia/Shanghai")
        #expect(zone("canada") == nil, "several clocks")
        #expect(zone("united states") == nil, "several clocks")
    }

    @Test func whatTheUserSees() throws {
        let roskilde = try #require(card("roskilde time to kouvola time"))
        #expect(roskilde.questionLabel == "now, Roskilde")
        #expect(roskilde.answerLabel == "Kouvola, EET")
        let threePM = try #require(card("3pm roskilde to kouvola"))
        #expect(threePM.questionLabel == "15:00, Roskilde")
        #expect(threePM.answer == "15 January 2026 at 16:00")
        #expect(threePM.answerLabel == "Kouvola, EET")
        for query in ["time in københavn", "time in cph", "time in kobenhavn"] {
            #expect(card(query)?.answerLabel == "Copenhagen, CET", "\(query)")
        }
        #expect(card("time in malmö")?.answerLabel == "Malmö, CET")
        #expect(card("time in malmo")?.answerLabel == "Malmö, CET")
        #expect(card("time in hillerod")?.answerLabel == "Hillerød, CET")
        #expect(card("time in roskilde")?.answerLabel == "Roskilde, CET")
        #expect(card("time in china")?.answerLabel == "China, GMT+8")
        #expect(card("time in spain")?.answerLabel == "Spain, CET", "the Canary Islands are under 10%")
        #expect(card("time in canada") == nil)
        #expect(card("time in united states") == nil)
        #expect(card("copenhagen to new york") == nil, "a search, as today")
        #expect(card("time in hirtshals") == nil, "not in the list")
    }

    @Test func unitAndCurrencyQueriesStayThemselves() throws {
        #expect(card("5 kgs to lbs")?.kind == .units)
        #expect(card("3 bar to psi")?.kind == .units)
        #expect(card("10 cad to hkd")?.kind == .currency)
    }

    @Test(arguments: [
        "tea time", "nap time", "run time", "screen time", "sunrise time", "spring time", "roskilde time",
    ])
    func placeTimeIsNeverATown(_ query: String) {
        #expect(card(query) == nil)
    }

    @Test func placeTimeAnswersFromTheOtherTables() throws {
        let denmark = try #require(card("denmark time"))
        #expect(denmark.questionLabel == "now, Copenhagen")
        #expect(denmark.answerLabel == "Denmark, CET")
        #expect(card("utc time")?.answerLabel == "UTC")
        #expect(card("copenhagen time")?.answerLabel == "Copenhagen, CET")
        #expect(card("gmt+2 time")?.answerLabel == "GMT+2")
    }

    @Test(arguments: ["arizona", "colorado", "ontario", "virginia", "georgia", "queensland"])
    func stateAndProvinceNamesGiveNoCard(_ name: String) {
        #expect(card("time in \(name)") == nil)
        #expect(zone(name) == nil)
    }

    @Test func aStateNameAnEarlierTableKnowsStillAnswers() throws {
        #expect(zone("new york") == "America/New_York", "a zone's city")
        #expect(zone("washington") == "America/New_York", "otherCities")
    }

    /// Note 7.1: no unit or currency word ever becomes a country or a town, so with the table every `5 <a> to <b>`
    /// converts in time zones exactly as it does without it.
    @Test func unitAndCurrencyWordsNeverBecomePlaces() throws {
        var spellings: [String: [String]] = [:]
        for (spelling, known) in UnitConversion.table {
            spellings[type(of: known.unit).baseUnit().symbol, default: []].append(spelling)
        }
        var pairs = spellings.values.flatMap { names in names.flatMap { a in names.map { b in (a, b) } } }
        let currencies: [String] =
            CurrencyConversion.codes.flatMap { [$0, $0.lowercased()] } + Array(CurrencyConversion.symbols.keys)
            + ["kr", "KR"]
        pairs += currencies.flatMap { a in currencies.map { b in (a, b) } }
        var differ: [String] = []
        for (a, b) in pairs {
            let query = "5 \(a) to \(b)"
            let with = TimeZoneConversion.evaluate(query, now: january, timeZone: copenhagen, places: committed)
            if with != TimeZoneConversion.evaluate(query, now: january, timeZone: copenhagen) { differ.append(query) }
        }
        #expect(pairs.count > 5_000)
        #expect(differ.isEmpty, "\(differ.prefix(20))")
    }

    // MARK: - Offsets

    @Test(arguments: [
        ("gmt+2", "GMT+2", 7200), ("gmt +2", "GMT+2", 7200), ("utc+02", "UTC+2", 7200), ("utc+5:30", "UTC+5:30", 19800),
        ("utc+05:30", "UTC+5:30", 19800), ("gmt+0530", "GMT+5:30", 19800), ("utc-3", "UTC-3", -10800),
        ("utc\u{2212}3", "UTC-3", -10800), ("utc-0", "UTC+0", 0), ("utc+14", "UTC+14", 50400),
        ("utc-9:30", "UTC-9:30", -34200),
    ])
    func offsets(_ typed: String, _ shown: String, _ seconds: Int) throws {
        let place = try #require(TimeZoneConversion.place(typed))
        #expect(place.name == shown)
        #expect(place.isOffset)
        #expect(place.zone.secondsFromGMT(for: january) == seconds)
    }

    @Test(arguments: ["utc+15", "utc+5:60", "utc+ 2", "utc+530", "utc+2:3", "gmt2", "utc+", "cet+1"])
    func notOffsets(_ typed: String) {
        #expect(TimeZoneConversion.place(typed) == nil)
    }

    @Test func offsetsConvertBothWays() throws {
        let now = try #require(card("gmt+2 to utc", places: nil))
        #expect(now.questionLabel == "now, GMT+2")
        #expect(now.answerLabel == "UTC")
        #expect(card("14:00 gmt+2 to utc", places: nil)?.answer == "15 January 2026 at 12:00", "GMT+2 is ahead of UTC")
        #expect(card("14:00 utc to gmt-3", places: nil)?.answer == "15 January 2026 at 11:00")
        let india = try #require(card("14:00 utc+5:30 to cet", places: nil))
        #expect(india.questionLabel == "14:00, UTC+5:30")
        #expect(india.answerLabel == "CET")
        #expect(india.answer == "15 January 2026 at 09:30")
        #expect(
            card("12:00 cet to gmt+0530", places: nil)?.answerLabel == "GMT+5:30", "no abbreviation after an offset")
    }

    @Test func abbreviationsAndOffsetsConvertWithoutATime() throws {
        #expect(card("cet to pst", places: nil)?.answerLabel == "PST")
        #expect(card("utc-5 in gmt+1", places: nil)?.answerLabel == "GMT+1")
        #expect(card("copenhagen to new york", places: nil) == nil, "city names still need a time or the word time")
        #expect(card("cet to new york", places: nil) == nil)
    }

    /// Foundation names the `UTC` zone `GMT`; a typed `utc` is still shown as UTC.
    @Test func aTypedAbbreviationIsShownByTheTablesZone() throws {
        #expect(card("12:00 cst in utc", places: nil)?.answerLabel == "UTC")
        #expect(card("12:00 utc in cst", places: nil)?.questionLabel == "12:00, UTC")
        #expect(card("12:00 cst in gmt", places: nil)?.answerLabel == "GMT")
        #expect(card("3pm cet in pst", places: nil)?.answerLabel == "PST")
    }
}
