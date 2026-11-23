import Foundation
import Testing

@testable import FudgeCore

@Test func readsAFormsFields() throws {
    let view = try JSONDecoder().decode(
        UINode.self,
        from: Data(
            #"""
            {"id":1,"type":"Form","props":{"navigationTitle":"Edit Workflow"},"children":[
              {"id":2,"type":"Form.Description","props":{"text":"What Claude checks."},"children":[]},
              {"id":3,"type":"Form.TextArea","props":{"id":"workflow","title":"Workflow","defaultValue":"saved",
                "info":"Placeholders are filled in.","onChange":{"$fn":["onChange"]}},"children":[]},
              {"id":4,"type":"Form.TextField","props":{"id":"name","value":"x","placeholder":"Name","error":"Required","autoFocus":true},"children":[]},
              {"id":5,"type":"Form.Checkbox","props":{"id":"done","label":"Done"},"children":[]},
              {"id":6,"type":"Form.Separator","props":{},"children":[]},
              {"id":7,"type":"Form.Future","props":{"id":"when"},"children":[]},
              {"id":8,"type":"Form.PasswordField","props":{"id":"secret","value":null},"children":[]}
            ]}
            """#.utf8))
    let fields = FormContent(view).fields
    #expect(
        fields.map(\.kind) == [
            .description, .textArea, .textField, .checkbox, .separator, .unsupported("Form.Future"), .passwordField,
        ])
    #expect(fields[0].text == "What Claude checks." && !fields[0].isEditable)
    #expect(fields[1].fieldId == "workflow" && fields[1].title == "Workflow" && fields[1].info != nil)
    #expect(fields[1].initialValue() == .string("saved"))
    #expect(fields[2].initialValue() == .string("x") && fields[2].error == "Required" && fields[2].autoFocus)
    #expect(fields[2].placeholder == "Name")
    #expect(fields[3].text == "Done" && fields[3].initialValue() == .bool(false))
    #expect(fields[6].value == nil && fields[6].initialValue() == .string(""), "a null value means uncontrolled")
}

@Test func fieldValuesIgnoreStaleEchoes() {
    var field = FieldValue(.string(""))
    field.edit(.string("a"))
    field.edit(.string("ab"))
    field.render(controlled: .string("a"))
    #expect(field.value == .string("ab"), "an echo of an earlier keystroke doesn't undo typing")
    field.render(controlled: .string("ab"))
    #expect(field.value == .string("ab"))
    field.render(controlled: .string("a"))
    #expect(field.value == .string("a"), "once settled, a different value is the extension's own")

    field.edit(.string("abc"))
    field.render(controlled: .string("ABC"))
    #expect(field.value == .string("ABC"), "the extension can transform what was typed")
    field.render(controlled: nil)
    #expect(field.value == .string("ABC"), "uncontrolled renders leave it alone")
}

/// The fields of a Form whose children are `children` (JSON nodes, comma-separated).
private func formFields(_ children: String) throws -> [FormContent.Field] {
    let json = #"{"id":1,"type":"Form","props":{},"children":["# + children + "]}"
    return FormContent(try JSONDecoder().decode(UINode.self, from: Data(json.utf8))).fields
}

/// A render's DatePicker, with `props` (a JSON object) as its props.
private func datePicker(_ props: String) throws -> FormContent.Field {
    try #require(try formFields(#"{"id":2,"type":"Form.DatePicker","props":"# + props + #","children":[]}"#).first)
}

/// One render of a field, as `LauncherModel.refreshForm` takes it: `start`, then the extension's controlled value.
private func rendered(_ field: FormContent.Field, over existing: FieldValue?) -> FieldValue {
    let start = field.start(current: existing?.value, stored: nil)
    var value = existing.flatMap { $0.value == start.value ? $0 : nil } ?? FieldValue(start.value)
    value.render(controlled: field.value)
    return value
}

@Test func aDatePickersNullValueIsControlledAndOtherFieldsNullIsnt() throws {
    let fields = try formFields(
        #"""
        {"id":2,"type":"Form.DatePicker","props":{"id":"due","value":null},"children":[]},
        {"id":3,"type":"Form.DatePicker","props":{"id":"start"},"children":[]},
        {"id":4,"type":"Form.DatePicker","props":{"id":"end","defaultValue":null},"children":[]},
        {"id":5,"type":"Form.TextField","props":{"id":"name","value":null},"children":[]},
        {"id":6,"type":"Form.Checkbox","props":{"id":"done","value":null},"children":[]}
        """#)
    #expect(fields[0].value == .null, "a DatePicker's null is controlled: no date, as Date | null in Raycast's types")
    #expect(fields[0].initialValue() == .null && fields[0].registeredValue == .null)
    #expect(fields[1].value == nil, "no value prop: not controlled")
    #expect(fields[2].value == nil && fields[2].defaultValue == nil && fields[2].initialValue() == .null)
    #expect(fields[3].value == nil && fields[3].initialValue() == .string(""), "a TextField's null means uncontrolled")
    #expect(fields[4].value == nil && fields[4].initialValue() == .bool(false), "a Checkbox's null means uncontrolled")
}

@Test func aDateTheExtensionClearsGoesFromTheField() throws {
    let dated = try datePicker(#"{"id":"due","value":{"$date":"2026-11-20T12:30:00.000Z"}}"#)
    let cleared = try datePicker(#"{"id":"due","value":null}"#)
    let date = try #require(dated.value)
    var field = rendered(dated, over: nil)
    #expect(field.value == date)
    field = rendered(cleared, over: field)
    #expect(field.value == .null, "the extension set null: the date goes")

    // The user's own clear (the ×) settles when the extension renders it back, and a later date it sets is taken.
    let redated = try datePicker(#"{"id":"due","value":{"$date":"2026-12-24T17:00:00.000Z"}}"#)
    let later = try #require(redated.value)
    var settled = rendered(dated, over: nil)
    settled.edit(.null)
    settled = rendered(cleared, over: settled)
    #expect(settled.value == .null)
    settled = rendered(redated, over: settled)
    #expect(settled.value == later, "settled, a date the extension sets is its own")

    // The user clears (the ×) and picks again before the extension renders the clear: that null is an echo.
    let picked = FormDates.json(Date(timeIntervalSince1970: 1_795_000_000))
    var user = rendered(dated, over: nil)
    user.edit(.null)
    user.edit(picked)
    user = rendered(cleared, over: user)
    #expect(user.value == picked, "a late echo of the user's own clear doesn't undo the pick")
}

@Test func aDatePickerLeftUncontrolledKeepsItsDate() throws {
    let dated = try datePicker(#"{"id":"due","value":{"$date":"2026-11-20T12:30:00.000Z"}}"#)
    let uncontrolled = try datePicker(#"{"id":"due"}"#)
    let date = try #require(dated.value)
    var field = rendered(dated, over: nil)
    field = rendered(uncontrolled, over: field)
    #expect(field.value == date, "with no value prop the field keeps the date it shows")
    let picked = FormDates.json(Date(timeIntervalSince1970: 1_795_000_000))
    field.edit(picked)
    field = rendered(uncontrolled, over: field)
    #expect(field.value == picked, "and the user's own date stays")
}
