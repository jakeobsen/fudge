import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { build } from "esbuild";
import React, { createElement, type FunctionComponent } from "react";
import * as jsxRuntime from "react/jsx-runtime";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";
import { createFudgeAppModule, searchFiles, type FoundFile } from "../src/fudge-app.ts";
import type { UINode } from "../src/renderer/serialize.ts";
import {
    detailFields,
    emptyView,
    formatDate,
    formatSize,
    searchLimit,
    tildePath,
    whereText,
} from "../file-search-extension/src/files.ts";
import { find, mount, type Mounted } from "./support/mount.ts";

// A fake app: `files.search` waits for the test to answer it; everything else is answered on the next tick.

let calls: RpcRequest[] = [];
let searches: RpcRequest[] = [];
let confirms = true;
let folder = "";

function launch(preferences: Record<string, unknown>) {
    setLaunchContext({
        preferences,
        environment: {
            ...placeholderEnvironment,
            extensionName: "fudge-file-search",
            commandName: "search-files",
            commandMode: "view",
            localStoragePath: path.join(folder, "local-storage.json"),
        },
        launchProps: {},
    });
}

beforeEach(() => {
    folder = mkdtempSync(path.join(tmpdir(), "fudge-file-search-"));
    calls = [];
    searches = [];
    confirms = true;
    launch({ searchIn: "home", leaveOut: "~/Library" });
    connect((request) => {
        calls.push(request);
        if (request.method === "files.search") {
            searches.push(request);
            return;
        }
        setImmediate(() => settle(request.id, request.method === "alert.confirm" ? confirms : null));
    });
});
afterEach(() => {
    connect(null);
    rmSync(folder, { recursive: true, force: true });
});

const home = "/Users/otter";
const modified = new Date("2026-11-02T09:30:00Z");
const opened = new Date("2026-11-20T16:05:00Z");

// `fudge:app`

test("searchFiles asks the app for files.search and revives its dates", async () => {
    const answer = searchFiles("report", 50);
    assert.deepEqual(searches.map((call) => call.params), [{ query: "report", limit: 50 }]);
    settle(searches[0]!.id, [
        {
            path: "/Users/otter/Report.pdf",
            name: "Report.pdf",
            kind: "PDF document",
            isFolder: false,
            size: 2048,
            modified: { $date: modified.toISOString() },
            lastUsed: { $date: opened.toISOString() },
        },
    ]);
    const [file] = await answer;
    assert.ok(file!.modified instanceof Date);
    assert.equal(file!.modified.getTime(), modified.getTime());
    assert.equal(file!.lastUsed?.getTime(), opened.getTime());
    assert.equal(file!.size, 2048);

    void searchFiles("");
    assert.deepEqual(searches[1]!.params, { query: "" }, "without a limit, the app's own default applies");
});

test("searchFiles rejects with the app's message", async () => {
    const answer = searchFiles("x");
    settle(searches[0]!.id, null, "files.search is only for Fudge's Search Files.");
    await assert.rejects(answer, { message: "files.search is only for Fudge's Search Files." });
});

test("the fudge:app module is frozen and holds searchFiles", () => {
    const module = createFudgeAppModule();
    assert.ok(Object.isFrozen(module));
    assert.equal(module.searchFiles, searchFiles);
});

// The extension's pure modules

test("a file's folder writes the home folder as ~", () => {
    assert.equal(whereText({ path: "/Users/otter/notes.txt" }, home), "~");
    assert.equal(whereText({ path: "/Users/otter/Documents/Work/plan.key" }, home), "~/Documents/Work");
    assert.equal(whereText({ path: "/Applications/Safari.app" }, home), "/Applications");
    assert.equal(whereText({ path: "/Users/otter" }, home), "/Users", "the home folder itself is in /Users");
    assert.equal(whereText({ path: "/Users/otterly/a.txt" }, home), "/Users/otterly", "a folder that only starts like home");
    assert.equal(whereText({ path: "/hello.txt" }, home), "/");
    assert.equal(tildePath("/Users/otter/Music", "/Users/otter/"), "~/Music");
    assert.equal(tildePath("/Users/otter", "/"), "/Users/otter", "a home of / isn't abbreviated");
});

test("sizes are written as Finder writes them", () => {
    assert.equal(formatSize(0, "en-US"), "0 bytes");
    assert.equal(formatSize(1, "en-US"), "1 byte");
    assert.equal(formatSize(999, "en-US"), "999 bytes");
    assert.equal(formatSize(1000, "en-US"), "1 KB");
    assert.equal(formatSize(12_345, "en-US"), "12 KB");
    assert.equal(formatSize(999_999, "en-US"), "1 MB", "rounding up moves to the next unit");
    assert.equal(formatSize(1_234_567, "en-US"), "1.2 MB");
    assert.equal(formatSize(5_000_000_000, "en-US"), "5 GB");
    assert.equal(formatSize(1_234_567, "da-DK"), "1,2 MB");
});

test("the detail's metadata: Kind, Size for files, Where, Modified, and Last Opened when known", () => {
    const file: FoundFile = {
        path: "/Users/otter/Documents/Report.pdf",
        name: "Report.pdf",
        kind: "PDF document",
        isFolder: false,
        size: 1_234_567,
        modified,
        lastUsed: opened,
    };
    assert.deepEqual(detailFields(file, home, "en-US"), [
        { title: "Kind", text: "PDF document" },
        { title: "Size", text: "1.2 MB" },
        { title: "Where", text: "~/Documents" },
        { title: "Modified", text: formatDate(modified, "en-US") },
        { title: "Last Opened", text: formatDate(opened, "en-US") },
    ]);

    const folderEntry: FoundFile = { path: "/Users/otter/Projects", name: "Projects", kind: "Folder", isFolder: true, size: 4096, modified };
    assert.deepEqual(
        detailFields(folderEntry, home, "en-US").map((field) => field.title),
        ["Kind", "Where", "Modified"],
        "a folder has no Size, and nothing is shown for a last use that isn't known",
    );
    const { size: _, ...sizeless } = file;
    assert.ok(!detailFields(sizeless, home).some((field) => field.title === "Size"));
});

test("the empty views", () => {
    assert.deepEqual(emptyView("", "home"), { title: "Type to Search Files" });
    assert.deepEqual(emptyView("   ", "mac"), { title: "Type to Search Files" });
    assert.deepEqual(emptyView("zebra", "home"), { title: "No Files Found", description: "Search In: Home Folder" });
    assert.deepEqual(emptyView("zebra", "mac"), { title: "No Files Found", description: "Search In: This Mac" });
    assert.deepEqual(emptyView("zebra", undefined), { title: "No Files Found", description: "Search In: Home Folder" });
});

// The command, compiled as `fudge build` compiles it and run against the fake app.

const extension = path.join(import.meta.dirname, "../file-search-extension");
let compiled: Promise<string> | null = null;

async function loadCommand(): Promise<FunctionComponent> {
    compiled ??= build({
        entryPoints: [path.join(extension, "src/search-files.tsx")],
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

const me = homedir();
const report = {
    path: path.join(me, "Documents/Report.pdf"),
    name: "Report.pdf",
    kind: "PDF document",
    isFolder: false,
    size: 1_234_567,
    modified: { $date: modified.toISOString() },
    lastUsed: { $date: opened.toISOString() },
};
const projects = { path: path.join(me, "Projects"), name: "Projects", kind: "Folder", isFolder: true, modified: { $date: modified.toISOString() } };
const elsewhere = { path: "/Applications/Notes.app", name: "Notes.app", kind: "Application", isFolder: false, modified: { $date: modified.toISOString() } };

const view = (mounted: Mounted) => mounted.snapshots.at(-1)!.view!;
const items = (mounted: Mounted) => view(mounted).children.filter((child) => child.type === "List.Item");
const actionsOf = (item: UINode) => (item.props.actions as unknown as UINode).children.flatMap((section) => section.children);
const action = (item: UINode, title: string) => actionsOf(item).find((entry) => entry.props.title === title)!;

async function answer(mounted: Mounted, search: RpcRequest, files: unknown[]) {
    settle(search.id, files);
    await mounted.settle();
}

async function type(mounted: Mounted, text: string) {
    mounted.root.dispatch(view(mounted).id, ["onSearchTextChange"], [text]);
    await mounted.settle();
}

async function searchFilesWith(...files: unknown[]) {
    const mounted = await mount(createElement(await loadCommand()));
    await mounted.settle();
    await answer(mounted, searches[0]!, files);
    return mounted;
}

test("the list searches as the user types, without filtering, showing the detail pane", async () => {
    const mounted = await mount(createElement(await loadCommand()));
    await mounted.settle();
    const list = view(mounted);
    assert.equal(list.type, "List");
    assert.equal(list.props.filtering, false);
    assert.equal(list.props.throttle, true);
    assert.equal(list.props.isLoading, true);
    assert.equal(list.props.isShowingDetail, true);
    assert.deepEqual(list.props.onSearchTextChange, { $fn: ["onSearchTextChange"] });
    assert.equal(find(list, "List.EmptyView"), undefined, "no empty view while loading");
    assert.deepEqual(searches.map((call) => call.params), [{ query: "", limit: searchLimit }]);

    await answer(mounted, searches[0]!, [report]);
    await type(mounted, "rep");
    assert.deepEqual(searches[1]!.params, { query: "rep", limit: 200 });
    assert.equal(view(mounted).props.isLoading, true);
    assert.deepEqual(items(mounted).map((item) => item.props.title), ["Report.pdf"], "the last answer stays meanwhile");
    await answer(mounted, searches[1]!, [report, projects]);
    assert.equal(view(mounted).props.isLoading, false);
    assert.deepEqual(items(mounted).map((item) => item.props.title), ["Report.pdf", "Projects"]);
});

test("each item: name, folder, file icon, modified date, Quick Look and its path as id", async () => {
    const mounted = await searchFilesWith(report, projects, elsewhere);
    assert.deepEqual(
        items(mounted).map(({ props }) => [props.id, props.title, props.subtitle, props.icon, props.accessories, props.quickLook]),
        [
            [report.path, "Report.pdf", "~/Documents", { fileIcon: report.path }, [{ date: report.modified }], { path: report.path, name: "Report.pdf" }],
            [projects.path, "Projects", "~", { fileIcon: projects.path }, [{ date: projects.modified }], { path: projects.path, name: "Projects" }],
            [elsewhere.path, "Notes.app", "/Applications", { fileIcon: elsewhere.path }, [{ date: elsewhere.modified }], { path: elsewhere.path, name: "Notes.app" }],
        ],
    );
});

test("the detail pane shows the file's metadata", async () => {
    const mounted = await searchFilesWith(report);
    const detail = items(mounted)[0]!.props.detail as unknown as UINode;
    assert.equal(detail.type, "List.Item.Detail");
    const metadata = detail.props.metadata as unknown as UINode;
    assert.deepEqual(
        metadata.children.map((label) => [label.type, label.props.title, label.props.text]),
        [
            ["Metadata.Label", "Kind", "PDF document"],
            ["Metadata.Label", "Size", formatSize(report.size)],
            ["Metadata.Label", "Where", "~/Documents"],
            ["Metadata.Label", "Modified", formatDate(modified)],
            ["Metadata.Label", "Last Opened", formatDate(opened)],
        ],
    );
});

test("the actions, in order, with their shortcuts; the first two take ↵ and ⌘↵", async () => {
    const mounted = await searchFilesWith(report);
    const entries = actionsOf(items(mounted)[0]!);
    assert.deepEqual(
        entries.map((entry) => [entry.type, entry.props.title, entry.props.shortcut ?? null]),
        [
            ["Action", "Open", null],
            ["Action", "Show in Finder", null],
            ["Action", "Quick Look", { modifiers: ["cmd"], key: "y" }],
            ["ActionPanel.Submenu", "Open With…", { modifiers: ["cmd"], key: "o" }],
            ["Action", "Copy Path", { modifiers: ["cmd", "shift"], key: "c" }],
            ["Action", "Copy File", { modifiers: ["cmd", "opt"], key: "c" }],
            ["Action", "Move to Trash", { modifiers: ["ctrl"], key: "x" }],
            ["Action", "Hide Details", { modifiers: ["cmd", "shift"], key: "d" }],
        ],
    );
    assert.equal(action(items(mounted)[0]!, "Quick Look").props.fudgeBuiltIn, "toggleQuickLook");
    assert.equal(action(items(mounted)[0]!, "Move to Trash").props.style, "destructive");

    const run = (title: string) => mounted.root.dispatch(action(items(mounted)[0]!, title).id, ["onAction"], []);
    await run("Open");
    await run("Show in Finder");
    await run("Copy Path");
    await run("Copy File");
    assert.deepEqual(
        calls.filter((call) => call.method !== "files.search" && call.method !== "window.close").map((call) => [call.method, call.params]),
        [
            ["open", { target: report.path, application: null }],
            ["showInFinder", { path: report.path }],
            ["clipboard.copy", { text: report.path, concealed: false, transient: false }],
            ["hud.show", { title: "Copied to Clipboard", clearRootSearch: false, popToRootType: "default" }],
            ["clipboard.copy", { file: report.path, concealed: false, transient: false }],
            ["hud.show", { title: "Copied File", clearRootSearch: false, popToRootType: "default" }],
        ],
    );
});

test("Move to Trash asks first, then trashes the file and takes it off the list", async () => {
    const mounted = await searchFilesWith(report, projects);
    confirms = false;
    await mounted.root.dispatch(action(items(mounted)[0]!, "Move to Trash").id, ["onAction"], []);
    await mounted.settle();
    assert.deepEqual(calls.filter((call) => call.method === "alert.confirm" || call.method === "trash").map((call) => call.method), ["alert.confirm"]);
    assert.equal(items(mounted).length, 2, "declined: nothing is trashed");

    confirms = true;
    await mounted.root.dispatch(action(items(mounted)[0]!, "Move to Trash").id, ["onAction"], []);
    await mounted.settle();
    const confirm = calls.filter((call) => call.method === "alert.confirm").at(-1)!.params as { title: string; primaryAction: unknown };
    assert.equal(confirm.title, "Move “Report.pdf” to the Trash?");
    assert.deepEqual(confirm.primaryAction, { title: "Move to Trash", style: "destructive" });
    assert.deepEqual(calls.find((call) => call.method === "trash")!.params, { paths: [report.path] });
    assert.deepEqual(items(mounted).map((item) => item.props.title), ["Projects"]);
    assert.equal((calls.at(-1)!.params as { title: string }).title, "Moved to Trash");
});

test("Show/Hide Details toggles the pane, and the choice is remembered for the next run", async () => {
    const first = await searchFilesWith(report);
    await first.root.dispatch(action(items(first)[0]!, "Hide Details").id, ["onAction"], []);
    await first.settle();
    assert.equal(view(first).props.isShowingDetail, false);
    assert.ok(action(items(first)[0]!, "Show Details"));
    assert.deepEqual(JSON.parse(readFileSync(path.join(folder, "local-storage.json"), "utf8")), { showingDetail: false });
    first.root.unmount();

    searches = [];
    const second = await searchFilesWith(report);
    assert.equal(view(second).props.isShowingDetail, false);
});

test("the empty views, never while loading", async () => {
    const mounted = await searchFilesWith();
    let empty = find(view(mounted), "List.EmptyView")!;
    assert.equal(empty.props.title, "Type to Search Files", "nothing used lately");

    await type(mounted, "zebra");
    assert.equal(find(view(mounted), "List.EmptyView"), undefined);
    await answer(mounted, searches[1]!, []);
    empty = find(view(mounted), "List.EmptyView")!;
    assert.deepEqual([empty.props.title, empty.props.description], ["No Files Found", "Search In: Home Folder"]);
    mounted.root.unmount();

    searches = [];
    launch({ searchIn: "mac", leaveOut: "" });
    const onTheMac = await searchFilesWith();
    await type(onTheMac, "zebra");
    await answer(onTheMac, searches[1]!, []);
    empty = find(view(onTheMac), "List.EmptyView")!;
    assert.deepEqual([empty.props.title, empty.props.description], ["No Files Found", "Search In: This Mac"]);
});

test("an older search's answer that comes after a newer one started is ignored", async () => {
    const mounted = await searchFilesWith();
    await type(mounted, "re");
    await type(mounted, "rep");
    assert.deepEqual(searches.map((call) => (call.params as { query: string }).query), ["", "re", "rep"]);
    await answer(mounted, searches[2]!, [report]);
    await answer(mounted, searches[1]!, [report, projects, elsewhere]);
    assert.deepEqual(items(mounted).map((item) => item.props.title), ["Report.pdf"]);
    assert.equal(view(mounted).props.isLoading, false);
});

test("a failed search shows a failure toast with its message", async () => {
    const mounted = await mount(createElement(await loadCommand()));
    await mounted.settle();
    settle(searches[0]!.id, null, "Spotlight is turned off.");
    await mounted.settle();
    const toast = calls.find((call) => call.method === "toast.show")!.params as Record<string, unknown>;
    assert.deepEqual([toast.style, toast.title, toast.message], ["FAILURE", "Couldn't search files", "Spotlight is turned off."]);
    assert.equal(view(mounted).props.isLoading, false);
});
