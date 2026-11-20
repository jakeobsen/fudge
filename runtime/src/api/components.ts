// The UI components of @raycast/api.
//
// Most are host components: they render a host element whose type is the
// component's name ("List.Item", "ActionPanel.Section", …), which the app
// draws natively. Props holding React elements (`actions`, `detail`,
// `metadata`, `searchBarAccessory`, …) are rendered as named `$slot`
// children so React manages them like any other child; the serializer puts
// them back as props. Components with behaviour (Action.Push, …) are plain
// function components that render a host `Action`.

import { createElement, isValidElement, type FunctionComponent, type ReactNode } from "react";
import { SLOT } from "../renderer/serialize.ts";
import { useNavigation } from "./navigation.ts";

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

// Constants. Their values match @raycast/api's own, since extensions may compare them.

const ActionStyle = Object.freeze({ Regular: "regular", Destructive: "destructive" });
const DatePickerType = Object.freeze({ Date: "date", DateTime: "date_time" });
const GridInset = Object.freeze({ Zero: "zero", Small: "sm", Medium: "md", Large: "lg" });
const GridItemSize = Object.freeze({ Small: "small", Medium: "medium", Large: "large" });
const GridFit = Object.freeze({ Contain: "contain", Fill: "fill" });

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

export const Action = Object.assign(ActionHost, {
    Style: ActionStyle,
    Push,
});

export const ActionPanel = Object.assign(host("ActionPanel"), {
    Section: host("ActionPanel.Section"),
    Submenu: host("ActionPanel.Submenu"),
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

const FormDropdownItem = host("Form.Dropdown.Item");
const FormDropdownSection = host("Form.Dropdown.Section");
const FormTagPickerItem = host("Form.TagPicker.Item");

export const Form = Object.assign(host("Form"), {
    TextField: host("Form.TextField"),
    PasswordField: host("Form.PasswordField"),
    TextArea: host("Form.TextArea"),
    Checkbox: host("Form.Checkbox"),
    DatePicker: Object.assign(host("Form.DatePicker"), { Type: DatePickerType }),
    Dropdown: Object.assign(host("Form.Dropdown"), { Item: FormDropdownItem, Section: FormDropdownSection }),
    TagPicker: Object.assign(host("Form.TagPicker"), { Item: FormTagPickerItem }),
    FilePicker: host("Form.FilePicker"),
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
