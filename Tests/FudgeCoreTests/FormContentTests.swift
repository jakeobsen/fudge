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
              {"id":7,"type":"Form.DatePicker","props":{"id":"when"},"children":[]},
              {"id":8,"type":"Form.PasswordField","props":{"id":"secret","value":null},"children":[]}
            ]}
            """#.utf8))
    let fields = FormContent(view).fields
    #expect(
        fields.map(\.kind) == [
            .description, .textArea, .textField, .checkbox, .separator, .unsupported("Form.DatePicker"), .passwordField,
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
