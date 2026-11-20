import Foundation

/// A Form view as fudge draws it: its fields in order.
public struct FormContent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case textField, passwordField, textArea, checkbox, description, separator
        /// A field fudge can't draw yet, by its type ("Form.DatePicker", …).
        case unsupported(String)
    }

    public struct Field: Sendable, Equatable, Identifiable {
        /// The node id, which `onChange` events go to.
        public var id: Int
        /// The field's own `id` prop, which names its value when the form is submitted.
        public var fieldId: String?
        public var kind: Kind
        public var title: String?
        public var placeholder: String?
        public var info: String?
        public var error: String?
        /// Set when the extension controls the value.
        public var value: JSONValue?
        public var defaultValue: JSONValue?
        /// A checkbox's label, or a description's text.
        public var text: String?
        public var autoFocus: Bool

        /// Whether the user can change it.
        public var isEditable: Bool {
            switch kind {
            case .textField, .passwordField, .textArea, .checkbox: true
            default: false
            }
        }

        /// What it holds before anything is typed or set.
        public var initialValue: JSONValue {
            value ?? defaultValue ?? (kind == .checkbox ? .bool(false) : .string(""))
        }
    }

    public var fields: [Field]

    public init(_ view: UINode) {
        fields = view.children.compactMap(Self.field)
    }

    static func field(_ node: UINode) -> Field? {
        let kind: Kind
        switch node.type {
        case "Form.TextField": kind = .textField
        case "Form.PasswordField": kind = .passwordField
        case "Form.TextArea": kind = .textArea
        case "Form.Checkbox": kind = .checkbox
        case "Form.Description": kind = .description
        case "Form.Separator": kind = .separator
        case let type where type.hasPrefix("Form.") && !type.hasPrefix("Form.LinkAccessory"): kind = .unsupported(type)
        default: return nil
        }
        return Field(
            id: node.id,
            fieldId: node.string("id"),
            kind: kind,
            title: node.string("title"),
            placeholder: node.string("placeholder"),
            info: node.string("info"),
            error: node.string("error"),
            value: node.props["value"].flatMap(ListContent.present),
            defaultValue: node.props["defaultValue"].flatMap(ListContent.present),
            text: kind == .checkbox ? node.string("label") : node.string("text"),
            autoFocus: node.bool("autoFocus") == true
        )
    }
}

/// A field's value in the app while the user edits it.
///
/// The app shows what the user typed straight away and tells the extension (`onChange`). When the extension
/// controls the value, it renders it back, but a render may still carry a value from a few keystrokes ago.
/// Adopting that would undo typing, so values the app sent and hasn't seen settle yet are recognised as echoes.
public struct FieldValue: Sendable, Equatable {
    public private(set) var value: JSONValue
    private var pending: [JSONValue] = []

    public init(_ value: JSONValue) {
        self.value = value
    }

    /// The user changed the value.
    public mutating func edit(_ new: JSONValue) {
        value = new
        pending.append(new)
    }

    /// The extension rendered the field again; `controlled` is its `value` prop, if it sets one.
    public mutating func render(controlled: JSONValue?) {
        guard let controlled else { return }
        if controlled == value {
            pending = []
        } else if let echo = pending.firstIndex(of: controlled) {
            pending.removeFirst(echo + 1)
        } else {
            // The extension set a value of its own.
            value = controlled
            pending = []
        }
    }
}
