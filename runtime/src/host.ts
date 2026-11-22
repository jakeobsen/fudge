// The extension host's entry point. The fudge app starts it with Node and
// talks to it over stdin/stdout (see protocol.ts). Each launched command
// runs in its own worker thread (worker.ts), so one extension can't block
// or crash another.

import { extname } from "node:path";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import {
    logs,
    parseAppMessage,
    type AppMessage,
    type HostMessage,
    type HostToWorker,
    type LogLevel,
    type WorkerMessage,
} from "./protocol.ts";
import type { WorkerData } from "./worker.ts";

// stdout carries the protocol and nothing else.
console.log = console.error;
console.info = console.error;
console.debug = console.error;

// worker.ts next to host.ts when run from source, worker.js next to host.js in the bundle.
const workerUrl = new URL(`./worker${extname(fileURLToPath(import.meta.url))}`, import.meta.url);

/** How long a command gets to clean up after `unload` before it's stopped. */
const UNLOAD_GRACE_MS = 1000;

/**
 * How many log lines a command may send in a second (SPEC-124). Past it, its lines are dropped and counted, and one
 * `… N lines dropped` line follows when the second is up, so a command printing in a loop can't flood the app.
 */
const LOG_LINES_PER_SECOND = 1000;

/** A command's log lines in the current second, and the ones dropped. */
type LogBudget = { windowStart: number; sent: number; dropped: number; droppedLevel?: LogLevel; timer?: NodeJS.Timeout };

type Session = {
    worker: Worker;
    done: boolean;
    unloadTimer?: NodeJS.Timeout;
    /** The names its log lines carry: the extension's id from the launch message, the command's from its environment. */
    names: { extension?: string; command?: string };
    log: LogBudget;
};
const sessions = new Map<string, Session>();

/** The Log level, until the app says otherwise: everything, so a host started on its own (tests) drops nothing. */
let logLevel: LogLevel = "debug";

function send(message: HostMessage): void {
    process.stdout.write(`${JSON.stringify(message)}\n`);
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
        logLevel,
    };
    const worker = new Worker(workerUrl, { workerData, stdout: true, stderr: true });
    const named = (name: unknown) => (typeof name === "string" && name !== "" ? name : undefined);
    const names = { extension: named(message.extensionId), command: named(message.environment?.commandName) };
    const session: Session = { worker, done: false, names, log: { windowStart: 0, sent: 0, dropped: 0 } };
    sessions.set(id, session);

    // What a command writes to stdout or stderr itself, outside `console` (which the worker sends as `log`).
    eachLine(worker.stdout, (line) => log(id, session, "info", line));
    eachLine(worker.stderr, (line) => log(id, session, "error", line));

    worker.on("message", (reply: WorkerMessage) => {
        if (session.done) return;
        if (reply.type === "log") return log(id, session, reply.level, reply.message);
        if (reply.type === "exit") sendDropped(id, session);
        send({ ...reply, session: id });
        if (reply.type === "exit") finish(id, session);
    });
    worker.on("error", (error) => {
        if (session.done) return;
        hostLine(id, session, error.stack ?? error.message);
        send({ session: id, type: "error", message: error.message, stack: error.stack, fatal: true });
    });
    worker.on("exit", (code) => {
        if (session.done) return;
        if (code !== 0) hostLine(id, session, `The command crashed (exit code ${code}).`);
        sendDropped(id, session);
        finish(id, session);
        send({ session: id, type: "exit", reason: code === 0 ? "finished" : "crashed" });
    });
}

/** Sends a command's log line, when the Log level records it and the command is within its lines per second. */
function log(id: string, session: Session, level: LogLevel, message: string): void {
    if (session.done || !logs(level, logLevel)) return;
    const budget = session.log;
    const now = Date.now();
    if (now - budget.windowStart >= 1000) {
        sendDropped(id, session);
        budget.windowStart = now;
        budget.sent = 0;
    }
    if (budget.sent < LOG_LINES_PER_SECOND) {
        budget.sent += 1;
        send({ session: id, type: "log", level, message, ...session.names });
        return;
    }
    budget.dropped += 1;
    // The count is as severe as the worst line it stands for, so the Log level that recorded those records it.
    if (budget.droppedLevel === undefined || logs(level, budget.droppedLevel)) budget.droppedLevel = level;
    // The count goes out when the second is up, even if the command has stopped printing by then.
    budget.timer ??= setTimeout(() => {
        budget.timer = undefined;
        sendDropped(id, session);
    }, 1000 - (now - budget.windowStart));
}

/**
 * A line of the host's own about the command (its worker failed, it crashed, it was stopped): always sent, outside the
 * command's lines per second and after the count of those dropped, so a flood just before can't hide it (SPEC-124 §3).
 * Each comes at most once per command. It's an error, which every Log level records.
 */
function hostLine(id: string, session: Session, message: string): void {
    if (session.done) return;
    sendDropped(id, session);
    send({ session: id, type: "log", level: "error", message, ...session.names });
}

/** The `… N lines dropped` line for the lines dropped so far, if any. */
function sendDropped(id: string, session: Session): void {
    const budget = session.log;
    clearTimeout(budget.timer);
    budget.timer = undefined;
    if (budget.dropped === 0) return;
    const message = `… ${budget.dropped} ${budget.dropped === 1 ? "line" : "lines"} dropped`;
    const level = budget.droppedLevel ?? "warning";
    budget.dropped = 0;
    budget.droppedLevel = undefined;
    send({ session: id, type: "log", level, message, ...session.names });
}

function finish(id: string, session: Session): void {
    session.done = true;
    clearTimeout(session.unloadTimer);
    clearTimeout(session.log.timer);
    sessions.delete(id);
    void session.worker.terminate();
}

function unload(id: string, session: Session): void {
    session.worker.postMessage({ type: "unload" } satisfies HostToWorker);
    session.unloadTimer ??= setTimeout(() => {
        if (session.done) return;
        hostLine(id, session, `The command was stopped: it didn't finish within ${UNLOAD_GRACE_MS} ms of being closed.`);
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
    if (message.type === "logLevel") {
        logLevel = message.level;
        for (const session of sessions.values()) {
            session.worker.postMessage({ type: "logLevel", level: message.level } satisfies HostToWorker);
        }
        return;
    }

    const session = sessions.get(message.session);
    if (!session) return send({ type: "protocolError", message: `no running session \`${message.session}\`` });

    switch (message.type) {
        case "event":
            session.worker.postMessage({ type: "event", node: message.node, path: message.path, args: message.args } satisfies HostToWorker);
            return;
        case "slots":
            session.worker.postMessage({ type: "slots", nodes: message.nodes } satisfies HostToWorker);
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
                ...(message.notice === undefined ? {} : { notice: message.notice }),
            } satisfies HostToWorker);
            return;
    }
});

input.on("close", () => {
    for (const [id, session] of sessions) finish(id, session);
});
