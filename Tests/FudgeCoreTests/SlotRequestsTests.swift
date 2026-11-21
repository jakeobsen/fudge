import Foundation
import Testing

@testable import FudgeCore

/// The host's side of `slots` (`Deferral` in the runtime): a render carries the first item and the last request's
/// items in full, and holds back the others' actions and detail.
private struct FakeHost {
    let count: Int
    var wanted: Set<Int> = []

    func render() -> [ListContent.Item] {
        (1...count).map { id in
            var item = ListContent.Item(
                id: id, title: "item \(id)", keywords: [], accessories: [])
            if id != 1, !wanted.contains(id) { item.deferred = [.actions, .detail] }
            return item
        }
    }
}

/// The app's side: the requests it sends, the answers it holds until the next render, and what it shows.
private struct FakeApp {
    var requests = SlotRequests()
    var answers: Set<Int> = []
    var items: [ListContent.Item]
    var selected: Int
    var sent = 0

    /// What `requestSlots()` does; the host takes the request, and answers it, before anything else.
    mutating func ask(_ host: inout FakeHost) {
        let held = answers
        guard let ids = requests.request(items: items, selected: selected, answered: { held.contains($0) }) else {
            return
        }
        #expect(ids.contains(selected), "a request always names the selected item")
        sent += 1
        host.wanted = Set(ids)
        answers.formUnion(ids)
        requests.answered(ids)
    }

    /// A render arrives: the answers held so far are dropped, as `LauncherModel` drops them.
    mutating func receive(_ items: [ListContent.Item]) {
        self.items = items
        answers = []
    }

    /// Whether the selected item's actions are here: in the render, or in an answer.
    var selectionHasActions: Bool {
        guard let item = items.first(where: { $0.id == selected }) else { return false }
        return item.deferred.isEmpty || answers.contains(selected)
    }
}

@Test func theSelectedItemIsNeverHeldBackAcrossRenders() {
    // A List whose onSelectionChange sets state: every move is followed by a render (#3425, REQUIRED 3).
    var host = FakeHost(count: 300)
    var app = FakeApp(items: host.render(), selected: 1)
    app.ask(&host)
    app.receive(host.render())

    var moves = 0
    func move(to id: Int) {
        app.selected = id
        moves += 1
        app.ask(&host)  // requestSlots() comes before reportSelection()
        app.receive(host.render())  // the render onSelectionChange causes
        #expect(app.items.first { $0.id == id }?.deferred.isEmpty == true, "item \(id) was held back")
        app.ask(&host)  // after the render
        #expect(app.selectionHasActions, "item \(id) has no actions")
    }
    for id in 2...150 { move(to: id) }  // ↓
    for id in stride(from: 149, through: 60, by: -1) { move(to: id) }  // ↑
    move(to: 280)  // a click far down, or selectedItemId
    move(to: 3)
    for id in 4...12 { move(to: id) }
    #expect(app.sent < moves / 3, "\(app.sent) requests for \(moves) moves: one every few moves, not every one")
}

@Test func aRequestNamesTheWholeWindowAndWaitsForItsAnswer() {
    let host = FakeHost(count: 40)
    let items = host.render()
    var requests = SlotRequests()
    let first = requests.request(items: items, selected: 20, answered: { _ in false })
    #expect(first == Array(12...30), "8 before the selected item, 10 after")
    #expect(
        requests.request(items: items, selected: 20, answered: { _ in false }) == nil,
        "already on its way")
    #expect(requests.request(items: items, selected: 23, answered: { _ in false }) == nil, "still near the middle")
    #expect(requests.request(items: items, selected: 26, answered: { _ in false })?.first == 18, "near the edge")

    // At the ends of the list, the window is cut short.
    var ends = SlotRequests()
    #expect(ends.request(items: items, selected: 2, answered: { _ in false }) == Array(1...12))
    #expect(ends.request(items: items, selected: 40, answered: { _ in false }) == Array(32...40))
    #expect(ends.request(items: [], selected: nil, answered: { _ in false }) == nil)
}

@Test func anItemStillHeldBackWithNoAnswerComingIsAskedForAgain() {
    var host = FakeHost(count: 40)
    var requests = SlotRequests()
    let ids = requests.request(items: host.render(), selected: 10, answered: { _ in false }) ?? []
    requests.answered(ids)
    // A render that the host made before it took the request holds them back, and the answers were dropped.
    host.wanted = []
    #expect(requests.request(items: host.render(), selected: 10, answered: { _ in false }) == ids)
    // With the answers held, nothing is asked.
    requests.answered(ids)
    #expect(requests.request(items: host.render(), selected: 10, answered: { _ in true }) == nil)
}
