import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { createElement as h } from "react";
import { Action, ActionPanel, Detail, Grid, Icon, Keyboard, List } from "../src/api/index.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";
import type { UINode } from "../src/renderer/serialize.ts";
import { mount } from "./support/mount.ts";

let calls: RpcRequest[] = [];

beforeEach(() => {
    calls = [];
    connect((request) => {
        calls.push(request);
        const textEdit = { name: "TextEdit", path: "/System/Applications/TextEdit.app" };
        const answer =
            request.method === "applications.list" ? [textEdit] : request.method === "applications.frontmost" ? textEdit : null;
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

test("Open With is a submenu of the applications that can open the path, looked up when it opens", async () => {
    const { mounted } = await panelWith(h(Action.OpenWith, { path: "/tmp/notes.txt" }));
    await flush();
    const closed = (mounted.snapshots.at(-1)!.view!.props.actions as unknown as UINode).children[0]!;
    assert.equal(closed.type, "ActionPanel.Submenu");
    assert.equal(closed.props.title, "Open With");
    assert.equal(closed.props.isLoading, true);
    assert.deepEqual(closed.props.onOpen, { $fn: ["onOpen"] });
    assert.equal(calls.length, 0, "nothing is asked until the submenu opens");

    mounted.root.dispatch(closed.id, ["onOpen"], []);
    await flush();
    const submenu = (mounted.snapshots.at(-1)!.view!.props.actions as unknown as UINode).children[0]!;
    assert.deepEqual(calls.map((call) => call.method), ["applications.list"]);
    assert.equal(submenu.props.isLoading, false);
    assert.deepEqual(submenu.children.map((child) => [child.props.title, child.props.icon]), [["TextEdit", { fileIcon: "/System/Applications/TextEdit.app" }]]);
    await mounted.root.dispatch(submenu.children[0]!.id, ["onAction"], []);
    assert.deepEqual(calls.find((call) => call.method === "open")!.params, { target: "/tmp/notes.txt", application: "/System/Applications/TextEdit.app" });
});

test("an action fudge can't perform still shows, and says so when picked", async () => {
    const { mounted, entries } = await panelWith(h(Action.CreateQuicklink, { quicklink: { link: "https://example.com" } }));
    assert.equal(entries[0]!.props.title, "Create Quicklink");
    await mounted.root.dispatch(entries[0]!.id, ["onAction"], []);
    const toast = calls.find((call) => call.method === "toast.show")!.params as { title: string; style: string };
    assert.equal(toast.title, "Action.CreateQuicklink isn't available in Fudge yet");
    assert.equal(toast.style, "FAILURE");
});

test("Action.Paste pastes into the app the user is in, then calls onPaste", async () => {
    const pasted: unknown[] = [];
    const { mounted } = await panelWith(h(Action.Paste, { content: "hello", onPaste: (content: unknown) => pasted.push(content) }));
    await flush();
    const entry = (mounted.snapshots.at(-1)!.view!.props.actions as unknown as UINode).children[0]!;
    assert.equal(entry.props.title, "Paste to TextEdit", "named after the frontmost app");
    assert.equal(entry.props.icon, Icon.Clipboard);
    await mounted.root.dispatch(entry.id, ["onAction"], []);
    await flush();
    assert.deepEqual(calls.find((call) => call.method === "clipboard.paste")!.params, { text: "hello", closeMainWindow: true });
    assert.deepEqual(pasted, ["hello"]);
    assert.equal(calls.some((call) => call.method === "toast.show"), false, "no not-available toast");
});

test("every Action.Paste in one render shares one frontmost lookup", async () => {
    const pastes = Array.from({ length: 50 }, (_, i) => h(Action.Paste, { key: i, content: `row ${i}` }));
    const { mounted } = await panelWith(...pastes);
    await flush();
    assert.equal(calls.filter((call) => call.method === "applications.frontmost").length, 1);
    const entries = (mounted.snapshots.at(-1)!.view!.props.actions as unknown as UINode).children;
    assert.equal(entries.length, 50);
    assert.ok(entries.every((entry) => entry.props.title === "Paste to TextEdit"));
});

test("Action.Paste keeps Raycast's default title until it knows the app, and shows a failure as a toast", async () => {
    const pasted: unknown[] = [];
    connect((request) => {
        calls.push(request);
        const error = request.method === "clipboard.paste" ? "Fudge needs Accessibility permission to paste." : undefined;
        setImmediate(() => (request.method === "applications.frontmost" ? undefined : settle(request.id, null, error)));
    });
    const { mounted, entries } = await panelWith(h(Action.Paste, { content: "x", onPaste: () => pasted.push("x") }));
    assert.equal(entries[0]!.props.title, "Paste in Active App");
    await mounted.root.dispatch(entries[0]!.id, ["onAction"], []);
    await flush();
    const toast = calls.find((call) => call.method === "toast.show")!.params as { title: string; style: string };
    assert.equal(toast.title, "Fudge needs Accessibility permission to paste.");
    assert.equal(toast.style, "FAILURE");
    assert.deepEqual(pasted, [], "onPaste only after a paste");
});

test("Submit Form outside a Form submits no values", async () => {
    const submitted: unknown[] = [];
    const { mounted, entries } = await panelWith(h(Action.SubmitForm, { onSubmit: (values: unknown) => submitted.push(values) }));
    assert.equal(entries[0]!.props.title, "Submit Form");
    await mounted.root.dispatch(entries[0]!.id, ["onAction"], []);
    assert.deepEqual(submitted, [{}]);
});

test("Toggle Quick Look renders with Raycast's defaults and a marker the app performs, with no onAction", async () => {
    const { entries } = await panelWith(
        h(Action.ToggleQuickLook),
        h(Action.ToggleQuickLook, { title: "Preview", shortcut: Keyboard.Shortcut.Common.ToggleQuickLook }),
    );
    assert.deepEqual(
        entries.map((entry) => [entry.type, entry.props.title, entry.props.icon, entry.props.fudgeBuiltIn]),
        [
            ["Action", "Quick Look", Icon.Eye, "toggleQuickLook"],
            ["Action", "Preview", Icon.Eye, "toggleQuickLook"],
        ],
    );
    assert.equal(entries[0]!.props.onAction, undefined, "nothing for the app to call back");
    assert.deepEqual(entries[1]!.props.shortcut, {
        macOS: { modifiers: ["cmd"], key: "y" },
        Windows: { modifiers: ["ctrl"], key: "y" },
    });
});

test("an item's quickLook path goes to the app as text: a URL as its href, a Buffer as UTF-8", async () => {
    const list = await mount(
        h(
            List,
            null,
            h(List.Item, { title: "a", quickLook: { path: "/tmp/a.png", name: "A" } }),
            h(List.Item, { title: "b", quickLook: { path: new URL("file:///tmp/b%20c.pdf") } }),
            h(List.Item, { title: "c", quickLook: { path: Buffer.from("/tmp/ü.txt") } }),
            h(List.Item, { title: "d" }),
        ),
    );
    await list.settle();
    const items = list.snapshots.at(-1)!.view!.children;
    assert.deepEqual(
        items.map((item) => item.props.quickLook ?? null),
        [{ path: "/tmp/a.png", name: "A" }, { path: "file:///tmp/b%20c.pdf" }, { path: "/tmp/ü.txt" }, null],
    );
    const grid = await mount(h(Grid, null, h(Grid.Item, { content: "x", quickLook: { path: new URL("file:///tmp/g.png") } })));
    await grid.settle();
    assert.deepEqual(grid.snapshots.at(-1)!.view!.children[0]!.props.quickLook, { path: "file:///tmp/g.png" });
});
