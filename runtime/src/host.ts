// The extension host's entry point. The fudge app starts it with Node and
// talks to it over stdin/stdout (see protocol.ts). Each launched command
// runs in its own worker thread (worker.ts), so one extension can't block
// or crash another.

import { extname } from "node:path";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import { parseAppMessage, type AppMessage, type HostMessage, type HostToWorker, type WorkerMessage } from "./protocol.ts";
import type { WorkerData } from "./worker.ts";
import { now, timing } from "./timing.ts";

// stdout carries the protocol and nothing else.
console.log = console.error;
console.info = console.error;
console.debug = console.error;

// worker.ts next to host.ts when run from source, worker.js next to host.js in the bundle.
const workerUrl = new URL(`./worker${extname(fileURLToPath(import.meta.url))}`, import.meta.url);

/** How long a command gets to clean up after `unload` before it's stopped. */
const UNLOAD_GRACE_MS = 1000;

type Session = { worker: Worker; done: boolean; unloadTimer?: NodeJS.Timeout };
const sessions = new Map<string, Session>();

function send(message: HostMessage): void {
    const t0 = now();
    const line = JSON.stringify(message);
    const t1 = now();
    process.stdout.write(`${line}\n`);
    if (message.type === "render") {
        timing("host.render", `stringify=${(t1 - t0).toFixed(1)} write=${(now() - t1).toFixed(1)} bytes=${line.length}`);
    }
}

function launch(message: Extract<AppMessage, { type: "launch" }>): void {
    const id = message.session;
    if (sessions.has(id)) {
        send({ type: "protocolError", message: `session \`${id}\` is already running` });
        return;
    }
    const workerData: WorkerData = {
        entry: message.entry,
        mode: message.mode,
        launchProps: message.launchProps ?? {},
        preferences: message.preferences ?? {},
        environment: message.environment ?? {},
    };
    const worker = new Worker(workerUrl, { workerData, stdout: true, stderr: true });
    const session: Session = { worker, done: false };
    sessions.set(id, session);

    eachLine(worker.stdout, (line) => send({ session: id, type: "log", level: "info", message: line }));
    eachLine(worker.stderr, (line) => send({ session: id, type: "log", level: "error", message: line }));

    worker.on("message", (reply: WorkerMessage) => {
        if (reply.type === "render") timing("host.received");
        if (session.done) return;
        send({ ...reply, session: id });
        if (reply.type === "exit") finish(id, session);
    });
    worker.on("error", (error) => {
        if (session.done) return;
        send({ session: id, type: "error", message: error.message, stack: error.stack, fatal: true });
    });
    worker.on("exit", (code) => {
        if (session.done) return;
        finish(id, session);
        send({ session: id, type: "exit", reason: code === 0 ? "finished" : "crashed" });
    });
}

function finish(id: string, session: Session): void {
    session.done = true;
    clearTimeout(session.unloadTimer);
    sessions.delete(id);
    void session.worker.terminate();
}

function unload(id: string, session: Session): void {
    session.worker.postMessage({ type: "unload" } satisfies HostToWorker);
    session.unloadTimer ??= setTimeout(() => {
        if (session.done) return;
        finish(id, session);
        send({ session: id, type: "exit", reason: "unloaded" });
    }, UNLOAD_GRACE_MS);
}

function eachLine(stream: Readable, handle: (line: string) => void): void {
    createInterface({ input: stream, crlfDelay: Infinity }).on("line", handle);
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });

input.on("line", (line) => {
    if (line.trim() === "") return;
    const parsed = parseAppMessage(line);
    if (!parsed.ok) return send(parsed.error);

    const message = parsed.message;
    if (message.type === "ping") return send({ type: "pong", id: message.id });
    if (message.type === "launch") return launch(message);

    const session = sessions.get(message.session);
    if (!session) return send({ type: "protocolError", message: `no running session \`${message.session}\`` });

    switch (message.type) {
        case "event":
            session.worker.postMessage({ type: "event", node: message.node, path: message.path, args: message.args } satisfies HostToWorker);
            return;
        case "pop":
            session.worker.postMessage({ type: "pop" } satisfies HostToWorker);
            return;
        case "unload":
            return unload(message.session, session);
        case "toastAction":
            session.worker.postMessage({ type: "toastAction", toast: message.toast, action: message.action } satisfies HostToWorker);
            return;
        case "rpcResult":
            session.worker.postMessage({
                type: "rpcResult",
                id: message.id,
                result: message.result,
                error: message.error,
            } satisfies HostToWorker);
            return;
    }
});

input.on("close", () => {
    for (const [id, session] of sessions) finish(id, session);
});
