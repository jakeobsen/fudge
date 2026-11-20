// The UI components of @raycast/api.
//
// Most are host components: they render a host element whose type is the
// component's name ("List.Item", "ActionPanel.Section", …), which the app
// draws natively. Props holding React elements (`actions`, `detail`,
// `metadata`, `searchBarAccessory`, …) are rendered as named `$slot`
// children so React manages them like any other child; the serializer puts
// them back as props. Components with behaviour (Action.Push, …) are plain
// function components that render a host `Action`.

import { createElement, isValidElement, useState, type FunctionComponent, type ReactNode } from "react";
import { SLOT } from "../renderer/serialize.ts";
import { builtInActions } from "./actions.ts";
import { FormValuesContext, useFormField, type FormRegistry } from "./form-state.ts";
import { useNavigation } from "./navigation.ts";
import { RAYCAST_ENUMS } from "./raycast-enums.generated.ts";

type Props = Record<string, unknown> & { children?: ReactNode };

export function host(type: string): FunctionComponent<Props> {
    const component: FunctionComponent<Props> = ({ children, ...props }) => {
        const plain: Record<string, unknown> = {};
        const slots: ReactNode[] = [];
        for (const [key, value] of Object.entries(props)) {
            if (isValidElement(value)) slots.push(createElement(SLOT, { key: `$slot:${key}`, name: key }, value));
            else plain[key] = value;
        }
        plain.children = slots.length === 0 ? children : [...slots, children];
        return createElement(type, plain);
    };
    component.displayName = type;
    return component;
}

// Constants, with @raycast/api's own values (generated from its type definitions).

const ActionStyle = Object.freeze({ ...RAYCAST_ENUMS.ActionStyle });
const DatePickerType = Object.freeze({ ...RAYCAST_ENUMS.DatePickerType });
const GridInset = Object.freeze({ ...RAYCAST_ENUMS.GridInset });
const GridItemSize = Object.freeze({ ...RAYCAST_ENUMS.GridItemSize });
const GridFit = Object.freeze({ ...RAYCAST_ENUMS.GridFit });

// Metadata is shared by Detail and List.Item.Detail.

const Metadata = Object.assign(host("Metadata"), {
    Label: host("Metadata.Label"),
    Link: host("Metadata.Link"),
    Separator: host("Metadata.Separator"),
    TagList: Object.assign(host("Metadata.TagList"), { Item: host("Metadata.TagList.Item") }),
});

// Actions.

function Push({ target, onPush, onPop, ...props }: Props) {
    const navigation = useNavigation();
    return createElement(ActionHost, {
        ...props,
        onAction: () => {
            navigation.push(target as ReactNode, onPop as (() => void) | undefined);
            (onPush as (() => void) | undefined)?.();
        },
    });
}
Push.displayName = "Action.Push";

const ActionHost = host("Action");
const Submenu = host("ActionPanel.Submenu");

export const Action = Object.assign(ActionHost, {
    Style: ActionStyle,
    Push,
    ...builtInActions(ActionHost, Submenu),
});

export const ActionPanel = Object.assign(host("ActionPanel"), {
    Section: host("ActionPanel.Section"),
    Submenu,
    /** @deprecated Raycast's old name for Action. */
    Item: Action,
});

// Views.

export const List = Object.assign(host("List"), {
    Section: host("List.Section"),
    Item: Object.assign(host("List.Item"), {
        Detail: Object.assign(host("List.Item.Detail"), { Metadata }),
    }),
    EmptyView: host("List.EmptyView"),
    Dropdown: Object.assign(host("List.Dropdown"), {
        Item: host("List.Dropdown.Item"),
        Section: host("List.Dropdown.Section"),
    }),
});

export const Grid = Object.assign(host("Grid"), {
    Section: host("Grid.Section"),
    Item: host("Grid.Item"),
    EmptyView: host("Grid.EmptyView"),
    Dropdown: Object.assign(host("Grid.Dropdown"), {
        Item: host("Grid.Dropdown.Item"),
        Section: host("Grid.Dropdown.Section"),
    }),
    Inset: GridInset,
    ItemSize: GridItemSize,
    Fit: GridFit,
});

export const Detail = Object.assign(host("Detail"), { Metadata });

// The menu bar: a menu-bar command renders one MenuBarExtra, which the app draws as a status item and its menu.

export const MenuBarExtra = Object.assign(host("MenuBarExtra"), {
    Item: host("MenuBarExtra.Item"),
    Section: host("MenuBarExtra.Section"),
    Submenu: host("MenuBarExtra.Submenu"),
    Separator: host("MenuBarExtra.Separator"),
});

// Forms: the Form provides the registry SubmitForm reads, and each field
// registers its value there (see form-state.ts).

/** A form field: its host element, always with an onChange the app can call as the user edits. */
function field(type: string, empty: unknown): FunctionComponent<Props> {
    const Host = host(type);
    const Field: FunctionComponent<Props> = (props) => {
        const store = props.storeValue === true && type !== "Form.PasswordField";
        const record = useFormField(props.id, props.value, props.defaultValue, empty, store);
        const onChange = props.onChange as ((value: unknown) => void) | undefined;
        return createElement(Host, {
            ...props,
            onChange: (next: unknown) => {
                record(next);
                onChange?.(next);
            },
        });
    };
    Field.displayName = type;
    return Field;
}

const FormHost = host("Form");

function FormView(props: Props) {
    const [registry] = useState<FormRegistry>(() => new Map());
    return createElement(FormValuesContext.Provider, { value: registry }, createElement(FormHost, props));
}
FormView.displayName = "Form";

const FormDropdownItem = host("Form.Dropdown.Item");
const FormDropdownSection = host("Form.Dropdown.Section");
const FormTagPickerItem = host("Form.TagPicker.Item");

export const Form = Object.assign(FormView, {
    TextField: field("Form.TextField", ""),
    PasswordField: field("Form.PasswordField", ""),
    TextArea: field("Form.TextArea", ""),
    Checkbox: field("Form.Checkbox", false),
    DatePicker: Object.assign(field("Form.DatePicker", null), { Type: DatePickerType }),
    Dropdown: Object.assign(field("Form.Dropdown", undefined), { Item: FormDropdownItem, Section: FormDropdownSection }),
    TagPicker: Object.assign(field("Form.TagPicker", []), { Item: FormTagPickerItem }),
    FilePicker: field("Form.FilePicker", []),
    Separator: host("Form.Separator"),
    Description: host("Form.Description"),
    LinkAccessory: host("Form.LinkAccessory"),
    /** @deprecated Use Form.Dropdown.Item. */
    DropdownItem: FormDropdownItem,
    /** @deprecated Use Form.Dropdown.Section. */
    DropdownSection: FormDropdownSection,
    /** @deprecated Use Form.TagPicker.Item. */
    TagPickerItem: FormTagPickerItem,
});
