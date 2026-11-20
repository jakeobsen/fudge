// Messages between the fudge app, the extension host and its workers.
//
// The app and the host write one JSON object per line: the app on the
// host's stdin, the host on its stdout. Every message has a `type`.
// Messages about a running command carry the `session` id the app chose
// when it launched it; the host strips it on the way to that command's
// worker and adds it on the way back.

import type { LaunchEnvironment } from "./api/launch.ts";
import type { RpcRequest } from "./bridge.ts";
import type { UINode } from "./renderer/serialize.ts";

export type CommandMode = "view" | "no-view" | "menu-bar";

export type LaunchProps = {
    arguments?: Record<string, string>;
    launchContext?: Record<string, unknown>;
    fallbackText?: string;
    launchType?: "userInitiated" | "background";
};

/** App → host. */
export type AppMessage =
    | { type: "ping"; id: number }
    | {
          type: "launch";
          session: string;
          /** The compiled command: a CommonJS file whose default export is the command. */
          entry: string;
          mode: CommandMode;
          launchProps?: LaunchProps;
          /** Resolved preference values for the command. */
          preferences?: Record<string, unknown>;
          /** Facts for `environment` and where LocalStorage and Cache live. */
          environment?: Partial<LaunchEnvironment>;
      }
    | { type: "event"; session: string; node: number; path: string[]; args: unknown[] }
    | { type: "pop"; session: string }
    | { type: "unload"; session: string }
    | { type: "rpcResult"; session: string; id: number; result?: unknown; error?: string }
    | { type: "toastAction"; session: string; toast: number; action: "primary" | "secondary" };

/** Worker → host; the host forwards these to the app with the session added. */
export type WorkerMessage =
    | { type: "render"; view: UINode | null; depth: number }
    | RpcRequest
    | { type: "error"; message: string; stack?: string; fatal: boolean }
    | { type: "log"; level: "info" | "error"; message: string }
    /** Answers every `event`, once its handler has returned, or settled when it returned a promise. */
    | { type: "eventSettled" }
    | { type: "exit"; reason: "finished" | "unloaded" | "crashed" };

/** Host → worker. */
export type HostToWorker =
    | { type: "event"; node: number; path: string[]; args: unknown[] }
    | { type: "pop" }
    | { type: "unload" }
    | { type: "rpcResult"; id: number; result?: unknown; error?: string }
    | { type: "toastAction"; toast: number; action: "primary" | "secondary" };

/** Host → app. */
export type HostMessage =
    | { type: "pong"; id: number }
    | { type: "protocolError"; message: string; id?: number }
    | (WorkerMessage & { session: string });

export type Parsed = { ok: true; message: AppMessage } | { ok: false; error: HostMessage };

/** Parses and checks one line from the app. */
export function parseAppMessage(line: string): Parsed {
    let value: unknown;
    try {
        value = JSON.parse(line);
    } catch {
        return protocolError("not valid JSON");
    }
    if (!isObject(value) || typeof value.type !== "string") {
        return protocolError("a message must be an object with a string `type`");
    }
    const id = typeof value.id === "number" ? value.id : undefined;
    const session = typeof value.session === "string" && value.session !== "" ? value.session : undefined;
    const needsSession = (): Parsed | undefined =>
        session === undefined ? protocolError(`\`${value.type}\` needs a non-empty string \`session\``, id) : undefined;

    switch (value.type) {
        case "ping":
            if (id === undefined) return protocolError("`ping` needs a numeric `id`");
            return { ok: true, message: { type: "ping", id } };
        case "launch": {
            const problem = needsSession();
            if (problem) return problem;
            if (typeof value.entry !== "string" || value.entry === "") return protocolError("`launch` needs an `entry`");
            if (value.mode !== "view" && value.mode !== "no-view" && value.mode !== "menu-bar") {
                return protocolError("`launch` needs a `mode` of `view`, `no-view` or `menu-bar`");
            }
            const launchProps = isObject(value.launchProps) ? (value.launchProps as LaunchProps) : undefined;
            const preferences = isObject(value.preferences) ? value.preferences : undefined;
            const environment = isObject(value.environment) ? (value.environment as Partial<LaunchEnvironment>) : undefined;
            return {
                ok: true,
                message: { type: "launch", session: session!, entry: value.entry, mode: value.mode, launchProps, preferences, environment },
            };
        }
        case "event": {
            const problem = needsSession();
            if (problem) return problem;
            if (typeof value.node !== "number") return protocolError("`event` needs a numeric `node`");
            if (!Array.isArray(value.path) || !value.path.every((key) => typeof key === "string")) {
                return protocolError("`event` needs a `path` of strings");
            }
            const args = Array.isArray(value.args) ? value.args : [];
            return { ok: true, message: { type: "event", session: session!, node: value.node, path: value.path, args } };
        }
        case "pop":
        case "unload": {
            const problem = needsSession();
            if (problem) return problem;
            return { ok: true, message: { type: value.type, session: session! } };
        }
        case "rpcResult": {
            const problem = needsSession();
            if (problem) return problem;
            if (id === undefined) return protocolError("`rpcResult` needs a numeric `id`");
            const error = typeof value.error === "string" ? value.error : undefined;
            return { ok: true, message: { type: "rpcResult", session: session!, id, result: value.result, error } };
        }
        case "toastAction": {
            const problem = needsSession();
            if (problem) return problem;
            if (typeof value.toast !== "number") return protocolError("`toastAction` needs a numeric `toast`");
            if (value.action !== "primary" && value.action !== "secondary") {
                return protocolError("`toastAction` needs an `action` of `primary` or `secondary`");
            }
            return { ok: true, message: { type: "toastAction", session: session!, toast: value.toast, action: value.action } };
        }
        default:
            return protocolError(`unknown message type \`${value.type}\``, id);
    }
}

/** Turns `{ "$date": iso }` and `{ "$buffer": base64 }` markers from the app back into Dates and Buffers. */
export function revive(value: unknown): unknown {
    if (Array.isArray(value)) return value.map(revive);
    if (!isObject(value)) return value;
    const keys = Object.keys(value);
    if (keys.length === 1 && keys[0] === "$date" && typeof value.$date === "string") return new Date(value.$date);
    if (keys.length === 1 && keys[0] === "$buffer" && typeof value.$buffer === "string") {
        return Buffer.from(value.$buffer, "base64");
    }
    return Object.fromEntries(keys.map((key) => [key, revive(value[key])]));
}

/**
 * The reverse of `revive`, for data sent to the app as JSON: Dates become `{ "$date": iso }` and Buffers (any
 * Uint8Array) `{ "$buffer": base64 }`, at any depth. Everything else follows `JSON.stringify`: `toJSON` is used,
 * functions and `undefined` are left out of objects (null in arrays), and non-finite numbers become null. Throws a
 * TypeError for a BigInt or a cycle.
 */
export function encode(value: unknown, ancestors: Set<object> = new Set()): unknown {
    if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : { $date: value.toISOString() };
    if (value instanceof Uint8Array) {
        return { $buffer: Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString("base64") };
    }
    switch (typeof value) {
        case "number":
            return Number.isFinite(value) ? value : null;
        case "bigint":
            throw new TypeError("a BigInt can't be sent");
        case "function":
        case "symbol":
        case "undefined":
            return undefined;
        case "object":
            break;
        default:
            return value;
    }
    if (value === null) return null;
    const object = value as Record<string, unknown> & { toJSON?: () => unknown };
    if (typeof object.toJSON === "function") return encode(object.toJSON(), ancestors);
    if (ancestors.has(object)) throw new TypeError("a value that contains itself can't be sent");
    ancestors.add(object);
    let result: unknown;
    if (Array.isArray(object)) {
        result = object.map((item) => encode(item, ancestors) ?? null);
    } else {
        const entries = Object.keys(object).map((key) => [key, encode(object[key], ancestors)] as const);
        result = Object.fromEntries(entries.filter(([, item]) => item !== undefined));
    }
    ancestors.delete(object);
    return result;
}

function protocolError(message: string, id?: number): Parsed {
    return { ok: false, error: id === undefined ? { type: "protocolError", message } : { type: "protocolError", message, id } };
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
