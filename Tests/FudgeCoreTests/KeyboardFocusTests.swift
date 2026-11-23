import Foundation
import Testing

@testable import FudgeCore

@Test func rootSearchWantsTheSearchFieldOrAFocusedTextArgument() {
    #expect(KeyboardFocus.target(for: .root(argument: nil, argumentIsDropdown: false)) == .search)
    #expect(KeyboardFocus.target(for: .root(argument: 1, argumentIsDropdown: false)) == .argument(1))
    #expect(
        KeyboardFocus.target(for: .root(argument: 0, argumentIsDropdown: true)) == .search,
        "a dropdown argument takes no typing")
    #expect(KeyboardFocus.target(for: .failure) == .search)
}

@Test func commandScreensWantTheirOwnField() {
    #expect(KeyboardFocus.target(for: .search) == .search, "a List's search field")
    #expect(KeyboardFocus.target(for: .form(lastField: 7, firstField: 3)) == .formField(7), "the last field")
    #expect(KeyboardFocus.target(for: .form(lastField: nil, firstField: 3)) == .formField(3), "else the first")
    #expect(KeyboardFocus.target(for: .form(lastField: nil, firstField: nil)) == .none, "a form with no fields")
    #expect(KeyboardFocus.target(for: .noField) == .none, "a Detail")
}

@Test func anOpenPanelKeepsTheKeyboardInItsSearchField() {
    #expect(KeyboardFocus.target(for: .search, actionPanelOpen: true) == .actionPanel)
    #expect(KeyboardFocus.target(for: .noField, actionPanelOpen: true) == .actionPanel, "⌘K in a Detail")
    #expect(KeyboardFocus.target(for: .form(lastField: 2, firstField: 1), actionPanelOpen: true) == .actionPanel)
    #expect(KeyboardFocus.target(for: .search, dropdownPanelOpen: true) == .dropdownPanel)
    #expect(
        KeyboardFocus.target(for: .root(argument: 1, argumentIsDropdown: false), actionPanelOpen: true)
            == .actionPanel)
}

@Test func aFormsNewFieldsTakeTheKeyboardOnlyWhenNoFieldAndNoOverlayHasIt() {
    func after(focused: Int?, editable: [Int] = [3, 5, 7], first: Int? = 3, overlayOpen: Bool = false) -> Int? {
        KeyboardFocus.formFieldAfterFieldsChange(
            focused: focused, editable: editable, first: first, overlayOpen: overlayOpen)
    }
    #expect(after(focused: nil) == 3, "no field had it: the first takes it")
    #expect(after(focused: 9) == 3, "the field that had it is gone")
    #expect(after(focused: 5) == nil, "a field still has it")
    #expect(after(focused: nil, editable: [], first: nil) == nil, "no fields left")
    #expect(
        after(focused: nil, overlayOpen: true) == nil,
        "an Action.PickDate picker or another overlay holds the keyboard: nothing takes it from there")
    #expect(after(focused: 9, overlayOpen: true) == nil)
}

@Test func closingAnOverlayGivesTheLastFieldTheKeyboardOrElseTheFirst() {
    #expect(KeyboardFocus.formFieldAfterOverlay(last: 5, editable: [3, 5, 7], first: 3) == 5)
    #expect(
        KeyboardFocus.formFieldAfterOverlay(last: 9, editable: [3, 7], first: 3) == 3,
        "the last field went while the overlay was open")
    #expect(KeyboardFocus.formFieldAfterOverlay(last: nil, editable: [3, 7], first: 7) == 7)
    #expect(KeyboardFocus.formFieldAfterOverlay(last: 5, editable: [], first: nil) == nil)
}

@Test func showingThePanelWithAPickerOpenLeavesTheKeyboardWithTheOverlay() {
    // An Action.PickDate picker lives in the action panel overlay, so a Form under it gets no field back.
    #expect(KeyboardFocus.target(for: .form(lastField: 2, firstField: 1), actionPanelOpen: true) == .actionPanel)
}

// MARK: - A Form's first field, and Tab between fields (FUD-185)

/// A Form read from its fields' nodes, ids from 2 on, as the host sends them.
private func form(_ fields: String...) throws -> FormContent {
    let children = fields.enumerated().map { index, field in
        #"{"id":\#(index + 2),"type":"Form.\#(field)","props":{},"children":[]}"#
    }
    let json = #"{"id":1,"type":"Form","props":{},"children":[\#(children.joined(separator: ","))]}"#
    return FormContent(try JSONDecoder().decode(UINode.self, from: Data(json.utf8)))
}

/// The field a form asks for when it appears, with no overlay open unless said.
private func onAppear(_ form: FormContent, overlayOpen: Bool = false) -> Int? {
    KeyboardFocus.formFieldOnAppear(editable: form.editableIDs, first: form.autoFocusID, overlayOpen: overlayOpen)
}

@Test func aFormAsksForItsFirstFieldWhenItAppears() throws {
    #expect(onAppear(try form("TextArea")) == 2, "a comment form: one text area")
    #expect(onAppear(try form("TextField")) == 2)
    #expect(onAppear(try form("Description", "TextArea")) == 3, "a description takes no keyboard")
    #expect(onAppear(try form("Separator", "TextField", "TextArea")) == 3)
    #expect(onAppear(try form("Description")) == nil, "no field to ask for")
}

@Test func aFormAsksForItsAutoFocusFieldWhenItAppears() throws {
    let autoFocusSecond = try JSONDecoder().decode(
        UINode.self,
        from: Data(
            #"""
            {"id":1,"type":"Form","props":{},"children":[
              {"id":2,"type":"Form.TextField","props":{"id":"title"},"children":[]},
              {"id":3,"type":"Form.TextArea","props":{"id":"body","autoFocus":true},"children":[]},
              {"id":4,"type":"Form.TextField","props":{"id":"tag","autoFocus":true},"children":[]}
            ]}
            """#.utf8))
    #expect(onAppear(FormContent(autoFocusSecond)) == 3, "the first with autoFocus")
    #expect(KeyboardFocus.formFieldOnAppear(editable: [2, 4], first: 3, overlayOpen: false) == 2, "it's gone")
}

@Test func aFormAsksForNoFieldWhileAnOverlayHoldsTheKeyboard() throws {
    #expect(onAppear(try form("TextArea"), overlayOpen: true) == nil, "it takes the keyboard when the overlay closes")
    #expect(onAppear(try form("TextField", "TextArea"), overlayOpen: true) == nil)
}

/// The Tab order's input for `form`: its editable fields, the DateTime ones in `timeBoxes` with a time box.
/// A DateTime field's value with a date, which gives it a time box.
private let aDate: JSONValue = .object(["$date": .string("2026-11-23T09:30:00.000Z")])

/// The form's places as Tab sees them, the fields in `timeBoxes` holding a date.
private func tabFields(_ form: FormContent, timeBoxes: Set<Int> = []) -> [KeyboardFocus.TabField] {
    form.tabFields { timeBoxes.contains($0) ? aDate : nil }
}

@Test func tabMovesToTheNextFieldAndShiftTabToThePreviousWrappingAtTheEnds() throws {
    // A TextField, a TextArea, a Checkbox and a Dropdown: 2, 3, 4 and 5.
    let fields = tabFields(try form("TextField", "TextArea", "Checkbox", "Dropdown"))
    func tab(_ now: Int?, backwards: Bool = false) -> KeyboardFocus.FormStop? {
        KeyboardFocus.formFieldAfterTab(now: now.map { .field($0) }, fields: fields, backwards: backwards)
    }
    #expect(tab(2) == .field(3))
    #expect(tab(3) == .field(4), "Tab leaves a text area, as Raycast's manual says")
    #expect(tab(4) == .field(5), "and goes on from a checkbox")
    #expect(tab(5) == .field(2), "from the last to the first")
    #expect(tab(2, backwards: true) == .field(5), "from the first to the last")
    #expect(tab(3, backwards: true) == .field(2))
    #expect(tab(4, backwards: true) == .field(3))
    #expect(tab(5, backwards: true) == .field(4))
}

@Test func tabWithNoFieldFocusedGoesToTheFirstFieldOrTheLastBackwards() throws {
    let fields = tabFields(try form("TextField", "TextArea", "Checkbox", "Dropdown"))
    #expect(KeyboardFocus.formFieldAfterTab(now: nil, fields: fields, backwards: false) == .field(2))
    #expect(KeyboardFocus.formFieldAfterTab(now: nil, fields: fields, backwards: true) == .field(5))
    #expect(
        KeyboardFocus.formFieldAfterTab(now: .field(9), fields: fields, backwards: false) == .field(2),
        "the field that had it is gone")
    #expect(
        KeyboardFocus.formFieldAfterTab(now: .timeBox(3), fields: fields, backwards: false) == .field(2),
        "a time box that's gone (its field has no date now)")
}

@Test func tabSkipsDescriptionsAndSeparators() throws {
    // 2 TextField, 3 Description, 4 TextArea, 5 Separator, 6 Checkbox.
    let fields = tabFields(try form("TextField", "Description", "TextArea", "Separator", "Checkbox"))
    #expect(fields.map(\.id) == [2, 4, 6])
    #expect(KeyboardFocus.formFieldAfterTab(now: .field(2), fields: fields, backwards: false) == .field(4))
    #expect(KeyboardFocus.formFieldAfterTab(now: .field(4), fields: fields, backwards: false) == .field(6))
    #expect(KeyboardFocus.formFieldAfterTab(now: .field(6), fields: fields, backwards: true) == .field(4))
    #expect(KeyboardFocus.formFieldAfterTab(now: .field(4), fields: fields, backwards: true) == .field(2))
}

@Test func aFormWithNoEditableFieldTakesTabAndGoesNowhere() throws {
    let fields = tabFields(try form("Description", "Separator", "Description"))
    #expect(fields.isEmpty)
    #expect(KeyboardFocus.formFieldAfterTab(now: nil, fields: fields, backwards: false) == nil)
    #expect(KeyboardFocus.formFieldAfterTab(now: nil, fields: fields, backwards: true) == nil)
}

@Test func aDateTimeFieldsTimeBoxIsATabStopAfterItsDate() throws {
    // 2 TextField, 3 DateTime with a date (a time box), 4 TextField.
    let fields = tabFields(try form("TextField", "DatePicker", "TextField"), timeBoxes: [3])
    func tab(_ now: KeyboardFocus.FormStop?, backwards: Bool = false) -> KeyboardFocus.FormStop? {
        KeyboardFocus.formFieldAfterTab(now: now, fields: fields, backwards: backwards)
    }
    #expect(tab(.field(2)) == .field(3), "into the date first")
    #expect(tab(.field(3)) == .timeBox(3), "then its time box")
    #expect(tab(.timeBox(3)) == .field(4), "then the next field")
    #expect(tab(.field(4), backwards: true) == .timeBox(3), "⇧Tab from the next field back into the time box")
    #expect(tab(.timeBox(3), backwards: true) == .field(3))
    #expect(tab(.field(3), backwards: true) == .field(2))
    #expect(tab(.field(2), backwards: true) == .field(4), "wrapping")
    let last = tabFields(try form("TextField", "DatePicker"), timeBoxes: [3])
    #expect(
        KeyboardFocus.formFieldAfterTab(now: nil, fields: last, backwards: true) == .timeBox(3),
        "backwards from nowhere, the last place is the last field's time box")
    #expect(KeyboardFocus.formFieldAfterTab(now: .timeBox(3), fields: last, backwards: false) == .field(2))
}

@Test func aDateFieldOrADateTimeWithNoDateHasNoTimeBox() throws {
    let view = try JSONDecoder().decode(
        UINode.self,
        from: Data(
            #"""
            {"id":1,"type":"Form","props":{},"children":[
              {"id":2,"type":"Form.DatePicker","props":{"id":"day","type":"date"},"children":[]},
              {"id":3,"type":"Form.DatePicker","props":{"id":"when","type":"date_time"},"children":[]},
              {"id":4,"type":"Form.DatePicker","props":{"id":"meeting"},"children":[]},
              {"id":5,"type":"Form.TextField","props":{"id":"title"},"children":[]}
            ]}
            """#.utf8))
    let fields = FormContent(view).fields
    let date: JSONValue = .object(["$date": .string("2026-11-23T09:30:00.000Z")])
    #expect(!fields[0].showsTimeBox(value: date), "a Date field")
    #expect(!fields[1].showsTimeBox(value: .null), "a DateTime with no date yet")
    #expect(fields[1].showsTimeBox(value: date))
    #expect(fields[2].showsTimeBox(value: date), "DateTime is the type when none is given")
    #expect(!fields[3].showsTimeBox(value: date), "not a DatePicker")
    let tab = FormContent(view).tabFields { $0 == 2 ? date : .null }
    #expect(tab.map(\.hasTimeBox) == [false, false, false, false], "a Date field with a date, and no dates elsewhere")
    #expect(KeyboardFocus.formFieldAfterTab(now: .field(2), fields: tab, backwards: false) == .field(3))
    #expect(KeyboardFocus.formFieldAfterTab(now: .field(3), fields: tab, backwards: false) == .field(4))
}

// The bookkeeping the launcher keeps for a Form: where the keyboard is now, and the field that had it last.

@Test func theKeyboardLeavingEveryFieldIsNowhereWhileTheLastFieldStays() {
    var keyboard = FormKeyboard()
    #expect(keyboard.moved(to: .field(2)) != nil)
    #expect(keyboard.now == .field(2) && keyboard.lastField == 2)
    #expect(keyboard.moved(to: nil) == nil, "no onBlur or onFocus for nowhere")
    #expect(keyboard.now == nil, "a click on the form's background: Tab starts from the first field")
    #expect(keyboard.lastField == 2, "while onBlur and the panel's showing still go by the last field")
    let fields = [2, 3, 4].map { KeyboardFocus.TabField(id: $0) }
    #expect(
        KeyboardFocus.formFieldAfterTab(now: keyboard.now, fields: fields, backwards: false) == .field(2),
        "from nowhere after a field had it: still the first, not the one after the last field")
}

@Test func movingBetweenFieldsTellsWhichToBlurAndFocus() {
    var keyboard = FormKeyboard()
    var change = keyboard.moved(to: .field(2))
    #expect(change?.left == nil && change?.entered == 2, "the first field takes it: onFocus only")
    change = keyboard.moved(to: .field(3))
    #expect(change?.left == 2 && change?.entered == 3)
    #expect(keyboard.moved(to: .field(3)) == nil, "the same field again: nothing")
    _ = keyboard.moved(to: nil)
    change = keyboard.moved(to: .field(3))
    #expect(change == nil, "back through nowhere into the same field: nothing")
}

@Test func aTimeBoxKeepsItsFieldAsTheLastField() {
    var keyboard = FormKeyboard()
    _ = keyboard.moved(to: .field(3))
    #expect(keyboard.moved(to: .timeBox(3)) == nil, "the date's own time box: no onBlur or onFocus")
    #expect(keyboard.now == .timeBox(3) && keyboard.lastField == 3 && keyboard.last == .timeBox(3))
    let change = keyboard.moved(to: .field(4))
    #expect(change?.left == 3 && change?.entered == 4)
    var clicked = FormKeyboard()
    _ = clicked.moved(to: .field(2))
    let intoTimeBox = clicked.moved(to: .timeBox(3))
    #expect(intoTimeBox?.left == 2 && intoTimeBox?.entered == 3, "a click from another field into a time box")
}

@Test func showingThePanelAgainGivesTheTimeBoxBackWhenItHadTheKeyboard() {
    #expect(KeyboardFocus.target(for: .form(lastField: 3, firstField: 2, lastInTimeBox: true)) == .formTimeBox(3))
    #expect(KeyboardFocus.target(for: .form(lastField: 3, firstField: 2, lastInTimeBox: false)) == .formField(3))
    #expect(
        KeyboardFocus.target(for: .form(lastField: nil, firstField: 2, lastInTimeBox: true)) == .formField(2),
        "no last field: the first")
    #expect(
        KeyboardFocus.target(for: .form(lastField: 3, firstField: 2, lastInTimeBox: true), actionPanelOpen: true)
            == .actionPanel)
}

@Test func aTabBeforeTheLastOneHasLandedGoesOnFromThePlaceAskedFor() {
    let fields = [2, 3, 4].map { KeyboardFocus.TabField(id: $0) }
    var keyboard = FormKeyboard()
    _ = keyboard.moved(to: .field(2))
    keyboard.ask(for: .field(3))
    #expect(keyboard.moved(to: nil) == nil, "the keyboard passing through nowhere on its way to field 3")
    #expect(keyboard.now == .field(2) && keyboard.tabFrom == .field(3))
    #expect(
        KeyboardFocus.formFieldAfterTab(now: keyboard.tabFrom, fields: fields, backwards: false) == .field(4),
        "two Tabs in a row: the third field, not the first")
    let change = keyboard.moved(to: .field(3))
    #expect(change?.left == 2 && change?.entered == 3)
    #expect(keyboard.tabFrom == .field(3) && keyboard.now == .field(3))
    #expect(keyboard.moved(to: nil) == nil)
    #expect(keyboard.tabFrom == nil, "once it has landed, leaving every field is nowhere again")
}

@Test func aPlaceAskedForThatTheKeyboardDoesntReachGivesWayToWhereItWent() {
    var keyboard = FormKeyboard()
    _ = keyboard.moved(to: .field(2))
    keyboard.ask(for: .field(3))
    _ = keyboard.moved(to: .field(4))
    #expect(keyboard.tabFrom == .field(4) && keyboard.lastField == 4)
}

@Test func reachingAnEarlierPlaceAskedForKeepsTheLaterOnesOnTheirWay() {
    // Fields 4, 5 and 6, the keyboard in 6, and four Tabs at once: 4, 5, 6, then 4 again.
    let fields = [4, 5, 6].map { KeyboardFocus.TabField(id: $0) }
    var keyboard = FormKeyboard()
    _ = keyboard.moved(to: .field(6))
    func tab() {
        if let place = KeyboardFocus.formFieldAfterTab(now: keyboard.tabFrom, fields: fields, backwards: false) {
            keyboard.ask(for: place)
        }
    }
    tab()
    tab()
    #expect(keyboard.tabFrom == .field(5))
    _ = keyboard.moved(to: .field(4))
    #expect(keyboard.tabFrom == .field(5), "the first Tab's field landing late doesn't undo the second Tab")
    tab()
    _ = keyboard.moved(to: .field(5))
    tab()
    #expect(keyboard.tabFrom == .field(4), "four Tabs from the third of three fields end in the first")
    _ = keyboard.moved(to: .field(6))
    _ = keyboard.moved(to: .field(4))
    #expect(keyboard.tabFrom == .field(4) && keyboard.now == .field(4))
    _ = keyboard.moved(to: nil)
    #expect(keyboard.tabFrom == nil, "every place asked for was reached")
}
