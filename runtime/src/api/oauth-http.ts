// Sign-in requests below `fetch` (SPEC-075). Extensions bundle their own HTTP clients: `@raycast/utils` 1.x posts its
// token requests through `cross-fetch`, whose `node-fetch` calls `https.request`, as axios and got do. So the worker
// applies `decide`'s rules (oauth-fetch.ts) to `http` and `https` too, and refuses any connection to Raycast's proxy
// hosts at `net.Socket.prototype.connect`, which every client in the worker reaches: https, http2, undici's `fetch`
// and WebSocket.
//
// A request that needs a decision (Raycast's proxy hosts and the table's token and refresh URLs) keeps its real
// `ClientRequest`, so every client sees the request and response it expects. Its socket is a gate (`createConnection`)
// that holds the bytes until the request is complete, decides, and then sends them to the relay with the request line
// and `Host` rewritten, sends them on unchanged, or fails the request. A redirect from the relay fails it too: a 307 or
// 308 would send the body (the code and verifier, or the refresh token) on. Every other request is untouched.

import type * as Http from "node:http";
import net from "node:net";
import { Duplex } from "node:stream";
import tls from "node:tls";
import {
    decide,
    isRaycastHost,
    needsDecision,
    redirectedMessage,
    redirectStatuses,
    refusedMessage,
    type Decision,
    type OAuthProvider,
    type ServerAnswer,
} from "./oauth-fetch.ts";

type Server = (provider: string) => Promise<ServerAnswer>;
type RequestFunction = typeof Http.request;
type HttpModule = { request: RequestFunction; get: typeof Http.get };

/** The URL a call to `http.request` or `https.request` asks for, read as Node reads its arguments; null for a unix
 * socket or anything that doesn't make a URL, which is left alone. */
export function requestURL(args: unknown[], protocol: "http:" | "https:"): { url: URL; method: string } | null {
    let options: Record<string, unknown> = {};
    const [first, second] = args;
    if (typeof first === "string" || first instanceof URL) {
        let parsed: URL;
        try {
            parsed = new URL(String(first));
        } catch {
            return null;
        }
        options = {
            protocol: parsed.protocol,
            hostname: parsed.hostname.startsWith("[") ? parsed.hostname.slice(1, -1) : parsed.hostname,
            port: parsed.port,
            path: `${parsed.pathname}${parsed.search}`,
        };
        if (second && typeof second === "object") options = { ...options, ...(second as Record<string, unknown>) };
    } else if (first && typeof first === "object") {
        options = first as Record<string, unknown>;
    } else {
        return null;
    }
    if (options.socketPath !== undefined) return null;
    const scheme = typeof options.protocol === "string" ? options.protocol : protocol;
    const host = String(options.hostname || options.host || "localhost");
    const port = options.port ? `:${String(options.port)}` : "";
    const path = typeof options.path === "string" ? options.path : "/";
    try {
        const url = new URL(`${scheme}//${host.includes(":") ? `[${host}]` : host}${port}${path}`);
        return { url, method: String(options.method || "GET").toUpperCase() };
    } catch {
        return null;
    }
}

/** The arguments again, with the gate as the socket: no agent, so `createConnection` is used. */
function throughGate(args: unknown[], gate: () => Duplex): unknown[] {
    const extra = { agent: undefined, createConnection: gate };
    const [first, second, ...rest] = args;
    if (typeof first === "string" || first instanceof URL) {
        if (second && typeof second === "object") return [first, { ...second, ...extra }, ...rest];
        return [first, extra, ...args.slice(1)];
    }
    return [{ ...(first as object), ...extra }, ...args.slice(1)];
}

/** A chunked body's bytes, for reading its `grant_type`. */
function dechunk(raw: Buffer): Buffer {
    const parts: Buffer[] = [];
    let at = 0;
    while (at < raw.length) {
        const end = raw.indexOf("\r\n", at);
        if (end < 0) break;
        const size = Number.parseInt(raw.subarray(at, end).toString("latin1").split(";")[0], 16);
        if (!Number.isFinite(size) || size <= 0) break;
        parts.push(raw.subarray(end + 2, end + 2 + size));
        at = end + 2 + size + 2;
    }
    return Buffer.concat(parts);
}

/**
 * The socket of a request that needs a decision. It holds what the `ClientRequest` writes until the request has
 * finished, then decides, and connects to the relay or the original host itself; the response comes back through it
 * unchanged, unless the relay answers with a redirect.
 */
class Gate extends Duplex {
    private held: Buffer[] = [];
    private upstream: net.Socket | null = null;
    private relayed = false;
    private statusRead = false;
    private early: Buffer[] = [];
    private timeoutMs = 0;
    private timer: NodeJS.Timeout | null = null;
    private ended = false;
    private readonly url: URL;
    private readonly method: string;
    private readonly providers: OAuthProvider[];
    private readonly server: Server;

    constructor(url: URL, method: string, providers: OAuthProvider[], server: Server) {
        super();
        this.url = url;
        this.method = method;
        this.providers = providers;
        this.server = server;
    }

    private finishResponse(): void {
        if (this.ended || this.destroyed) return;
        this.ended = true;
        this.push(null);
    }

    /** The `ClientRequest` has written everything: decide, then send it. */
    requestFinished(): void {
        const all = Buffer.concat(this.held);
        this.held = [];
        const headEnd = all.indexOf("\r\n\r\n");
        if (headEnd < 0) return void this.destroy(new Error("The request couldn't be read."));
        const head = all.subarray(0, headEnd).toString("latin1").split("\r\n");
        const raw = all.subarray(headEnd + 4);
        const chunked = head.some((line) => /^transfer-encoding:.*chunked/i.test(line));
        const body = (chunked ? dechunk(raw) : raw).toString("utf8");
        decide(this.method, this.url, body, this.providers, this.server).then(
            (decision) => this.send(decision, head, raw),
            (error) => this.destroy(error instanceof Error ? error : new Error(String(error))),
        );
    }

    private send(decision: Decision, head: string[], raw: Buffer): void {
        if (this.destroyed) return;
        if (decision.kind === "refused") return void this.destroy(new Error(decision.message));
        this.relayed = decision.kind === "relay";
        const to = decision.kind === "relay" ? new URL(decision.target) : this.url;
        const [, ...headers] = head;
        const lines = [
            `${this.method} ${to.pathname}${to.search} HTTP/1.1`,
            ...headers.filter((line) => !/^host:/i.test(line)),
            `Host: ${to.host}`,
        ];
        const port = Number(to.port) || (to.protocol === "https:" ? 443 : 80);
        const host = to.hostname.startsWith("[") ? to.hostname.slice(1, -1) : to.hostname;
        const socket =
            to.protocol === "https:"
                ? tls.connect({ host, port, servername: net.isIP(host) ? undefined : host })
                : net.connect({ host, port });
        this.upstream = socket;
        socket.on("data", (chunk: Buffer) => this.received(chunk));
        socket.on("end", () => this.finishResponse());
        socket.on("error", (error) => this.destroy(error));
        socket.on("close", () => this.finishResponse());
        socket.write(Buffer.concat([Buffer.from(`${lines.join("\r\n")}\r\n\r\n`, "latin1"), raw]));
        if (this.timeoutMs) socket.setTimeout(this.timeoutMs, () => this.emit("timeout"));
    }

    /** The response: for the relay, its status is checked first, and a redirect fails the request. */
    private received(chunk: Buffer): void {
        this.touch();
        if (!this.relayed || this.statusRead) {
            if (!this.push(chunk)) this.upstream?.pause();
            return;
        }
        this.early.push(chunk);
        const seen = Buffer.concat(this.early);
        const lineEnd = seen.indexOf("\r\n");
        if (lineEnd < 0 && seen.length < 1024) return;
        this.statusRead = true;
        this.early = [];
        const status = Number(/^HTTP\/\d(?:\.\d)? (\d{3})/.exec(seen.subarray(0, lineEnd).toString("latin1"))?.[1]);
        if (redirectStatuses.has(status)) return void this.destroy(new Error(redirectedMessage));
        if (!this.push(seen)) this.upstream?.pause();
    }

    override _write(chunk: Buffer, _encoding: BufferEncoding, callback: (error?: Error | null) => void): void {
        this.touch();
        if (this.upstream) this.upstream.write(chunk, callback);
        else {
            this.held.push(Buffer.from(chunk));
            callback();
        }
    }

    override _read(): void {
        this.upstream?.resume();
    }

    override _final(callback: (error?: Error | null) => void): void {
        if (this.upstream) this.upstream.end(callback);
        else callback();
    }

    override _destroy(error: Error | null, callback: (error?: Error | null) => void): void {
        if (this.timer) clearTimeout(this.timer);
        this.upstream?.destroy();
        callback(error);
    }

    // What a `ClientRequest` asks of its socket.
    setTimeout(ms: number, callback?: () => void): this {
        if (callback) this.once("timeout", callback);
        this.timeoutMs = ms;
        this.upstream?.setTimeout(ms);
        this.touch();
        return this;
    }

    private touch(): void {
        if (this.timer) clearTimeout(this.timer);
        this.timer = null;
        if (this.timeoutMs > 0 && !this.upstream) this.timer = setTimeout(() => this.emit("timeout"), this.timeoutMs);
    }

    setNoDelay(): this {
        return this;
    }

    setKeepAlive(): this {
        return this;
    }

    ref(): this {
        return this;
    }

    unref(): this {
        return this;
    }
}

/** `request` and `get` for one module, with `decide`'s rules for the requests that need a decision. */
function guardModule(module: HttpModule, protocol: "http:" | "https:", providers: OAuthProvider[], server: Server) {
    const original = module.request;
    const request = function (this: unknown, ...args: unknown[]) {
        const asked = requestURL(args, protocol);
        if (asked === null || !needsDecision(asked.url, providers)) {
            return Reflect.apply(original, this, args) as Http.ClientRequest;
        }
        const gate = new Gate(asked.url, asked.method, providers, server);
        const sent = Reflect.apply(original, this, throughGate(args, () => gate)) as Http.ClientRequest;
        sent.once("finish", () => gate.requestFinished());
        return sent;
    } as RequestFunction;
    const get = function (this: unknown, ...args: unknown[]) {
        const sent = Reflect.apply(request, this, args) as Http.ClientRequest;
        sent.end();
        return sent;
    } as typeof Http.get;
    const before = { request: module.request, get: module.get };
    module.request = request;
    module.get = get;
    return () => Object.assign(module, before);
}

/** Applies `decide`'s rules to `http` and `https`. Returns a function that puts them back (for tests). */
export function guardRequests(
    modules: { http: HttpModule; https: HttpModule },
    providers: OAuthProvider[],
    server: Server,
): () => void {
    const undo = [
        guardModule(modules.http, "http:", providers, server),
        guardModule(modules.https, "https:", providers, server),
    ];
    return () => undo.forEach((restore) => restore());
}

/** The host a `Socket.prototype.connect` call names: `(options[, cb])`, Node's normalized `[options, cb]`, or
 * `(port[, host][, cb])`. A unix socket path names none. */
function connectHosts(args: unknown[]): string[] {
    let options = args[0];
    if (Array.isArray(options)) options = options[0];
    if (options && typeof options === "object") {
        const { host, servername, path } = options as { host?: unknown; servername?: unknown; path?: unknown };
        if (path !== undefined && host === undefined) return [];
        return [host ?? "localhost", servername].filter((name): name is string => typeof name === "string");
    }
    if (typeof options === "number" || (typeof options === "string" && /^\d+$/.test(options))) {
        return [typeof args[1] === "string" ? args[1] : "localhost"];
    }
    return [];
}

/**
 * The backstop: no connection to Raycast's proxy hosts, whatever the client, checked on the host and a TLS
 * connection's `servername`, before any DNS lookup. The socket fails with `fetch`'s refusal instead. A raw IP address
 * or a native addon isn't caught. Returns a function that puts it back (for tests).
 */
export function guardConnections(): () => void {
    const connect = net.Socket.prototype.connect;
    net.Socket.prototype.connect = function (this: net.Socket, ...args: unknown[]) {
        const refused = connectHosts(args).find((host) => isRaycastHost(host));
        if (refused !== undefined) {
            const error = new Error(refusedMessage(refused.toLowerCase().replace(/\.+$/, ""), false));
            process.nextTick(() => this.destroy(error));
            return this;
        }
        return Reflect.apply(connect, this, args) as net.Socket;
    } as typeof connect;
    return () => {
        net.Socket.prototype.connect = connect;
    };
}
