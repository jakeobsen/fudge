// The built-in actions (Action.CopyToClipboard, Action.Open, …). Each renders
// a plain host `Action` whose onAction does the work through the system APIs,
// with Raycast's default title, icon and style.

import { createElement, useEffect, useState, type FunctionComponent } from "react";
import { closeMainWindow, showHUD, showToast, Toast } from "./feedback.ts";
import { RAYCAST_ENUMS } from "./raycast-enums.generated.ts";
import { NotAvailableError } from "./stubs.ts";
import { Clipboard, getApplications, open, showInFinder, trash } from "./system.ts";
import { callApp } from "../bridge.ts";
import { useFormValues, useStoredFormValues } from "./form-state.ts";

const Icon = RAYCAST_ENUMS.Icon;
type Props = Record<string, unknown>;
type HostAction = FunctionComponent<Props>;

/** Builds the built-in actions on top of the host `Action` and `ActionPanel.Submenu`. */
export function builtInActions(ActionHost: HostAction, Submenu: HostAction) {
    const action = (defaults: Props, props: Props, run: () => Promise<void> | void) =>
        createElement(ActionHost, { ...defaults, ...withoutOwn(props), onAction: run });

    function CopyToClipboard({ content, concealed, transient, onCopy, ...props }: Props) {
        return action({ title: "Copy to Clipboard", icon: Icon.Clipboard }, props, async () => {
            await Clipboard.copy(content as string, { concealed: concealed as boolean, transient: transient as boolean });
            await showHUD("Copied to Clipboard");
            (onCopy as ((content: unknown) => void) | undefined)?.(content);
        });
    }

    function Open({ target, application, onOpen, ...props }: Props) {
        return action({ icon: Icon.Finder }, props, async () => {
            await open(target as string, application as string | undefined);
            await closeMainWindow();
            (onOpen as ((target: unknown) => void) | undefined)?.(target);
        });
    }

    function OpenInBrowser({ url, onOpen, ...props }: Props) {
        return action({ title: "Open in Browser", icon: Icon.Globe }, props, async () => {
            await open(url as string);
            await closeMainWindow();
            (onOpen as ((url: unknown) => void) | undefined)?.(url);
        });
    }

    function ShowInFinder({ path, onShow, ...props }: Props) {
        return action({ title: "Show in Finder", icon: Icon.Finder }, props, async () => {
            await showInFinder(path as string);
            await closeMainWindow();
            (onShow as ((path: unknown) => void) | undefined)?.(path);
        });
    }

    function Trash({ paths, onTrash, ...props }: Props) {
        return action({ title: "Move to Trash", icon: Icon.Trash, style: RAYCAST_ENUMS.ActionStyle.Destructive }, props, async () => {
            await trash(paths as string | string[]);
            (onTrash as ((paths: unknown) => void) | undefined)?.(paths);
        });
    }

    /** A submenu listing the applications that can open `path`. */
    function OpenWith({ path, onOpen, title, icon, shortcut }: Props) {
        const [applications, setApplications] = useState<{ name: string; path: string }[] | null>(null);
        useEffect(() => {
            let current = true;
            getApplications(path as string).then(
                (found) => current && setApplications(found),
                () => current && setApplications([]),
            );
            return () => {
                current = false;
            };
        }, [path]);
        return createElement(
            Submenu,
            { title: title ?? "Open With", icon: icon ?? Icon.Upload, shortcut, isLoading: applications === null },
            (applications ?? []).map((application) =>
                createElement(ActionHost, {
                    key: application.path,
                    title: application.name,
                    icon: { fileIcon: application.path },
                    onAction: async () => {
                        await open(path as string, application.path);
                        await closeMainWindow();
                        (onOpen as ((path: unknown) => void) | undefined)?.(path);
                    },
                }),
            ),
        );
    }

    function SubmitForm({ onSubmit, ...props }: Props) {
        const values = useFormValues();
        const stored = useStoredFormValues();
        return action({ title: "Submit Form", icon: Icon.Checkmark }, props, () => {
            // Fields with `storeValue` start the form next time; the app keeps their values.
            const keep = stored();
            if (Object.keys(keep).length > 0) callApp("form.storeValues", { values: keep }).catch(() => {});
            return (onSubmit as ((values: Record<string, unknown>) => unknown) | undefined)?.(values()) as void;
        });
    }

    /** An action fudge can't perform yet: it shows, and says so when picked. */
    const unavailable = (name: string, title: string) => {
        function Unavailable(props: Props) {
            return action({ title }, props, async () => {
                await showToast({ style: Toast.Style.Failure, title: new NotAvailableError(name).message });
            });
        }
        Unavailable.displayName = name;
        return Unavailable;
    };

    return {
        CopyToClipboard,
        Open,
        OpenInBrowser,
        OpenWith,
        ShowInFinder,
        Trash,
        SubmitForm,
        Paste: unavailable("Action.Paste", "Paste"),
        CreateQuicklink: unavailable("Action.CreateQuicklink", "Create Quicklink"),
        CreateSnippet: unavailable("Action.CreateSnippet", "Create Snippet"),
        ToggleQuickLook: unavailable("Action.ToggleQuickLook", "Quick Look"),
        PickDate: unavailable("Action.PickDate", "Pick Date"),
        InstallMCPServer: unavailable("Action.InstallMCPServer", "Install MCP Server"),
    };
}

/** The props every action passes through: title, icon, shortcut, style, autoFocus, id. */
function withoutOwn(props: Props): Props {
    const { title, icon, shortcut, style, autoFocus, id } = props;
    const passed: Props = {};
    for (const [key, value] of Object.entries({ title, icon, shortcut, style, autoFocus, id })) {
        if (value !== undefined) passed[key] = value;
    }
    return passed;
}
