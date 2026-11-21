// Calls from extension code into the fudge app (clipboard, toasts, alerts,
// preferences, …). Each call is an `rpc` message with an id; the app answers
// with an `rpcResult` carrying the same id.

export type RpcRequest = { type: "rpc"; id: number; method: string; params: unknown };

type Pending = { resolve(value: unknown): void; reject(error: Error): void };

let transport: ((request: RpcRequest) => void) | null = null;
let nextId = 1;
const pending = new Map<number, Pending>();

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
        send({ type: "rpc", id, method, params: params ?? null });
    });
}

/** Settles the call `id` with the app's answer. Unknown ids are ignored. */
export function settle(id: number, result: unknown, error?: string): void {
    const call = pending.get(id);
    if (!call) return;
    pending.delete(id);
    if (error !== undefined) call.reject(new Error(error));
    else call.resolve(result);
}
