import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import https from "node:https";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import type { HostMessage } from "../src/protocol.ts";
import type { UINode } from "../src/renderer/serialize.ts";

const hostPath = fileURLToPath(new URL("../src/host.ts", import.meta.url));
const fixture = (name: string) => fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url));

type Message = HostMessage & Record<string, unknown>;

/** A running host and the messages it has sent. */
class Host {
    readonly process: ChildProcessWithoutNullStreams;
    private readonly received: Message[] = [];
    /** Every message, in the order it arrived. */
    readonly arrived: Message[] = [];
    private readonly waiting: { match: (m: Message) => boolean; resolve: (m: Message) => void }[] = [];

    constructor(environment: Record<string, string> = {}) {
        this.process = spawn(process.execPath, [hostPath], {
            stdio: ["pipe", "pipe", "pipe"],
            env: { ...process.env, ...environment },
        });
        createInterface({ input: this.process.stdout }).on("line", (line) => {
            const message = JSON.parse(line) as Message;
            this.arrived.push(message);
            const index = this.waiting.findIndex((w) => w.match(message));
            if (index === -1) this.received.push(message);
            else this.waiting.splice(index, 1)[0]!.resolve(message);
        });
    }

    send(message: object): void {
        this.process.stdin.write(`${JSON.stringify(message)}\n`);
    }

    /** The first message (already received or still to come) that matches. */
    next(match: (m: Message) => boolean, timeoutMs = 5000): Promise<Message> {
        const index = this.received.findIndex(match);
        if (index !== -1) return Promise.resolve(this.received.splice(index, 1)[0]!);
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error("timed out waiting for a message")), timeoutMs);
            this.waiting.push({
                match,
                resolve: (m) => {
                    clearTimeout(timer);
                    resolve(m);
                },
            });
        });
    }

    async close(): Promise<number | null> {
        this.process.stdin.end();
        const [code] = await once(this.process, "exit");
        return code as number | null;
    }
}

const hosts: Host[] = [];
const start = (environment: Record<string, string> = {}) => {
    const host = new Host(environment);
    hosts.push(host);
    return host;
};
after(() => {
    for (const host of hosts) host.process.kill();
});

const of = (session: string, type: string) => (m: Message) => m.session === session && m.type === type;

test("ping and protocol errors", async () => {
    const host = start();
    host.send({ type: "ping", id: 1 });
    assert.deepEqual(await host.next((m) => m.type === "pong"), { type: "pong", id: 1 });

    host.send({ type: "event", session: "nobody", node: 1, path: ["onAction"] });
    const error = await host.next((m) => m.type === "protocolError");
    assert.match(String(error.message), /no running session `nobody`/);
    assert.equal(await host.close(), 0);
});

test("a view command renders, handles an event and renders again", async () => {
    const host = start();
    host.send({ type: "launch", session: "s1", entry: fixture("counter.cjs"), mode: "view", launchProps: { arguments: { name: "Fixture" } } });

    const first = await host.next(of("s1", "render"));
    assert.equal(first.depth, 1);
    const list = first.view as UINode;
    assert.equal(list.type, "List");
    assert.equal(list.props.navigationTitle, "Fixture");
    const item = list.children[0]!;
    assert.equal(item.props.title, "count 0");
    const action = (item.props.actions as unknown as UINode).children[0]!;

    host.send({ type: "event", session: "s1", node: action.id, path: ["onAction"], args: [] });
    const second = await host.next(of("s1", "render"));
    assert.equal((second.view as UINode).children[0]!.props.title, "count 1");

    host.send({ type: "unload", session: "s1" });
    assert.deepEqual(await host.next(of("s1", "exit")), { type: "exit", reason: "unloaded", session: "s1" });
    assert.equal(await host.close(), 0);
});

test("slots answers with the items' action panels", async () => {
    const host = start();
    host.send({ type: "launch", session: "s1", entry: fixture("counter.cjs"), mode: "view" });
    const first = await host.next(of("s1", "render"));
    const item = (first.view as UINode).children[0]!;

    host.send({ type: "slots", session: "s1", nodes: [item.id, 9999] });
    const answer = await host.next(of("s1", "slots"));
    assert.deepEqual(answer, {
        type: "slots",
        session: "s1",
        items: [
            { id: item.id, slots: { actions: item.props.actions } },
            { id: 9999, slots: {} },
        ],
    });

    host.send({ type: "unload", session: "s1" });
    await host.next(of("s1", "exit"));
    assert.equal(await host.close(), 0);
});

test("a keyed List re-ranked by a search: each row's detail and actions, inline or answered, are its own", async () => {
    const host = start();
    host.send({ type: "launch", session: "k", entry: fixture("keyed-search.cjs"), mode: "view" });
    const first = (await host.next(of("k", "render"))).view as UINode;
    const titleOf = new Map(first.children.map((row) => [row.id, String(row.props.title)]));
    /** The detail's markdown and the panel's action title a row's slots carry, or null when they're held back. */
    const carried = (slots: Record<string, unknown>) => {
        const detail = slots.detail as UINode | { $deferred: true };
        const actions = slots.actions as UINode | { $deferred: true };
        if (!("type" in detail) || !("type" in actions)) return null;
        return { markdown: detail.props.markdown, action: actions.children[0]!.props.title };
    };
    const ownFor = (id: number) => ({ markdown: `# ${titleOf.get(id)}`, action: `Open ${titleOf.get(id)}` });

    // The app asks for the window around the first row, rows 0 to 10.
    const window = first.children.slice(0, 11).map((row) => row.id);
    host.send({ type: "slots", session: "k", nodes: window });
    await host.next(of("k", "slots"));

    // The user types, and the extension reverses its rows.
    host.send({ type: "event", session: "k", node: first.id, path: ["onSearchTextChange"], args: ["x"] });
    const after = (await host.next(of("k", "render"))).view as UINode;
    assert.deepEqual(
        after.children.map((row) => row.props.title),
        [...first.children].reverse().map((row) => row.props.title),
    );
    // Every row carried in full is its own; the others are held back.
    let inline = 0;
    for (const row of after.children) {
        const slots = carried(row.props as Record<string, unknown>);
        if (slots === null) continue;
        inline += 1;
        assert.deepEqual(slots, ownFor(row.id), `row ${titleOf.get(row.id)}`);
    }
    assert.equal(inline, 12, "the new first row and the 11 asked for");

    // The selected row is file-20: neither first nor in the last request, so it's held back, and asked for.
    const selected = after.children.find((row) => row.props.title === "file-20")!;
    assert.equal(carried(selected.props as Record<string, unknown>), null);
    const index = after.children.indexOf(selected);
    const asked = after.children.slice(Math.max(0, index - 8), index + 11).map((row) => row.id);
    host.send({ type: "slots", session: "k", nodes: asked });
    const answer = await host.next(of("k", "slots"));
    for (const item of answer.items as { id: number; slots: Record<string, unknown> }[]) {
        assert.deepEqual(carried(item.slots), ownFor(item.id), `answer for ${titleOf.get(item.id)}`);
    }

    host.send({ type: "unload", session: "k" });
    await host.next(of("k", "exit"));
    assert.equal(await host.close(), 0);
});

test("a menu-bar command renders its MenuBarExtra, and every event is answered once its handler settles", async () => {
    const host = start();
    host.send({ type: "launch", session: "mb", entry: fixture("menu-bar.cjs"), mode: "menu-bar", launchProps: { launchType: "background" } });

    const first = await host.next(of("mb", "render"));
    const extra = first.view as UINode;
    assert.equal(extra.type, "MenuBarExtra");
    assert.deepEqual([extra.props.title, extra.props.tooltip, extra.props.isLoading], ["0", "background", false]);
    assert.deepEqual(
        extra.children.map((child) => child.type),
        ["MenuBarExtra.Item", "MenuBarExtra.Section", "MenuBarExtra.Separator", "MenuBarExtra.Submenu"],
    );
    const [add, fail] = extra.children[1]!.children;
    assert.deepEqual([add!.props.title, add!.props.subtitle, add!.props.shortcut], ["Add", "one", { modifiers: ["cmd"], key: "a" }]);
    assert.deepEqual(add!.props.onAction, { $fn: ["onAction"] });
    const alternate = add!.props.alternate as unknown as UINode;
    assert.equal(alternate.type, "MenuBarExtra.Item");
    assert.equal(alternate.props.title, "Add Later");
    assert.equal(extra.children[3]!.children[0]!.props.title, "Deep");

    // A plain handler: settled straight away.
    host.send({ type: "event", session: "mb", node: add!.id, path: ["onAction"], args: [{ type: "left-click" }] });
    const plainSettled = await host.next(of("mb", "eventSettled"));
    const plainRender = await host.next(of("mb", "render"));
    assert.equal((plainRender.view as UINode).props.title, "1");
    assert.ok(host.arrived.indexOf(plainRender) < host.arrived.indexOf(plainSettled), "rendered first");

    // A handler's promise that sets state and then resolves: settled after the render it caused has been sent, so
    // the app never takes the command as idle with that render still to come.
    host.send({ type: "event", session: "mb", node: alternate.id, path: ["onAction"], args: [{ type: "left-click" }] });
    const settled = await host.next(of("mb", "eventSettled"));
    const rendered = await host.next(of("mb", "render"));
    assert.equal((rendered.view as UINode).props.title, "11");
    assert.ok(host.arrived.indexOf(rendered) < host.arrived.indexOf(settled), "the render arrived before eventSettled");

    // A rejected promise is reported and logged with its stack, then settled; a stale node is logged as a warning,
    // then settled.
    host.send({ type: "event", session: "mb", node: fail!.id, path: ["onAction"], args: [] });
    assert.equal((await host.next(of("mb", "error"))).message, "nope");
    const logged = await host.next(of("mb", "log"));
    assert.equal(logged.level, "error");
    assert.match(String(logged.message), /^Error: nope\n {4}at onAction /);
    await host.next(of("mb", "eventSettled"));
    host.send({ type: "event", session: "mb", node: 99999, path: ["onAction"], args: [] });
    const ignored = await host.next(of("mb", "log"));
    assert.equal(ignored.level, "warning");
    assert.match(String(ignored.message), /ignored an event/);
    await host.next(of("mb", "eventSettled"));

    host.send({ type: "unload", session: "mb" });
    assert.equal((await host.next(of("mb", "exit"))).reason, "unloaded");
    await host.close();
});

test("a worker trusts the CA the host is started with, by fetch and by https (SPEC-081)", async () => {
    // A self-signed CA for 127.0.0.1, made for this run, as the app hands the Mac's certificates to an older Node.
    const certs = mkdtempSync(path.join(tmpdir(), "fudge-ca-"));
    execFileSync("openssl", [
        "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
        "-addext", "subjectAltName=IP:127.0.0.1",
        "-keyout", path.join(certs, "key.pem"), "-out", path.join(certs, "cert.pem"),
    ], { stdio: "ignore" });
    const server = https.createServer(
        { key: readFileSync(path.join(certs, "key.pem")), cert: readFileSync(path.join(certs, "cert.pem")) },
        (_request, response) => response.end("trusted"),
    );
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const url = `https://127.0.0.1:${(server.address() as AddressInfo).port}/`;
    const run = async (environment: Record<string, string>) => {
        const host = start(environment);
        host.send({ type: "launch", session: "ca", entry: fixture("trusted-fetch.cjs"), mode: "no-view", launchProps: { arguments: { url } } });
        const log = await host.next(of("ca", "log"));
        await host.close();
        return String(log.message);
    };
    try {
        assert.equal(await run({ NODE_EXTRA_CA_CERTS: path.join(certs, "cert.pem") }), "trusted | trusted");
        assert.match(await run({}), /^failed: .*SELF_SIGNED.* \| failed: .*SELF_SIGNED/, "without it, both refuse");
    } finally {
        server.close();
    }
});

test("a no-view command runs to completion and its console output arrives as logs", async () => {
    const host = start();
    host.send({ type: "launch", session: "nv", entry: fixture("no-view.cjs"), mode: "no-view", launchProps: { arguments: { q: "x" } } });
    const log = await host.next(of("nv", "log"));
    assert.deepEqual(log, { session: "nv", type: "log", level: "info", message: 'ran with {"q":"x"}' });
    assert.equal((await host.next(of("nv", "exit"))).reason, "finished");
    await host.close();
});

test("a command can't reach Raycast's sign-in proxy, by https kept at load or by a raw socket", async () => {
    const host = start();
    host.send({ type: "launch", session: "rp", entry: fixture("raycast-proxy.cjs"), mode: "no-view" });
    const log = await host.next(of("rp", "log"));
    assert.equal(
        log.message,
        "Fudge doesn't send requests to github.oauth.raycast.com. | Fudge doesn't send requests to x.oauth.raycast.com.",
    );
    assert.equal((await host.next(of("rp", "exit"))).reason, "finished");
    await host.close();
});

test("a no-view command's last console output arrives before its exit, every time", async () => {
    const host = start();
    for (let run = 0; run < 5; run++) {
        const session = `burst${run}`;
        host.send({ type: "launch", session, entry: fixture("log-then-return.cjs"), mode: "no-view" });
        assert.equal((await host.next(of(session, "exit"))).reason, "finished");
        const logs = host.arrived.filter(of(session, "log"));
        assert.equal(logs.length, 202, `run ${run}: every line before the exit`);
        // Each stream keeps its order; the two streams are separate.
        const stdout = logs.filter((m) => m.level === "info").map((m) => m.message);
        assert.deepEqual(stdout, [...Array.from({ length: 200 }, (_, i) => `line ${i + 1}`), "last on stdout"]);
        assert.deepEqual(logs.filter((m) => m.level === "error").map((m) => m.message), ["last on stderr"]);
    }
    await host.close();
});

test("getPreferenceValues returns the preferences sent with the launch", async () => {
    const host = start();
    const preferences = { openInEditor: true, staleDays: "7", editorApp: { name: "Code", path: "/Applications/Code.app" } };
    host.send({ type: "launch", session: "p", entry: fixture("preferences.cjs"), mode: "no-view", preferences });
    const log = await host.next(of("p", "log"));
    assert.deepEqual(JSON.parse(String(log.message)), preferences);
    await host.close();
});

test("a toast's action runs when the app sends toastAction", async () => {
    const host = start();
    host.send({ type: "launch", session: "t", entry: fixture("toast-action.cjs"), mode: "view" });
    const rpc = await host.next(of("t", "rpc"));
    assert.equal(rpc.method, "toast.show");
    host.send({ type: "rpcResult", session: "t", id: rpc.id, result: null });
    const toast = (rpc.params as { id: number }).id;
    host.send({ type: "toastAction", session: "t", toast, action: "primary" });
    assert.equal((await host.next(of("t", "log"))).message, "undo: Saved");
    await host.close();
});

test("a refusal on purpose comes back as a notice, through the extension's own wrapping (SPEC-095)", async () => {
    const host = start();
    host.send({ type: "launch", session: "so", entry: fixture("sign-in-off.cjs"), mode: "no-view" });
    const prepare = await host.next(of("so", "rpc"));
    assert.equal(prepare.method, "oauth.prepare");
    const refusal = "Sign-in is off. This extension needs to sign in with OAuth to work.";
    host.send({ type: "rpcResult", session: "so", id: prepare.id, error: refusal, notice: "signInOff" });
    const error = await host.next(of("so", "error"));
    assert.deepEqual(
        { message: error.message, fatal: error.fatal, notice: error.notice },
        { message: refusal, fatal: true, notice: "signInOff" },
    );
    assert.match(String(error.stack), /Couldn't search repositories/, "the stack, for the log, is the extension's error");
    assert.equal((await host.next(of("so", "exit"))).reason, "crashed");
    await host.close();
});

test("a refusal the app gives no notice is a failure as before", async () => {
    const host = start();
    host.send({ type: "launch", session: "sf", entry: fixture("sign-in-off.cjs"), mode: "no-view" });
    const prepare = await host.next(of("sf", "rpc"));
    host.send({ type: "rpcResult", session: "sf", id: prepare.id, error: "Fudge can't sign in to GitHub yet." });
    const error = await host.next(of("sf", "error"));
    assert.equal(error.message, "Couldn't search repositories");
    assert.equal("notice" in error, false);
    await host.close();
});

test("the extension and the renderer share one React", async () => {
    const host = start();
    host.send({ type: "launch", session: "r", entry: fixture("same-react.cjs"), mode: "view" });
    const render = await host.next(of("r", "render"));
    assert.equal((render.view as UINode).props.markdown, "from the extension; can push: function");
    await host.close();
});

test("a missing API fails with an error naming it", async () => {
    const host = start();
    host.send({ type: "launch", session: "m", entry: fixture("missing-api.cjs"), mode: "no-view" });
    const error = await host.next(of("m", "error"));
    assert.equal(error.message, "captureMemorySnapshot isn't available in Fudge yet");
    assert.equal(error.fatal, true);
    assert.equal((await host.next(of("m", "exit"))).reason, "crashed");
    await host.close();
});

test("an error while rendering is reported as fatal, with its stack", async () => {
    const host = start();
    host.send({ type: "launch", session: "b", entry: fixture("broken-view.cjs"), mode: "view" });
    const error = await host.next(of("b", "error"));
    assert.equal(error.message, "render went wrong");
    assert.equal(error.fatal, true);
    assert.match(String(error.stack), /broken-view\.cjs/);
    await host.close();
});

test("a command file that can't be loaded is reported", async () => {
    const host = start();
    host.send({ type: "launch", session: "x", entry: fixture("does-not-exist.cjs"), mode: "view" });
    assert.match(String((await host.next(of("x", "error"))).message), /Cannot find module/);
    assert.equal((await host.next(of("x", "exit"))).reason, "crashed");
    await host.close();
});

test("an old module that only calls render() renders that element, which handles events", async () => {
    const host = start();
    host.send({ type: "launch", session: "old", entry: fixture("render-only.cjs"), mode: "view" });
    const first = await host.next(of("old", "render"));
    const list = first.view as UINode;
    assert.equal(list.type, "List");
    assert.equal(list.props.navigationTitle, "rendered");
    const item = list.children[0]!;
    assert.equal(item.props.title, "count 0");
    const log = await host.next(of("old", "log"));
    assert.equal(log.level, "error");
    assert.match(String(log.message), /render\(\) was called again/, "a second call is ignored, with a log line");

    const action = (item.props.actions as unknown as UINode).children[0]!;
    host.send({ type: "event", session: "old", node: action.id, path: ["onAction"], args: [] });
    assert.equal(((await host.next(of("old", "render"))).view as UINode).children[0]!.props.title, "count 1");
    await host.close();
});

test("a no-view command that only calls render() fails, saying why, rather than showing nothing", async () => {
    const host = start();
    host.send({ type: "launch", session: "nv", entry: fixture("render-only.cjs"), mode: "no-view" });
    const error = await host.next(of("nv", "error"));
    assert.match(String(error.message), /render-only\.cjs shows a view with render\(\), but it's a no-view command$/);
    assert.equal(error.fatal, true);
    assert.equal((await host.next(of("nv", "exit"))).reason, "crashed");
    assert.equal(host.arrived.some(of("nv", "render")), false, "nothing was rendered");
    await host.close();
});

test("a menu-bar command that only calls render() renders it", async () => {
    const host = start();
    host.send({ type: "launch", session: "mbr", entry: fixture("render-only.cjs"), mode: "menu-bar" });
    assert.equal(((await host.next(of("mbr", "render"))).view as UINode).props.navigationTitle, "rendered");
    await host.close();
});

test("a module with a default export uses it, even if it called render()", async () => {
    const host = start();
    host.send({ type: "launch", session: "d", entry: fixture("render-and-default.cjs"), mode: "view" });
    assert.equal(((await host.next(of("d", "render"))).view as UINode).props.markdown, "from the default export");
    await host.close();
});

test("a module with neither a default export nor render() is reported", async () => {
    const host = start();
    host.send({ type: "launch", session: "n", entry: fixture("nothing.cjs"), mode: "view" });
    assert.match(String((await host.next(of("n", "error"))).message), /has no default export to run/);
    assert.equal((await host.next(of("n", "exit"))).reason, "crashed");
    await host.close();
});

test("an old no-view module's top-level code is its run, and it finishes when that's done", async () => {
    const host = start();
    host.send({ type: "launch", session: "tl", entry: fixture("top-level-sync.cjs"), mode: "no-view" });
    assert.equal((await host.next(of("tl", "exit"))).reason, "finished");
    const logs = host.arrived.filter(of("tl", "log")).map((m) => m.message);
    assert.deepEqual(logs, ["one", "two"], "its log lines, in order, before it ends");
    assert.equal(host.arrived.some(of("tl", "error")), false);
    await host.close();
});

test("an old no-view module's async work keeps it running until its calls and timers are done", async () => {
    const host = start();
    host.send({ type: "launch", session: "ta", entry: fixture("top-level-async.cjs"), mode: "no-view" });
    const copy = await host.next(of("ta", "rpc"));
    assert.equal(copy.method, "clipboard.copy");
    // The answer is late: the pending call keeps the worker alive meanwhile.
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(host.arrived.some(of("ta", "exit")), false, "still running while the call waits");
    host.send({ type: "rpcResult", session: "ta", id: copy.id, result: null });
    const hud = await host.next(of("ta", "rpc"));
    assert.equal(hud.method, "hud.show");
    assert.equal(host.arrived.some(of("ta", "exit")), false);
    host.send({ type: "rpcResult", session: "ta", id: hud.id, result: null });
    assert.equal((await host.next(of("ta", "exit"))).reason, "finished");
    const logs = host.arrived.filter(of("ta", "log")).map((m) => m.message);
    assert.deepEqual(logs, ["start", "after the timer", "done"]);
    const order = host.arrived.filter((m) => m.session === "ta" && m.type !== "log").map((m) => m.type);
    assert.deepEqual(order, ["rpc", "rpc", "exit"]);
    await host.close();
});

test("an old no-view module that throws while loading is reported, and crashed", async () => {
    const host = start();
    host.send({ type: "launch", session: "tt", entry: fixture("top-level-throws.cjs"), mode: "no-view" });
    const error = await host.next(of("tt", "error"));
    assert.equal(error.message, "top-level went wrong");
    assert.equal(error.fatal, true);
    assert.equal((await host.next(of("tt", "exit"))).reason, "crashed");
    await host.close();
});

test("an old no-view module's later rejection is reported, then it finishes", async () => {
    const host = start();
    host.send({ type: "launch", session: "tr", entry: fixture("top-level-rejects.cjs"), mode: "no-view" });
    const error = await host.next(of("tr", "error"));
    assert.equal(error.message, "later went wrong");
    assert.equal(error.fatal, false, "as an unhandled rejection is reported for any command");
    assert.equal((await host.next(of("tr", "exit"))).reason, "finished");
    await host.close();
});

test("view, menu-bar and default-export no-view workers keep running while idle", async () => {
    const host = start();
    host.send({ type: "launch", session: "v", entry: fixture("counter.cjs"), mode: "view" });
    host.send({ type: "launch", session: "m", entry: fixture("menu-bar.cjs"), mode: "menu-bar" });
    const view = await host.next(of("v", "render"));
    await host.next(of("m", "render"));
    // A no-view command with a default export keeps running while its function hasn't returned, as before.
    host.send({ type: "launch", session: "nv", entry: fixture("default-waits.cjs"), mode: "no-view" });
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(host.arrived.some((m) => m.type === "exit"), false, "none of the three ended while idle");

    // The idle view still answers an event.
    const action = ((view.view as UINode).children[0]!.props.actions as unknown as UINode).children[0]!;
    host.send({ type: "event", session: "v", node: action.id, path: ["onAction"], args: [] });
    assert.equal(((await host.next(of("v", "render"))).view as UINode).children[0]!.props.title, "count 1");
    for (const session of ["v", "m", "nv"]) host.send({ type: "unload", session });
    for (const session of ["v", "m", "nv"]) assert.equal((await host.next(of(session, "exit"))).reason, "unloaded");
    await host.close();
});

test("a view or menu-bar module with no export still has nothing to run", async () => {
    const host = start();
    for (const mode of ["view", "menu-bar"]) {
        host.send({ type: "launch", session: mode, entry: fixture("top-level-sync.cjs"), mode });
        assert.match(String((await host.next(of(mode, "error"))).message), /has no default export to run/);
        assert.equal((await host.next(of(mode, "exit"))).reason, "crashed");
    }
    await host.close();
});

test("two sessions run side by side", async () => {
    const host = start();
    host.send({ type: "launch", session: "a", entry: fixture("counter.cjs"), mode: "view" });
    host.send({ type: "launch", session: "b", entry: fixture("counter.cjs"), mode: "view", launchProps: { arguments: { name: "B" } } });
    const [a, b] = await Promise.all([host.next(of("a", "render")), host.next(of("b", "render"))]);
    assert.equal((a.view as UINode).props.navigationTitle, "counter");
    assert.equal((b.view as UINode).props.navigationTitle, "B");

    host.send({ type: "launch", session: "a", entry: fixture("counter.cjs"), mode: "view" });
    assert.match(String((await host.next((m) => m.type === "protocolError")).message), /already running/);
    await host.close();
});

// SPEC-124: a command's log lines.

/** Launches `logging.cjs` and returns a function that clicks one of its items and waits for the event to settle. */
async function launchLogging(host: Host, session: string) {
    host.send({
        type: "launch",
        session,
        entry: fixture("logging.cjs"),
        mode: "menu-bar",
        environment: { extensionName: "amazon-aws", commandName: "console" },
    });
    const view = (await host.next(of(session, "render"))).view as UINode;
    const items = new Map(view.children.map((item) => [String(item.props.title), item.id]));
    return async (title: string) => {
        host.send({ type: "event", session, node: items.get(title), path: ["onAction"], args: [] });
        await host.next(of(session, "eventSettled"));
    };
}

const logsOf = (host: Host, session: string) => host.arrived.filter(of(session, "log"));

test("a command's console lines carry its extension and command, at the Log level the app sets, also while it runs", async () => {
    const host = start();
    host.send({ type: "logLevel", level: "error" });
    const click = await launchLogging(host, "lv");
    const levels: [string, string[]][] = [
        ["error", ["error: an error line"]],
        ["warning", ["error: an error line", "warning: a warning line"]],
        ["info", ["error: an error line", "warning: a warning line", "info: a log line", "info: an info line"]],
        ["debug", ["error: an error line", "warning: a warning line", "info: a log line", "info: an info line", "debug: a debug line"]],
    ];
    for (const [level, expected] of levels) {
        // The running command gets the change: no relaunch.
        host.send({ type: "logLevel", level });
        const before = logsOf(host, "lv").length;
        await click("Levels");
        const lines = logsOf(host, "lv").slice(before);
        assert.deepEqual(lines.map((m) => `${m.level}: ${m.message}`), expected, `at ${level}`);
        for (const line of lines) assert.deepEqual([line.extension, line.command], ["amazon-aws", "console"]);
    }
    await host.close();
});

test("a thrown error, an unhandled rejection and failure toasts are errors in the log at the default level", async () => {
    const host = start();
    host.send({ type: "logLevel", level: "error" });
    const click = await launchLogging(host, "er");
    const logged = (pattern: RegExp) => host.next((m) => of("er", "log")(m) && pattern.test(String(m.message)));

    await click("Throw");
    const thrown = await logged(/thrown later/);
    assert.equal(thrown.level, "error");
    assert.match(String(thrown.message), /^Error: thrown later\n {4}at /, "with its stack");
    await click("Reject");
    assert.match(String((await logged(/rejected later/)).message), /^Error: rejected later\n {4}at /);

    // amazon-aws's Console (#5151) failed through showFailureToast, which is a failure toast like this one.
    await click("Failure Toast");
    const toast = await logged(/^Failure toast/);
    assert.equal(toast.message, "Failure toast: Failed to fetch latest data\nENOENT: no such file");
    assert.deepEqual([toast.level, toast.extension, toast.command], ["error", "amazon-aws", "console"]);
    // An animated toast that becomes a failure is logged once, with the title and message it got with its new style.
    await click("Animated Then Failure");
    assert.equal((await logged(/^Failure toast/)).message, "Failure toast: Couldn't load\nbecause");
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(logsOf(host, "er").filter((m) => /Couldn't load/.test(String(m.message))).length, 1);
    await host.close();
});

test("a command printing in a loop is cut at 1,000 lines a second and the count follows; another's lines arrive in order", async () => {
    const host = start();
    host.send({ type: "logLevel", level: "error" });
    const flood = await launchLogging(host, "fl");
    const steady = await launchLogging(host, "st");
    await Promise.all([flood("Flood"), steady("Steady")]);
    const dropped = await host.next((m) => of("fl", "log")(m) && /dropped/.test(String(m.message)), 3000);
    // As severe as the lines it stands for, so the level that recorded them records it.
    assert.deepEqual([dropped.level, dropped.message], ["error", "… 2000 lines dropped"]);
    const flooded = logsOf(host, "fl").filter((m) => /^flood /.test(String(m.message)));
    assert.deepEqual(
        flooded.map((m) => m.message),
        Array.from({ length: 1000 }, (_, i) => `flood ${i + 1}`),
        "the first thousand, in order",
    );
    assert.ok(host.arrived.indexOf(flooded.at(-1)!) < host.arrived.indexOf(dropped), "the count comes after them");
    assert.deepEqual(
        logsOf(host, "st").map((m) => m.message),
        Array.from({ length: 50 }, (_, i) => `steady ${i + 1}`),
    );
    await host.close();
});
