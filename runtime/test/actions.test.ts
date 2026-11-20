import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { createElement as h } from "react";
import { Action, ActionPanel, Detail, Keyboard } from "../src/api/index.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";
import type { UINode } from "../src/renderer/serialize.ts";
import { mount } from "./support/mount.ts";

let calls: RpcRequest[] = [];

beforeEach(() => {
    calls = [];
    connect((request) => {
        calls.push(request);
        const answer = request.method === "applications.list" ? [{ name: "TextEdit", path: "/System/Applications/TextEdit.app" }] : null;
        setImmediate(() => settle(request.id, answer));
    });
});
afterEach(() => connect(null));

const flush = async () => {
    for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
};

/** Mounts a Detail whose action panel holds `actions`, and returns the panel's children. */
async function panelWith(...actions: ReturnType<typeof h>[]) {
    const mounted = await mount(h(Detail, { markdown: "x", actions: h(ActionPanel, null, ...actions) }));
    await mounted.settle();
    const view = mounted.snapshots.at(-1)!.view!;
    return { mounted, entries: (view.props.actions as unknown as UINode).children };
}

test("built-in actions carry Raycast's default titles, icons and styles", async () => {
    const { entries } = await panelWith(
        h(Action.CopyToClipboard, { content: "x" }),
        h(Action.OpenInBrowser, { url: "https://example.com" }),
        h(Action.ShowInFinder, { path: "/tmp" }),
        h(Action.Trash, { paths: ["/tmp/a"] }),
        h(Action.CopyToClipboard, { content: "y", title: "Copy Path", shortcut: Keyboard.Shortcut.Common.CopyPath }),
    );
    assert.deepEqual(
        entries.map((entry) => [entry.type, entry.props.title, entry.props.icon, entry.props.style ?? null]),
        [
            ["Action", "Copy to Clipboard", "copy-clipboard-16", null],
            ["Action", "Open in Browser", "globe-01-16", null],
            ["Action", "Show in Finder", "finder-16", null],
            ["Action", "Move to Trash", "trash-16", "destructive"],
            ["Action", "Copy Path", "copy-clipboard-16", null],
        ],
    );
    assert.deepEqual(entries[4]!.props.shortcut, {
        macOS: { modifiers: ["cmd", "ctrl"], key: "c" },
        Windows: { modifiers: ["alt", "shift"], key: "c" },
    });
});

test("Copy to Clipboard copies, shows a HUD, then calls onCopy", async () => {
    const copied: unknown[] = [];
    const { mounted, entries } = await panelWith(h(Action.CopyToClipboard, { content: "secret", concealed: true, onCopy: (c: unknown) => copied.push(c) }));
    await mounted.root.dispatch(entries[0]!.id, ["onAction"], []);
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["clipboard.copy", { text: "secret", concealed: true, transient: false }],
            ["hud.show", { title: "Copied to Clipboard", clearRootSearch: false, popToRootType: "default" }],
        ],
    );
    assert.deepEqual(copied, ["secret"]);
});

test("Trash and Open ask the app, then report back", async () => {
    const reported: unknown[] = [];
    const { mounted, entries } = await panelWith(
        h(Action.Trash, { paths: "/tmp/a", onTrash: (p: unknown) => reported.push(["trashed", p]) }),
        h(Action.Open, { title: "Open", target: "/tmp/a", application: "TextEdit", onOpen: (t: unknown) => reported.push(["opened", t]) }),
    );
    await mounted.root.dispatch(entries[0]!.id, ["onAction"], []);
    await mounted.root.dispatch(entries[1]!.id, ["onAction"], []);
    assert.deepEqual(calls.map((call) => call.method), ["trash", "open", "window.close"]);
    assert.deepEqual(calls[1]!.params, { target: "/tmp/a", application: "TextEdit" });
    assert.deepEqual(reported, [["trashed", "/tmp/a"], ["opened", "/tmp/a"]]);
});

test("Open With is a submenu of the applications that can open the path", async () => {
    const { mounted } = await panelWith(h(Action.OpenWith, { path: "/tmp/notes.txt" }));
    await flush();
    const view = mounted.snapshots.at(-1)!.view!;
    const submenu = (view.props.actions as unknown as UINode).children[0]!;
    assert.equal(submenu.type, "ActionPanel.Submenu");
    assert.equal(submenu.props.title, "Open With");
    assert.equal(submenu.props.isLoading, false);
    assert.deepEqual(submenu.children.map((child) => [child.props.title, child.props.icon]), [["TextEdit", { fileIcon: "/System/Applications/TextEdit.app" }]]);
    await mounted.root.dispatch(submenu.children[0]!.id, ["onAction"], []);
    assert.deepEqual(calls.find((call) => call.method === "open")!.params, { target: "/tmp/notes.txt", application: "/System/Applications/TextEdit.app" });
});

test("an action fudge can't perform still shows, and says so when picked", async () => {
    const { mounted, entries } = await panelWith(h(Action.Paste, { content: "x" }));
    assert.equal(entries[0]!.props.title, "Paste");
    await mounted.root.dispatch(entries[0]!.id, ["onAction"], []);
    const toast = calls.find((call) => call.method === "toast.show")!.params as { title: string; style: string };
    assert.equal(toast.title, "Action.Paste isn't available in fudge yet");
    assert.equal(toast.style, "FAILURE");
});

test("Submit Form outside a Form submits no values", async () => {
    const submitted: unknown[] = [];
    const { mounted, entries } = await panelWith(h(Action.SubmitForm, { onSubmit: (values: unknown) => submitted.push(values) }));
    assert.equal(entries[0]!.props.title, "Submit Form");
    await mounted.root.dispatch(entries[0]!.id, ["onAction"], []);
    assert.deepEqual(submitted, [{}]);
});
