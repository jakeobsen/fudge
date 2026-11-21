// Calls from extension code into the fudge app (clipboard, toasts, alerts,
// preferences, …). Each call is an `rpc` message with an id; the app answers
// with an `rpcResult` carrying the same id.

import { markNotice } from "./notice.ts";

export type RpcRequest = { type: "rpc"; id: number; method: string; params: unknown };

type Pending = { resolve(value: unknown): void; reject(error: Error): void };

let transport: ((request: RpcRequest) => void) | null = null;
let nextId = 1;
const pending = new Map<number, Pending>();

/** What keeps the worker alive, such as its message port: `ref` while a call waits for its answer. */
export type Hold = { ref(): void; unref(): void };
let hold: Hold | null = null;

/**
 * From now on, `target` is held (`ref`) only while a call waits for the app's answer, and let go of (`unref`)
 * otherwise. The worker then ends once its own work is done, as an old no-view command's top-level code expects.
 */
export function holdWhilePending(target: Hold | null): void {
    hold = target;
    if (pending.size > 0) target?.ref();
    else target?.unref();
}

/** Connects the bridge; the worker passes a function that posts to the host. */
export function connect(send: ((request: RpcRequest) => void) | null): void {
    transport = send;
}

export function callApp<T = unknown>(method: string, params?: unknown): Promise<T> {
    if (!transport) return Promise.reject(new Error(`${method}: not connected to the Fudge app`));
    const id = nextId++;
    const send = transport;
    return new Promise<T>((resolve, reject) => {
        pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
        if (pending.size === 1) hold?.ref();
        send({ type: "rpc", id, method, params: params ?? null });
    });
}

/**
 * Settles the call `id` with the app's answer. Unknown ids are ignored. A rejection the app gave a `notice` (it refused
 * on purpose, e.g. while sign-in is off) is marked with it (`markNotice`).
 */
export function settle(id: number, result: unknown, error?: string, notice?: string): void {
    const call = pending.get(id);
    if (!call) return;
    pending.delete(id);
    if (pending.size === 0) hold?.unref();
    if (error !== undefined) call.reject(notice === undefined ? new Error(error) : markNotice(new Error(error), notice));
    else call.resolve(result);
}
