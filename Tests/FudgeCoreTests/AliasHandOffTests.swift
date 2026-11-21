import Foundation
import Testing

@testable import FudgeCore

// FUD-140: "alias, space, rest" in root search with the command already selected never settled in a snapshot run.

private let query = ExtensionManifest.Argument(name: "query", type: "text", placeholder: "Query", required: true)

private func quicklink(_ id: String, alias: String) -> RootItem {
    var item = RootItem(
        id: "quicklink:\(id)", title: "Docs Search", subtitle: "Quicklink",
        kind: .command(
            extension: "x", command: id, mode: "no-view", entry: URL(fileURLWithPath: "/x/\(id).cjs")),
        arguments: [query])
    item.alias = alias
    return item
}

/// SwiftUI's focus state as the probe saw it (FUD-140's evidence log): a panel that holds the keyboard gives a field
/// the keyboard when asked; one that doesn't falls back to the search field when asked for an argument field, keeps
/// that request, and makes it again when next asked for the search field. It returns what the view's
/// `.onChange(of: focus)` would hear.
private struct FakeFocus {
    enum Field: Equatable {
        case search
        case argument(Int)

        var index: Int? {
            if case .argument(let index) = self { return index }
            return nil
        }
    }

    var holdsKeyboard: Bool
    private(set) var shown: Field?
    private var kept: Field?

    init(holdsKeyboard: Bool) {
        self.holdsKeyboard = holdsKeyboard
    }

    mutating func ask(for field: Field) -> [Field] {
        let next: Field
        if holdsKeyboard {
            next = field
        } else if field == .search, let kept {
            next = kept
        } else {
            if field != .search { kept = field }
            next = .search
        }
        defer { shown = next }
        return shown == next ? [] : [next]
    }
}

/// The view's two ways: the model's focus goes to SwiftUI, and each change SwiftUI reports goes back to the model when
/// `takes` says so. The number of reports before nothing is left to do, or nil when it hadn't settled after 100.
private func settle(
    _ input: inout ArgumentInput, _ view: inout FakeFocus, takes: (ArgumentInput, Int?) -> Bool
) -> Int? {
    func field(_ focus: Int?) -> FakeFocus.Field { focus.map(FakeFocus.Field.argument) ?? .search }
    var reports = view.ask(for: field(input.focus))
    var count = 0
    while !reports.isEmpty {
        let report = reports.removeFirst()
        count += 1
        if count > 100 { return nil }
        guard takes(input, report.index) else { continue }
        input.focus = report.index
        reports += view.ask(for: field(input.focus))
    }
    return count
}

/// What the app's model does: `LauncherModel.fieldTookKeyboard`.
private func modelTakes(_ panelHoldsKeyboard: Bool) -> (ArgumentInput, Int?) -> Bool {
    { input, index in input.follows(index, panelHoldsKeyboard: panelHoldsKeyboard) }
}

/// The hand-off as the model's search field setter runs it.
private func type(
    _ text: String, into input: inout ArgumentInput, handOff: inout AliasHandOff, items: [RootItem]
) -> AliasHandOff.Answer {
    let answer = handOff.answer(text, in: items, inArgument: input.focus != nil)
    if case .handOff(let item, let rest) = answer {
        if input.arguments != item.arguments { input = ArgumentInput(arguments: item.arguments) }
        input.set(rest, at: 0)
        input.focus = 0
    }
    return answer
}

@Test func aPanelThatCantTakeTheKeyboardSettlesAfterTheHandOff() throws {
    let docs = quicklink("q1", alias: "dw")
    // The quicklink is already selected (history), so its field is already there.
    var input = ArgumentInput(arguments: docs.arguments)
    var handOff = AliasHandOff()
    #expect(type("dw zzyzx", into: &input, handOff: &handOff, items: [docs]) == .handOff(item: docs, rest: "zzyzx"))

    var view = FakeFocus(holdsKeyboard: false)
    let reports = try #require(settle(&input, &view, takes: modelTakes(false)), "the loop is back")
    #expect(reports == 1, "SwiftUI's fallback is heard once and not taken")
    #expect(input.focus == 0, "the model still wants the argument field")
    #expect(input.value(at: 0) == "zzyzx")
    #expect(view.shown == .search, "the fallback the panel can't help")

    // The panel comes up and takes the keyboard: `presented()` asks for it again, and the field gets it.
    view.holdsKeyboard = true
    #expect(view.ask(for: .argument(0)) == [.argument(0)])
}

@Test func theFakeLoopsWhenEveryAnswerIsTakenAsAMove() {
    // What the view did before FUD-140: every change SwiftUI reported went to the model.
    let docs = quicklink("q1", alias: "dw")
    var input = ArgumentInput(arguments: docs.arguments)
    var handOff = AliasHandOff()
    _ = type("dw zzyzx", into: &input, handOff: &handOff, items: [docs])
    var view = FakeFocus(holdsKeyboard: false)
    #expect(settle(&input, &view, takes: modelTakes(true)) == nil)
}

@Test func aPanelThatHoldsTheKeyboardFollowsTheUser() throws {
    let docs = quicklink("q1", alias: "dw")
    var input = ArgumentInput(arguments: docs.arguments)
    var handOff = AliasHandOff()
    _ = type("dw zzyzx", into: &input, handOff: &handOff, items: [docs])
    var view = FakeFocus(holdsKeyboard: true)
    #expect(try #require(settle(&input, &view, takes: modelTakes(true))) == 1)
    #expect(input.focus == 0)
    #expect(view.shown == .argument(0))

    // A click into the search field is the user's move.
    #expect(input.follows(nil, panelHoldsKeyboard: true))
    // The field the model already wants, an argument that isn't there, and anything while the panel doesn't hold
    // the keyboard aren't moves to take.
    #expect(!input.follows(0, panelHoldsKeyboard: true))
    #expect(!input.follows(3, panelHoldsKeyboard: true))
    #expect(!input.follows(nil, panelHoldsKeyboard: false))
}

@Test func theHandOffRunsOncePerQuery() {
    let docs = quicklink("q1", alias: "dw")
    var input = ArgumentInput(arguments: docs.arguments)
    var handOff = AliasHandOff()
    #expect(type("dw zzyzx", into: &input, handOff: &handOff, items: [docs]) == .handOff(item: docs, rest: "zzyzx"))

    // The user types on in the argument field, and the search field writes the query it showed back.
    input.set("zzyzx and more", at: 0)
    #expect(type("dw zzyzx", into: &input, handOff: &handOff, items: [docs]) == .alreadyHandedOff)
    #expect(input.value(at: 0) == "zzyzx and more", "the write-back doesn't replace the user's typing")
    #expect(input.focus == 0, "nor send the keyboard anywhere")

    // Another query is a new hand-off, even back to the first.
    #expect(type("dw other", into: &input, handOff: &handOff, items: [docs]) == .handOff(item: docs, rest: "other"))
    #expect(type("d", into: &input, handOff: &handOff, items: [docs]) == .query)
    #expect(type("dw zzyzx", into: &input, handOff: &handOff, items: [docs]) == .handOff(item: docs, rest: "zzyzx"))

    // The same query for another row (the alias moved to another quicklink) is a new hand-off too.
    let moved = quicklink("q2", alias: "dw")
    #expect(type("dw zzyzx", into: &input, handOff: &handOff, items: [moved]) == .handOff(item: moved, rest: "zzyzx"))
}

@Test func escAndDeleteStillLeaveTheArgumentField() {
    let docs = quicklink("q1", alias: "dw")
    var input = ArgumentInput(arguments: docs.arguments)
    var handOff = AliasHandOff()
    _ = type("dw zzyzx", into: &input, handOff: &handOff, items: [docs])

    // Esc goes back to the search field, and typing the same query there again hands it off again.
    #expect(input.handle(KeyShortcut(key: "escape", modifiers: [])) == .handled)
    #expect(input.focus == nil)
    #expect(type("dw zzyzx", into: &input, handOff: &handOff, items: [docs]) == .handOff(item: docs, rest: "zzyzx"))
    #expect(input.focus == 0)

    // ⌫ in the empty field goes back to the search field too.
    _ = type("dw ", into: &input, handOff: &handOff, items: [docs])
    #expect(input.value(at: 0) == "")
    #expect(input.handle(KeyShortcut(key: "delete", modifiers: [])) == .handled)
    #expect(input.focus == nil)
    #expect(type("dw ", into: &input, handOff: &handOff, items: [docs]) == .handOff(item: docs, rest: ""))
}
