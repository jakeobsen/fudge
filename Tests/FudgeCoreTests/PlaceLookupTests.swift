import Foundation
import Testing

@testable import FudgeCore

private let copenhagen = TimeZone(identifier: "Europe/Copenhagen")!
private let hirtshals = TimeZoneConversion.Place(zone: copenhagen, name: "Hirtshals")

/// What a lookup was asked, in order, with the waits between; nothing goes to Apple.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

/// Answers from `answers` (else not found), throws for `failing` as a throttled search does, and holds `holding`
/// until the lookup is stopped, as `MKLocalSearch.cancel()` ends a search. It never waits past 10 s, so a mutant
/// that doesn't stop it fails rather than hangs.
private struct FakeLookup: PlaceLookup {
    struct Throttled: Error {}

    let log: Log
    var answers: [String: TimeZoneConversion.Place] = ["hirtshals": hirtshals]
    var failing: Set<String> = []
    var holding: Set<String> = []

    func lookUp(_ name: String) async throws -> TimeZoneConversion.Place? {
        log.add(name)
        if holding.contains(name) {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                log.add("stopped \(name)")
                throw error
            }
        }
        if failing.contains(name) { throw Throttled() }
        return answers[name]
    }
}

@MainActor
private func makeLookups(
    _ log: Log, enabled: Bool = true, made: Log? = nil, fake: ((Log) -> FakeLookup)? = nil
) -> PlaceLookups {
    PlaceLookups(
        enabled: enabled,
        makeLookup: {
            made?.add("made")
            return fake?(log) ?? FakeLookup(log: log)
        }, wait: { log.add("wait") })
}

/// The names a query sends, with the committed table, each from a lookup of its own.
@MainActor
private func sent(_ query: String) async -> [String] {
    let log = Log()
    let lookups = makeLookups(log)
    lookups.queryChanged(query, places: committedPlaces)
    await lookups.settled()
    return log.all.filter { $0 != "wait" }
}

/// Up to 5 s for `condition`, for what a stopped task does after the test's own turn.
@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
struct PlaceLookupTests {
    @Test func offNothingIsMadeOrCalled() async {
        let log = Log()
        let made = Log()
        let lookups = makeLookups(log, enabled: false, made: made)
        lookups.queryChanged("time in hirtshals", places: committedPlaces)
        await lookups.settled()
        #expect(log.all.isEmpty)
        #expect(made.all.isEmpty, "it holds no lookup while it's off")
        #expect(!lookups.isEnabled)
    }

    @Test func onANameGoesOnceTheTypingHasStopped() async {
        let log = Log()
        let lookups = makeLookups(log)
        var changes = 0
        lookups.onChange = { changes += 1 }
        lookups.queryChanged("time in hirtshals", places: committedPlaces)
        await lookups.settled()
        #expect(log.all == ["wait", "hirtshals"], "one call, after the wait")
        #expect(lookups.found == ["hirtshals": hirtshals])
        #expect(changes == 1, "the card is evaluated again")
    }

    @Test func foundAndNotFoundAreKeptForTheRun() async {
        let log = Log()
        let lookups = makeLookups(log)
        for query in ["time in hirtshals", "time in xyz", "time in Hirtshals", "time in xyz", "now in hirtshals"] {
            lookups.queryChanged(query, places: committedPlaces)
            await lookups.settled()
        }
        #expect(log.all.filter { $0 != "wait" } == ["hirtshals", "xyz"], "each name once, by its folded name")
    }

    @Test func aNewQueryStopsTheLookupUnderWay() async throws {
        let log = Log()
        let lookups = makeLookups(log) { log in FakeLookup(log: log, holding: ["hirtshals"]) }
        var changes = 0
        lookups.onChange = { changes += 1 }
        lookups.queryChanged("time in hirtshals", places: committedPlaces)
        try await eventually { log.all.contains("hirtshals") }
        lookups.queryChanged("time in xyz", places: committedPlaces)
        try await eventually { log.all.contains("stopped hirtshals") }
        await lookups.settled()
        #expect(log.all.filter { $0 != "wait" && !$0.hasPrefix("stopped") } == ["hirtshals", "xyz"])
        #expect(log.all.contains("stopped hirtshals"))
        #expect(lookups.found.isEmpty)
        #expect(changes == 0)
        // Stopped isn't an answer: the name goes again.
        lookups.queryChanged("time in hirtshals", places: committedPlaces)
        try await eventually { log.all.filter { $0 == "hirtshals" }.count == 2 }
        lookups.setEnabled(false)
        try await eventually { log.all.filter { $0 == "stopped hirtshals" }.count == 2 }
    }

    @Test func aThrottledAnswerIsntKept() async {
        let log = Log()
        let lookups = makeLookups(log) { log in FakeLookup(log: log, failing: ["hirtshals"]) }
        for query in ["time in hirtshals", "time in xyz", "time in hirtshals"] {
            lookups.queryChanged(query, places: committedPlaces)
            await lookups.settled()
        }
        #expect(log.all.filter { $0 != "wait" } == ["hirtshals", "xyz", "hirtshals"])
        #expect(lookups.found.isEmpty)
    }

    @Test func theSameQueryAgainSendsNothingNew() async {
        let log = Log()
        let lookups = makeLookups(log)
        lookups.queryChanged("time in xyz", places: committedPlaces)
        lookups.queryChanged("time in xyz", places: committedPlaces)
        await lookups.settled()
        #expect(log.all == ["wait", "xyz"])
    }

    @Test(arguments: [
        // Point 13's list.
        "5 kg to lb", "10 to 15", "3 apples to oranges", "add time to calendar", "how to save time in excel",
        // `<name> time` alone, a name without a letter, of one character or of 5 words.
        "hirtshals time", "time in 42", "time in x", "time in one two three four five",
        // Unit and currency words in an allowed shape.
        "time in kgs", "kgs time to lbs time", "3pm cad to hkd", "time in kr", "time in €",
        // Names the tables know, and queries with a card already.
        "time in roskilde", "time in tokyo", "3pm copenhagen to kouvola", "gmt+2 to utc", "",
        // A bare number isn't a clock, with or without the word in one place.
        "9 xyz to qwz", "9 xyz time to qwz",
        // A clock that doesn't start the query: plain text around a time.
        "meeting 3pm to 4pm", "dinner with bob 7pm to 9pm", "remind me at 3pm in calendar",
        "call mom at 3pm in the morning", "standup at 9:30 in room 4", "flight at 3pm from london to paris",
        // A name that starts with a number: a quantity, or a clock time.
        "3pm to 4pm", "time in 3pm", "time in 5 kg", "time in 2 hours", "3pm 5 kg to london",
    ])
    func sendsNothing(_ query: String) async {
        #expect(await sent(query) == [], "\(query)")
    }

    @Test(arguments: [
        ("time in xyz", ["xyz"]), ("now in xyz", ["xyz"]), ("xyz time to qwz time", ["xyz", "qwz"]),
        ("xyz time in qwz time", ["xyz", "qwz"]), ("3pm xyz to qwz", ["xyz", "qwz"]),
        ("15:00 xyz in qwz", ["xyz", "qwz"]), ("9.30 xyz to qwz", ["xyz", "qwz"]), ("3pm xyz to copenhagen", ["xyz"]),
        ("time in arizona", ["arizona"]), ("time in new south wales", ["new south wales"]),
        ("9 xyz time to qwz time", ["xyz", "qwz"]), ("3 pm xyz to qwz", ["xyz", "qwz"]),
    ])
    func sendsTheNamesNoTableKnows(_ query: String, _ names: [String]) async {
        #expect(await sent(query) == names, "\(query)")
    }

    @Test func aFoundPlaceAnswersOnlyInTheShapesThatMaySendIt() {
        let found = ["hirtshals": hirtshals, "arizona": hirtshals]
        func answers(_ query: String) -> Bool {
            TimeZoneConversion.evaluate(
                query, now: Date(), timeZone: copenhagen, places: committedPlaces, lookedUp: found) != nil
        }
        for query in [
            "time in hirtshals", "now in Hirtshals", "hirtshals time to copenhagen time", "3pm hirtshals to london",
            "15:00 london in hirtshals", "time in arizona",
        ] {
            #expect(answers(query), "\(query)")
        }
        for query in [
            "hirtshals time", "copenhagen to hirtshals", "9 hirtshals to copenhagen", "add time to hirtshals",
            "arizona time", "london 3pm to hirtshals",
        ] {
            #expect(!answers(query), "\(query)")
        }
        // Without them, nothing.
        #expect(TimeZoneConversion.evaluate("time in hirtshals", now: Date(), timeZone: copenhagen) == nil)
        // A unit or currency word never answers from Apple Maps, even if a lookup had found it.
        let units = ["kgs": hirtshals, "cad": hirtshals]
        for query in ["time in kgs", "3pm cad to copenhagen"] {
            #expect(
                TimeZoneConversion.evaluate(query, now: Date(), timeZone: copenhagen, lookedUp: units) == nil,
                "\(query)")
        }
    }

    @Test func turnedOffItForgetsWhatItFoundAndStartsNothing() async {
        let log = Log()
        let made = Log()
        let lookups = makeLookups(log, made: made)
        var changes = 0
        lookups.onChange = { changes += 1 }
        lookups.queryChanged("time in hirtshals", places: committedPlaces)
        await lookups.settled()
        #expect(changes == 1)
        lookups.setEnabled(false)
        #expect(lookups.found.isEmpty)
        #expect(changes == 2, "the card goes")
        lookups.queryChanged("time in xyz", places: committedPlaces)
        await lookups.settled()
        #expect(log.all == ["wait", "hirtshals"])
        // On again: a new lookup, and nothing kept from before.
        lookups.setEnabled(true)
        lookups.queryChanged("time in hirtshals", places: committedPlaces)
        await lookups.settled()
        #expect(made.all == ["made", "made"])
        #expect(log.all.filter { $0 == "hirtshals" }.count == 2)
    }

    @Test func theCalculatorShowsAFoundPlace() throws {
        let result = try #require(
            Calculator.evaluate(
                "time in hirtshals", locale: Locale(identifier: "en_GB"), now: Date(), timeZone: copenhagen,
                places: committedPlaces, lookedUp: ["hirtshals": hirtshals]))
        #expect(result.answerLabel.hasPrefix("Hirtshals, "))
    }

    @Test func theSettingIsSavedOnlyWhenOn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("settings.json")
        #expect(FudgeSettings.load(from: file).appleMapsPlaces == false, "off by default")
        var settings = FudgeSettings()
        settings.appleMapsPlaces = true
        try settings.save(to: file)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["appleMapsPlaces"] as? Bool == true)
        #expect(FudgeSettings.load(from: file).appleMapsPlaces)
        settings.appleMapsPlaces = false
        try settings.save(to: file)
        let off = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(off["appleMapsPlaces"] == nil, "off is the default, so it isn't written")
    }
}
