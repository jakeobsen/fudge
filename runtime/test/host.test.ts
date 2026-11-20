import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
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
    private readonly waiting: { match: (m: Message) => boolean; resolve: (m: Message) => void }[] = [];

    constructor() {
        this.process = spawn(process.execPath, [hostPath], { stdio: ["pipe", "pipe", "pipe"] });
        createInterface({ input: this.process.stdout }).on("line", (line) => {
            const message = JSON.parse(line) as Message;
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
const start = () => {
    const host = new Host();
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

test("a no-view command runs to completion and its console output arrives as logs", async () => {
    const host = start();
    host.send({ type: "launch", session: "nv", entry: fixture("no-view.cjs"), mode: "no-view", launchProps: { arguments: { q: "x" } } });
    const log = await host.next(of("nv", "log"));
    assert.deepEqual(log, { session: "nv", type: "log", level: "info", message: 'ran with {"q":"x"}' });
    assert.equal((await host.next(of("nv", "exit"))).reason, "finished");
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
    assert.equal(error.message, "WindowManagement.getActiveWindow isn't available in Fudge yet");
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
