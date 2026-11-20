import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { pathToFileURL } from "node:url";
import { Cache, Clipboard, LocalStorage, environment, getApplications, open, pasteText, showInFinder, trash } from "../src/api/index.ts";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";

let folder = "";
let calls: RpcRequest[] = [];

beforeEach(() => {
    folder = mkdtempSync(join(tmpdir(), "fudge-api-"));
    setLaunchContext({
        preferences: {},
        environment: {
            ...placeholderEnvironment,
            extensionName: "scratch",
            commandName: "scratch-folders",
            commandMode: "view",
            assetsPath: "/ext/scratch/assets",
            supportPath: join(folder, "support"),
            cachePath: join(folder, "cache"),
            localStoragePath: join(folder, "local-storage.json"),
            ownerOrAuthorName: "someone",
            appearance: "light",
        },
        launchProps: { launchType: "background", launchContext: { from: "test" } },
    });
    calls = [];
    // A fake app: records each call and answers it on the next tick.
    connect((request) => {
        calls.push(request);
        setImmediate(() => settle(request.id, request.method === "applications.list" ? [{ name: "Code", path: "/A/Code.app" }] : null));
    });
});
afterEach(() => connect(null));

test("environment describes the launch", () => {
    assert.equal(environment.extensionName, "scratch");
    assert.equal(environment.commandName, "scratch-folders");
    assert.equal(environment.commandMode, "view");
    assert.equal(environment.entryPointName, "scratch-folders");
    assert.equal(environment.supportPath, join(folder, "support"));
    assert.equal(environment.assetsPath, "/ext/scratch/assets");
    assert.equal(environment.appearance, "light");
    assert.equal(environment.theme, "light");
    assert.equal(environment.launchType, "background");
    assert.deepEqual(environment.launchContext, { from: "test" });
    assert.equal(environment.raycastVersion, "2.13.1");
    assert.equal(environment.isDevelopment, false);
});

test("environment.canAccess is false for APIs fudge doesn't have", () => {
    const api = createApiModule();
    assert.equal(environment.canAccess(api.Clipboard), true);
    assert.equal(environment.canAccess(api.AI), false);
    assert.equal(environment.canAccess(undefined), false);
});

test("LocalStorage keeps values per extension in its file", async () => {
    assert.equal(await LocalStorage.getItem("missing"), undefined);
    await LocalStorage.setItem("count", 3);
    await LocalStorage.setItem("pinned", true);
    await LocalStorage.setItem("name", "otter");
    assert.equal(await LocalStorage.getItem<number>("count"), 3);
    assert.deepEqual(await LocalStorage.allItems(), { count: 3, pinned: true, name: "otter" });
    await LocalStorage.removeItem("pinned");
    assert.deepEqual(JSON.parse(readFileSync(join(folder, "local-storage.json"), "utf8")), { count: 3, name: "otter" });
    await LocalStorage.clear();
    assert.deepEqual(await LocalStorage.allItems(), {});
});

test("Cache is synchronous, persists, and shares a folder between instances", () => {
    const cache = new Cache();
    assert.equal(cache.isEmpty, true);
    cache.set("a", "1");
    assert.equal(new Cache().get("a"), "1", "another instance sees it");
    assert.equal(cache.has("a"), true);
    assert.equal(cache.remove("a"), true);
    assert.equal(cache.remove("a"), false);
    const named = new Cache({ namespace: "projects" });
    named.set("list", "[]");
    assert.equal(named.storageDirectory, join(folder, "cache", "projects"));
    assert.deepEqual(JSON.parse(readFileSync(join(folder, "cache", "projects", "cache.json"), "utf8")), { list: "[]" });
    assert.equal(new Cache().has("list"), false, "namespaces are separate");
});

test("Cache drops the least recently used entries beyond its capacity", () => {
    const cache = new Cache({ namespace: "small", capacity: 10 });
    cache.set("a", "1111");
    cache.set("b", "2222");
    cache.get("a");
    cache.set("c", "3333");
    assert.equal(cache.has("b"), false, "b was least recently used");
    assert.equal(cache.has("a"), true);
    assert.equal(cache.has("c"), true);
});

test("Cache subscribers hear sets, removals and clears", () => {
    const cache = new Cache({ namespace: "events" });
    const heard: [string | undefined, string | undefined][] = [];
    const unsubscribe = cache.subscribe((key, data) => heard.push([key, data]));
    cache.set("k", "v");
    cache.remove("k");
    cache.clear();
    cache.clear({ notifySubscribers: false });
    unsubscribe();
    cache.set("k", "again");
    assert.deepEqual(heard, [["k", "v"], ["k", undefined], [undefined, undefined]]);
});

test("Cache methods work detached, as useSyncExternalStore calls subscribe", () => {
    const { get, has, set, remove, clear, subscribe } = new Cache({ namespace: "detached" });
    const heard: (string | undefined)[] = [];
    const unsubscribe = subscribe((key) => heard.push(key));
    set("k", "v");
    assert.equal(get("k"), "v");
    assert.equal(has("k"), true);
    assert.equal(remove("k"), true);
    clear();
    unsubscribe();
    assert.deepEqual(heard, ["k", "k", undefined]);
});

test("Clipboard calls go to the app", async () => {
    await Clipboard.copy("hello", { concealed: true });
    await Clipboard.copy(42);
    await Clipboard.copy({ file: pathToFileURL("/tmp/x.txt") });
    await Clipboard.copy({ html: "<b>hi</b>", text: "hi" });
    assert.equal(await Clipboard.readText(), undefined, "the fake app returns nothing");
    assert.deepEqual(await Clipboard.read(), { text: "" });
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["clipboard.copy", { text: "hello", concealed: true, transient: false }],
            ["clipboard.copy", { text: "42", concealed: false, transient: false }],
            ["clipboard.copy", { file: "/tmp/x.txt", concealed: false, transient: false }],
            ["clipboard.copy", { html: "<b>hi</b>", text: "hi", concealed: false, transient: false }],
            ["clipboard.read", { offset: 0 }],
            ["clipboard.read", { offset: 0 }],
        ],
    );
});

test("Clipboard.paste goes to the app with the content and closeMainWindow, and its errors reject", async () => {
    await Clipboard.paste("x");
    await Clipboard.paste({ file: "/tmp/a.txt" }, { closeMainWindow: false });
    await pasteText("old API");
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["clipboard.paste", { text: "x", closeMainWindow: true }],
            ["clipboard.paste", { file: "/tmp/a.txt", closeMainWindow: false }],
            ["clipboard.paste", { text: "old API", closeMainWindow: true }],
        ],
    );
    connect((request) => setImmediate(() => settle(request.id, undefined, "There is no app to paste into")));
    await assert.rejects(Clipboard.paste("x"), /There is no app to paste into/);
});

test("open, trash, showInFinder and getApplications go to the app", async () => {
    await open("https://example.com");
    await open("/tmp/a", { name: "Code", path: "/A/Code.app" });
    await trash(["/tmp/a", pathToFileURL("/tmp/b")]);
    await showInFinder("/tmp/a");
    assert.deepEqual(await getApplications("/tmp/a"), [{ name: "Code", path: "/A/Code.app" }]);
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["open", { target: "https://example.com", application: null }],
            ["open", { target: "/tmp/a", application: "/A/Code.app" }],
            ["trash", { paths: ["/tmp/a", "/tmp/b"] }],
            ["showInFinder", { path: "/tmp/a" }],
            ["applications.list", { path: "/tmp/a" }],
        ],
    );
});
