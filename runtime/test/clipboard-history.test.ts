import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { build } from "esbuild";
import React, { createElement, type FunctionComponent } from "react";
import * as jsxRuntime from "react/jsx-runtime";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";
import { Clipboard } from "../src/api/system.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";
import {
    clearClipboardHistory,
    clipboardImage,
    commandLineToolsReady,
    copyClipboardEntry,
    createFudgeAppModule,
    deleteClipboardEntry,
    listClipboardHistory,
    logToFudge,
    openDevelopmentSettings,
    pasteClipboardEntry,
    pinClipboardEntry,
    searchFiles,
    type ClipboardEntry,
} from "../src/fudge-app.ts";
import type { JsonValue, UINode } from "../src/renderer/serialize.ts";
import {
    detailFields,
    detailMarkdown,
    filesMarkdown,
    filesShown,
    formatDate,
    imageMarkdown,
    keywords,
    sections,
    sizeText,
    textMarkdown,
    title,
} from "../clipboard-history-extension/src/entries.ts";
import { find, mount, type Mounted } from "./support/mount.ts";

// A fake app. `clipboardHistory.list` answers with `history`, `clipboardHistory.image` waits for the test to answer
// it, a method in `failures` rejects with its message, and everything else is answered on the next tick.

let calls: RpcRequest[] = [];
let images: RpcRequest[] = [];
let history: unknown = { on: true, entries: [] };
let failures: Record<string, string> = {};
let confirms = true;

beforeEach(() => {
    calls = [];
    images = [];
    history = { on: true, entries: [] };
    failures = {};
    confirms = true;
    setLaunchContext({
        preferences: {},
        environment: {
            ...placeholderEnvironment,
            extensionName: "fudge-clipboard-history",
            commandName: "clipboard-history",
            commandMode: "view",
        },
        launchProps: {},
    });
    connect((request) => {
        calls.push(request);
        if (request.method === "clipboardHistory.image") {
            images.push(request);
            return;
        }
        setImmediate(() => {
            const failure = failures[request.method];
            if (failure !== undefined) settle(request.id, null, failure);
            else if (request.method === "clipboardHistory.list") settle(request.id, history);
            else if (request.method === "alert.confirm") settle(request.id, confirms);
            else settle(request.id, null);
        });
    });
});
afterEach(() => connect(null));

const at = (time: string) => new Date(`2026-11-20T${time}:00Z`);
const wire = (date: Date) => ({ $date: date.toISOString() });

/** Entries as the app sends them, dates and all. */
const hello = {
    id: "t1",
    kind: "text",
    text: "\n  Hello world  \nsecond line",
    app: { bundleId: "com.apple.TextEdit", name: "TextEdit" },
    copiedAt: wire(at("10:00")),
    size: 28,
    pinned: false,
};
const link = {
    id: "l1",
    kind: "link",
    text: "https://example.com/a",
    app: { bundleId: "com.apple.Safari" },
    copiedAt: wire(at("11:00")),
    size: 21,
    pinned: true,
};
const screenshot = { id: "i1", kind: "image", copiedAt: wire(at("12:00")), size: 245_000, pinned: false, width: 1200, height: 800 };
const report = {
    id: "f1",
    kind: "files",
    files: ["/Users/otter/Documents/Report.pdf", "/Users/otter/Notes.txt"],
    name: "Report.pdf",
    app: { bundleId: "com.apple.finder", name: "Finder" },
    copiedAt: wire(at("09:00")),
    size: 2,
    pinned: true,
};

/** An entry as `fudge:app` hands it to the command. */
function entry(fields: Partial<ClipboardEntry> & Pick<ClipboardEntry, "kind">): ClipboardEntry {
    return { id: "e", copiedAt: at("08:00"), size: 0, pinned: false, ...fields };
}

// `fudge:app`

test("listClipboardHistory asks for clipboardHistory.list and revives the dates", async () => {
    history = { on: true, entries: [hello, report] };
    const answer = await listClipboardHistory();
    assert.deepEqual(calls.map((call) => [call.method, call.params]), [["clipboardHistory.list", null]]);
    assert.equal(answer.on, true);
    assert.deepEqual(answer.entries.map((each) => each.id), ["t1", "f1"]);
    assert.ok(answer.entries[0]!.copiedAt instanceof Date);
    assert.equal(answer.entries[1]!.copiedAt.getTime(), at("09:00").getTime());
    assert.deepEqual(answer.entries[1]!.files, report.files);
});

test("the other clipboardHistory calls send their params, and resolve when the app answers", async () => {
    const image = clipboardImage("i1");
    settle(images[0]!.id, { path: "/private/var/folders/x/i1.png" });
    assert.deepEqual(await image, { path: "/private/var/folders/x/i1.png" });
    assert.equal(await pasteClipboardEntry("t1"), undefined);
    await copyClipboardEntry("t1");
    await pinClipboardEntry("t1", true);
    await pinClipboardEntry("t1", false);
    await deleteClipboardEntry("t1");
    await clearClipboardHistory();
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["clipboardHistory.image", { id: "i1" }],
            ["clipboardHistory.paste", { id: "t1" }],
            ["clipboardHistory.copy", { id: "t1" }],
            ["clipboardHistory.pin", { id: "t1", pinned: true }],
            ["clipboardHistory.pin", { id: "t1", pinned: false }],
            ["clipboardHistory.delete", { id: "t1" }],
            ["clipboardHistory.clear", {}],
        ],
    );
});

test("the clipboardHistory calls reject with the app's message", async () => {
    const refusal = "clipboardHistory calls are only for Fudge's Clipboard History.";
    failures = { "clipboardHistory.list": refusal, "clipboardHistory.paste": "No such entry." };
    await assert.rejects(listClipboardHistory(), { message: refusal });
    await assert.rejects(pasteClipboardEntry("gone"), { message: "No such entry." });
    const image = clipboardImage("t1");
    settle(images[0]!.id, null, "Not an image.");
    await assert.rejects(image, { message: "Not an image." });
});

test("the fudge:app module is frozen and holds every call", () => {
    const module = createFudgeAppModule();
    assert.ok(Object.isFrozen(module));
    assert.deepEqual(module, {
        logToFudge,
        commandLineToolsReady,
        openDevelopmentSettings,
        searchFiles,
        listClipboardHistory,
        clipboardImage,
        pasteClipboardEntry,
        copyClipboardEntry,
        pinClipboardEntry,
        deleteClipboardEntry,
        clearClipboardHistory,
    });
});

// Raycast's `offset` (§5)

test("Clipboard.read and readText send an offset above 0 to the history, and anything else as the current clipboard", async () => {
    await Clipboard.readText();
    await Clipboard.readText({ offset: 0 });
    await Clipboard.readText({ offset: 2 });
    await Clipboard.read();
    await Clipboard.read({ offset: 0 });
    await Clipboard.read({ offset: 5 });
    await Clipboard.read({ offset: -1 });
    await Clipboard.readText({ offset: Number.NaN });
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["clipboard.read", { offset: 0 }],
            ["clipboard.read", { offset: 0 }],
            ["clipboard.read", { offset: 2 }],
            ["clipboard.read", { offset: 0 }],
            ["clipboard.read", { offset: 0 }],
            ["clipboard.read", { offset: 5 }],
            ["clipboard.read", { offset: 0 }],
            ["clipboard.read", { offset: 0 }],
        ],
    );
});

test("no history entry (null) reads as Raycast's types say: undefined text, and a ReadContent with an empty text", async () => {
    assert.equal(await Clipboard.readText({ offset: 3 }), undefined);
    assert.deepEqual(await Clipboard.read({ offset: 3 }), { text: "" });

    connect((request) => {
        calls.push(request);
        setImmediate(() => settle(request.id, { text: "earlier", file: "/tmp/a.txt" }));
    });
    assert.equal(await Clipboard.readText({ offset: 1 }), "earlier");
    assert.deepEqual(await Clipboard.read({ offset: 1 }), { text: "earlier", file: "/tmp/a.txt" });
});

// The extension's pure module

test("sections: Pinned, then Recent, each newest first, and none left empty", () => {
    const entries = [
        entry({ id: "a", kind: "text", copiedAt: at("08:00") }),
        entry({ id: "b", kind: "text", copiedAt: at("10:00"), pinned: true }),
        entry({ id: "c", kind: "text", copiedAt: at("09:00") }),
        entry({ id: "d", kind: "text", copiedAt: at("07:00"), pinned: true }),
    ];
    assert.deepEqual(
        sections(entries).map((section) => [section.title, section.entries.map((each) => each.id)]),
        [
            ["Pinned", ["b", "d"]],
            ["Recent", ["c", "a"]],
        ],
    );
    assert.deepEqual(sections(entries.filter((each) => !each.pinned)).map((section) => section.title), ["Recent"]);
    assert.deepEqual(sections(entries.filter((each) => each.pinned)).map((section) => section.title), ["Pinned"]);
    assert.deepEqual(sections([]), []);
});

test("titles: a text's first line with something on it, an image's or file's name, or the type", () => {
    assert.equal(title(entry({ kind: "text", text: "\n\n   Hello world \nmore" })), "Hello world");
    assert.equal(title(entry({ kind: "text", text: "one\r\ntwo" })), "one");
    assert.equal(title(entry({ kind: "text", text: " \n\t " })), "Text", "only whitespace");
    assert.equal(title(entry({ kind: "link", text: "https://example.com" })), "https://example.com");
    assert.equal(title(entry({ kind: "text", text: "x".repeat(300) })), `${"x".repeat(200)}…`, "a long line is cut");
    assert.equal(title(entry({ kind: "text", text: `${"x".repeat(199)}😀and more` })), `${"x".repeat(199)}…`, "never inside an emoji");
    assert.equal(title(entry({ kind: "image", name: "Screenshot.png" })), "Screenshot.png");
    assert.equal(title(entry({ kind: "image" })), "Image");
    assert.equal(title(entry({ kind: "files", files: ["/a/Report.pdf"] })), "Report.pdf");
    assert.equal(title(entry({ kind: "files", files: ["/a/Report.pdf", "/b/c.txt", "/d"], name: "Report" })), "Report and 2 more");
    assert.equal(title(entry({ kind: "files", files: [] })), "Files");
});

test("keywords: the start of a longer text, and every file's name", () => {
    assert.deepEqual(keywords(entry({ kind: "text", text: "Hello" })), [], "a one-line text is its title");
    assert.deepEqual(keywords(entry({ kind: "text", text: "Dear Otter,\n\n  the river\tis high." })), ["Dear Otter, the river is high."]);
    const long = keywords(entry({ kind: "text", text: `first\n${"word ".repeat(400)}` }))[0]!;
    assert.equal(long.length, 501, "500 characters and an ellipsis");
    assert.deepEqual(keywords(entry({ kind: "image", name: "Screenshot.png" })), []);
    assert.deepEqual(keywords(entry({ kind: "files", files: ["/a/Report.pdf"] })), []);
    assert.deepEqual(keywords(entry({ kind: "files", files: ["/a/Report.pdf", "/b/Notes.txt"] })), ["Report.pdf", "Notes.txt"]);
});

test("a text is shown as it is, in a fence longer than any run of backticks in it", () => {
    assert.equal(textMarkdown("# not a heading\n**not bold**"), "```\n# not a heading\n**not bold**\n```");
    assert.equal(textMarkdown("```js\ncode\n```"), "````\n```js\ncode\n```\n````");
    assert.equal(textMarkdown("a ````` b"), "``````\na ````` b\n``````");
    assert.equal(detailMarkdown(entry({ kind: "link", text: "https://example.com" })), "```\nhttps://example.com\n```");
});

test("an image is its file's URL, with spaces and parentheses encoded; none until the file is read", () => {
    assert.equal(imageMarkdown("/private/tmp/Clip (1) copy.png"), "![](file:///private/tmp/Clip%20%281%29%20copy.png)");
    assert.equal(detailMarkdown(entry({ kind: "image" })), undefined);
    assert.equal(detailMarkdown(entry({ kind: "image" }), "/tmp/i.png"), "![](file:///tmp/i.png)");
});

test("files: each name in bold over its path, markdown escaped, and a long list cut", () => {
    assert.equal(
        filesMarkdown(["/Users/otter/Report.pdf", "/tmp/# *odd*_name"]),
        "**Report\\.pdf**  \n\\/Users\\/otter\\/Report\\.pdf\n\n**\\# \\*odd\\*\\_name**  \n\\/tmp\\/\\# \\*odd\\*\\_name",
    );
    const many = Array.from({ length: filesShown + 3 }, (_, index) => `/f/${index}`);
    const blocks = filesMarkdown(many).split("\n\n");
    assert.equal(blocks.length, filesShown + 1);
    assert.equal(blocks.at(-1), "And 3 more.");
});

test("the detail's metadata for each kind", () => {
    const copiedAt = at("10:00");
    const copied = { title: "Copied", text: formatDate(copiedAt, "en-US") };
    assert.deepEqual(
        detailFields(entry({ kind: "text", text: "héllo 😀", copiedAt, app: { bundleId: "com.apple.TextEdit", name: "TextEdit" } }), "en-US"),
        [{ title: "Type", text: "Text" }, { title: "App", text: "TextEdit" }, copied, { title: "Size", text: "7 characters" }],
    );
    assert.deepEqual(
        detailFields(entry({ kind: "link", text: "https://a.b", copiedAt, app: { bundleId: "com.apple.Safari" } }), "en-US"),
        [{ title: "Type", text: "Link" }, { title: "App", text: "com.apple.Safari" }, copied, { title: "Size", text: "11 characters" }],
        "the bundle id when the app has no name",
    );
    assert.deepEqual(
        detailFields(entry({ kind: "image", copiedAt, size: 245_000, width: 1200, height: 800 }), "en-US"),
        [{ title: "Type", text: "Image" }, copied, { title: "Size", text: "1200 × 800, 245 KB" }],
        "no App row when it isn't known",
    );
    assert.deepEqual(
        detailFields(entry({ kind: "files", copiedAt, files: ["/a", "/b"], size: 2 }), "en-US"),
        [{ title: "Type", text: "Files" }, copied, { title: "Size", text: "2 files" }],
    );
    assert.deepEqual(detailFields(entry({ kind: "files", files: ["/a"], size: 1 }), "en-US")[0], { title: "Type", text: "File" });
    assert.equal(sizeText(entry({ kind: "files", files: ["/a"] })), "1 file");
    assert.equal(sizeText(entry({ kind: "text", text: "x" })), "1 character");
    assert.equal(sizeText(entry({ kind: "image", size: 900 })), "900 bytes", "an image without its size in pixels");
    assert.equal(sizeText(entry({ kind: "text", text: "a".repeat(1234) }), "da-DK"), "1.234 characters");
});

test("a truncated text says so", () => {
    assert.equal(sizeText(entry({ kind: "text", text: "a".repeat(1500), truncated: true }), "en-US"), "1,500 characters (truncated)");
    const shown = detailFields(entry({ kind: "text", text: "abc", truncated: true }), "en-US");
    assert.deepEqual(shown.at(-1), { title: "Size", text: "3 characters (truncated)" });
});

// The command, compiled as `fudge build` compiles it and run against the fake app.

const extension = path.join(import.meta.dirname, "../clipboard-history-extension");
let compiled: Promise<string> | null = null;

async function loadCommand(): Promise<FunctionComponent> {
    compiled ??= build({
        entryPoints: [path.join(extension, "src/clipboard-history.tsx")],
        bundle: true,
        platform: "node",
        format: "cjs",
        target: "node22",
        jsx: "automatic",
        external: ["@raycast/api", "fudge:app", "react", "react/jsx-runtime"],
        write: false,
        logLevel: "silent",
    }).then((result) => result.outputFiles[0]!.text);
    const provided: Record<string, unknown> = {
        "@raycast/api": createApiModule(),
        "fudge:app": createFudgeAppModule(),
        react: React,
        "react/jsx-runtime": jsxRuntime,
    };
    const fallback = createRequire(import.meta.url);
    const require = (name: string) => (Object.hasOwn(provided, name) ? provided[name] : fallback(name));
    const module = { exports: {} as { default?: FunctionComponent } };
    new Function("module", "exports", "require", await compiled)(module, module.exports, require);
    return module.exports.default!;
}

const view = (mounted: Mounted) => mounted.snapshots.at(-1)!.view!;
const sectionsOf = (mounted: Mounted) => view(mounted).children.filter((child) => child.type === "List.Section");
const items = (mounted: Mounted) => sectionsOf(mounted).flatMap((section) => section.children);
const item = (mounted: Mounted, id: string) => items(mounted).find((each) => each.props.id === id)!;
const asNode = (value: JsonValue | undefined) => value as unknown as UINode;
/** An item's `actions` and `detail`, asked for as the app asks for them. */
const slots = (mounted: Mounted, id: string) => mounted.root.slots([item(mounted, id).id])[0]!.slots;
const actionsOf = (mounted: Mounted, id: string) => asNode(slots(mounted, id).actions).children.flatMap((section) => section.children);
const detailOf = (mounted: Mounted, id: string) => asNode(slots(mounted, id).detail);
const metadataOf = (detail: UINode) => asNode(detail.props.metadata).children.map((label) => [label.props.title, label.props.text]);
const methods = () => calls.map((call) => call.method);

async function open(...entries: unknown[]) {
    history = { on: true, entries };
    const mounted = await mount(createElement(await loadCommand()));
    await mounted.settle();
    return mounted;
}

async function run(mounted: Mounted, id: string, title: string) {
    const action = actionsOf(mounted, id).find((each) => each.props.title === title)!;
    await mounted.root.dispatch(action.id, ["onAction"], []);
    await mounted.settle();
}

test("the list: loading first, then Pinned and Recent, newest first, with the detail pane", async () => {
    history = { on: true, entries: [screenshot, link, hello, report] };
    const mounted = await mount(createElement(await loadCommand()));
    assert.equal(mounted.first.view!.props.isLoading, true);
    assert.equal(find(mounted.first.view!, "List.EmptyView"), undefined, "no empty view while loading");
    await mounted.settle();

    const list = view(mounted);
    assert.equal(list.props.isLoading, false);
    assert.equal(list.props.isShowingDetail, true);
    assert.equal(list.props.onSearchTextChange, undefined, "Fudge filters by title and keywords");
    assert.deepEqual(list.props.onSelectionChange, { $fn: ["onSelectionChange"] });
    assert.deepEqual(
        sectionsOf(mounted).map((section) => [section.props.title, section.children.map((each) => each.props.id)]),
        [
            ["Pinned", ["l1", "f1"]],
            ["Recent", ["i1", "t1"]],
        ],
    );
    assert.deepEqual(methods(), ["clipboardHistory.list"], "the first item isn't an image: nothing else is asked for");
});

test("each item: its title, keywords, an icon for its kind, and when it was copied", async () => {
    const mounted = await open(link, report, screenshot, hello);
    assert.deepEqual(
        items(mounted).map(({ props }) => [props.id, props.title, props.keywords, props.icon, props.accessories]),
        [
            ["l1", "https://example.com/a", [], "link-16", [{ date: link.copiedAt }]],
            ["f1", "Report.pdf and 1 more", ["Report.pdf", "Notes.txt"], "blank-document-16", [{ date: report.copiedAt }]],
            ["i1", "Image", [], "image-16", [{ date: screenshot.copiedAt }]],
            ["t1", "Hello world", ["Hello world second line"], "text-16", [{ date: hello.copiedAt }]],
        ],
    );
});

test("the detail: a text in a fence, the files' names and paths, and the metadata", async () => {
    const mounted = await open(link, report, hello);
    const first = asNode(item(mounted, "l1").props.detail);
    assert.equal(first.type, "List.Item.Detail", "the first item's detail comes with the list");
    assert.equal(first.props.markdown, "```\nhttps://example.com/a\n```");
    assert.deepEqual(metadataOf(first), [
        ["Type", "Link"],
        ["App", "com.apple.Safari"],
        ["Copied", formatDate(at("11:00"))],
        ["Size", "21 characters"],
    ]);

    const text = detailOf(mounted, "t1");
    assert.equal(text.props.markdown, "```\n\n  Hello world  \nsecond line\n```");
    assert.deepEqual(metadataOf(text), [
        ["Type", "Text"],
        ["App", "TextEdit"],
        ["Copied", formatDate(at("10:00"))],
        ["Size", "28 characters"],
    ]);

    const files = detailOf(mounted, "f1");
    assert.equal(files.props.markdown, filesMarkdown(report.files));
    assert.deepEqual(metadataOf(files), [
        ["Type", "Files"],
        ["App", "Finder"],
        ["Copied", formatDate(at("09:00"))],
        ["Size", "2 files"],
    ]);
});

test("an image is read for the selected item only, and shown once it's there", async () => {
    const older = { ...screenshot, id: "i0", copiedAt: wire(at("06:00")) };
    const mounted = await open({ ...hello, copiedAt: wire(at("13:00")) }, screenshot, older);
    assert.deepEqual(methods(), ["clipboardHistory.list"], "the selected item is a text: no image is read");
    const waiting = detailOf(mounted, "i1");
    assert.equal(waiting.props.isLoading, true);
    assert.equal(waiting.props.markdown, undefined);
    assert.deepEqual(metadataOf(waiting), [
        ["Type", "Image"],
        ["Copied", formatDate(at("12:00"))],
        ["Size", "1200 × 800, 245 KB"],
    ]);

    await mounted.root.dispatch(view(mounted).id, ["onSelectionChange"], ["i1"]);
    await mounted.settle();
    assert.deepEqual(images.map((call) => call.params), [{ id: "i1" }]);
    settle(images[0]!.id, { path: "/private/tmp/fudge-clips/i1.png" });
    await mounted.settle();
    const shown = detailOf(mounted, "i1");
    assert.equal(shown.props.isLoading, false);
    assert.equal(shown.props.markdown, "![](file:///private/tmp/fudge-clips/i1.png)");

    await mounted.root.dispatch(view(mounted).id, ["onSelectionChange"], ["t1"]);
    await mounted.root.dispatch(view(mounted).id, ["onSelectionChange"], ["i1"]);
    await mounted.settle();
    assert.equal(images.length, 1, "an image is read once");
    assert.equal(detailOf(mounted, "i0").props.isLoading, true, "the other image isn't read until it's selected");
});

test("an image that can't be read shows a failure toast, and the detail stops loading", async () => {
    const mounted = await open(screenshot);
    assert.deepEqual(images.map((call) => call.params), [{ id: "i1" }], "the first item is selected until the app says otherwise");
    settle(images[0]!.id, null, "The image is gone.");
    await mounted.settle();
    const toast = calls.find((call) => call.method === "toast.show")!.params as Record<string, unknown>;
    assert.deepEqual([toast.style, toast.title, toast.message], ["FAILURE", "Couldn't show the image", "The image is gone."]);
    const detail = asNode(item(mounted, "i1").props.detail);
    assert.equal(detail.props.isLoading, false);
    assert.equal(detail.props.markdown, undefined);
});

test("a truncated text says so in the detail", async () => {
    const mounted = await open({ ...hello, text: "start of something long", truncated: true });
    assert.deepEqual(metadataOf(asNode(item(mounted, "t1").props.detail)).at(-1), ["Size", "23 characters (truncated)"]);
});

test("the actions, in order, with their shortcuts; Paste takes ↵ and Copy ⌘↵", async () => {
    const mounted = await open(link, hello);
    const shown = (id: string) =>
        actionsOf(mounted, id).map((each) => [each.props.title, each.props.shortcut ?? null, each.props.style ?? null]);
    assert.deepEqual(shown("t1"), [
        ["Paste", null, null],
        ["Copy", null, null],
        ["Pin", { modifiers: ["cmd", "shift"], key: "p" }, null],
        ["Delete", { modifiers: ["ctrl"], key: "x" }, "destructive"],
        ["Delete All…", { modifiers: ["ctrl", "shift"], key: "x" }, "destructive"],
    ]);
    assert.equal(shown("l1")[2]![0], "Unpin", "a pinned entry");
});

test("Paste, Copy, Pin, Unpin and Delete call the app, then load the history again", async () => {
    const mounted = await open(link, hello);
    calls = [];
    await run(mounted, "t1", "Paste");
    await run(mounted, "t1", "Copy");
    await run(mounted, "t1", "Pin");
    await run(mounted, "l1", "Unpin");
    await run(mounted, "t1", "Delete");
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["clipboardHistory.paste", { id: "t1" }],
            ["clipboardHistory.list", null],
            ["clipboardHistory.copy", { id: "t1" }],
            ["hud.show", { title: "Copied", clearRootSearch: false, popToRootType: "default" }],
            ["clipboardHistory.list", null],
            ["clipboardHistory.pin", { id: "t1", pinned: true }],
            ["clipboardHistory.list", null],
            ["clipboardHistory.pin", { id: "l1", pinned: false }],
            ["clipboardHistory.list", null],
            ["clipboardHistory.delete", { id: "t1" }],
            ["clipboardHistory.list", null],
        ],
    );
});

test("the list shows the history the app answers after a change", async () => {
    const mounted = await open(link, hello);
    history = { on: true, entries: [link] };
    await run(mounted, "t1", "Delete");
    assert.deepEqual(items(mounted).map((each) => each.props.id), ["l1"]);
});

test("Delete All asks first, then deletes everything", async () => {
    const mounted = await open(link, hello);
    calls = [];
    confirms = false;
    await run(mounted, "t1", "Delete All…");
    assert.deepEqual(methods(), ["alert.confirm"], "declined: nothing is deleted");

    confirms = true;
    history = { on: true, entries: [] };
    await run(mounted, "t1", "Delete All…");
    assert.deepEqual(methods(), ["alert.confirm", "alert.confirm", "clipboardHistory.clear", "clipboardHistory.list"]);
    const confirm = calls[1]!.params as Record<string, unknown>;
    assert.deepEqual([confirm.title, confirm.message, confirm.primaryAction], [
        "Delete All Copies?",
        "Pinned copies are deleted too.",
        { title: "Delete All", style: "destructive" },
    ]);
    assert.deepEqual(calls[2]!.params, {});
    assert.equal(find(view(mounted), "List.EmptyView")!.props.title, "No Copies Yet");
});

test("a failed action shows a failure toast with its message, and nothing is loaded again", async () => {
    const mounted = await open(hello);
    failures = { "clipboardHistory.paste": "Fudge needs Accessibility permission to paste." };
    calls = [];
    await run(mounted, "t1", "Paste");
    assert.deepEqual(methods(), ["clipboardHistory.paste", "toast.show"]);
    const toast = calls[1]!.params as Record<string, unknown>;
    assert.deepEqual([toast.style, toast.title, toast.message], ["FAILURE", "Couldn't paste", "Fudge needs Accessibility permission to paste."]);

    failures = { "clipboardHistory.clear": "The history couldn't be saved." };
    calls = [];
    await run(mounted, "t1", "Delete All…");
    assert.deepEqual(methods(), ["alert.confirm", "clipboardHistory.clear", "toast.show"]);
});

test("while history is off: one empty view, whose one action opens its settings", async () => {
    history = { on: false, entries: [] };
    const mounted = await mount(createElement(await loadCommand()));
    await mounted.settle();
    const list = view(mounted);
    assert.equal(list.props.isShowingDetail, undefined);
    assert.equal(list.props.isLoading, undefined);
    assert.deepEqual(sectionsOf(mounted), []);
    const empty = find(list, "List.EmptyView")!;
    assert.equal(empty.props.title, "Clipboard history is off");
    const actions = asNode(empty.props.actions).children;
    assert.deepEqual(actions.map((each) => [each.type, each.props.title]), [["Action", "Open Clipboard History Settings"]]);

    calls = [];
    await mounted.root.dispatch(actions[0]!.id, ["onAction"], []);
    await mounted.settle();
    assert.deepEqual(methods(), ["preferences.openExtension"]);
});

test("on with nothing copied yet: its own empty view, without the detail pane", async () => {
    const mounted = await open();
    assert.equal(view(mounted).props.isShowingDetail, false);
    const empty = find(view(mounted), "List.EmptyView")!;
    assert.deepEqual([empty.props.title, empty.props.description], ["No Copies Yet", "What you copy shows up here."]);
});

test("a history that can't be read shows a failure toast, and an empty view that says so", async () => {
    failures = { "clipboardHistory.list": "The history couldn't be read." };
    const mounted = await mount(createElement(await loadCommand()));
    await mounted.settle();
    const toast = calls.find((call) => call.method === "toast.show")!.params as Record<string, unknown>;
    assert.deepEqual([toast.style, toast.title, toast.message], ["FAILURE", "Couldn't read the clipboard history", "The history couldn't be read."]);
    assert.equal(view(mounted).props.isLoading, false);
    const empty = find(view(mounted), "List.EmptyView")!;
    assert.deepEqual([empty.props.title, empty.props.description], ["Couldn't read the clipboard history", "The history couldn't be read."]);
});

test("a failed reload keeps the list as it was", async () => {
    const mounted = await open(link, hello);
    failures = { "clipboardHistory.list": "The history couldn't be read." };
    await run(mounted, "t1", "Pin");
    assert.deepEqual(items(mounted).map((each) => each.props.id), ["l1", "t1"]);
    assert.equal((calls.at(-1)!.params as { title: string }).title, "Couldn't read the clipboard history");
});
