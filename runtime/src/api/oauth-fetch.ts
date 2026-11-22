// The worker's `fetch`, for sign-in through the relay (SPEC-056 §2). `OAuthService` fetches its token and refresh
// URLs itself, so exactly the built-in providers' default token and refresh URLs go to `<server>/<provider>/token`
// or `/refresh-token` instead. Nothing else is changed. With sign-in off, a request to one of Raycast's proxy hosts
// is refused here, never sent.
//
// The provider table is core's (`OAuthProviders`), handed over by the app in `FUDGE_OAUTH_PROVIDERS` and read, with
// Raycast's hosts, in `oauth-table.ts`.

import http from "node:http";
import https from "node:https";
import { Readable } from "node:stream";
import tls from "node:tls";
import zlib from "node:zlib";
import { markNotice } from "../notice.ts";
import { signInOffMessage, signInOffNotice } from "./oauth.ts";
import { isRaycastDomainHost, isRaycastHost, type OAuthProvider } from "./oauth-table.ts";

export {
    isRaycastDomainHost,
    isRaycastHost,
    providersFromEnvironment,
    providersVariable,
    raycastDomainsFromEnvironment,
    raycastDomainsVariable,
    type OAuthProvider,
} from "./oauth-table.ts";

function parse(url: string): URL | null {
    try {
        return new URL(url);
    } catch {
        return null;
    }
}

/** Scheme, host and path: what a request URL is matched by. */
function key(url: URL): string {
    return `${url.protocol}//${url.host}${url.pathname}`;
}

/** The provider whose token or refresh URL this is, by scheme, host and path. */
function providerFor(url: URL, providers: OAuthProvider[]): OAuthProvider | null {
    const wanted = key(url);
    return (
        providers.find((provider) =>
            [provider.tokenURL, provider.refreshURL].some((candidate) => {
                const parsed = parse(candidate);
                return parsed !== null && key(parsed) === wanted;
            }),
        ) ?? null
    );
}

/** Where a request goes: to the relay as a provider's token or refresh request, refused, or untouched. */
export type Route =
    | { kind: "relay"; provider: OAuthProvider; endpoint: "token" | "refresh-token"; ownHost: boolean }
    | { kind: "refused" }
    | { kind: "untouched" };

const grants = new Set(["authorization_code", "refresh_token"]);

/**
 * Routes a request. Only a `POST` to a table token or refresh URL (by scheme, host and path) with `grant_type`
 * `authorization_code` or `refresh_token` can go to the relay; a URL that's both (Google, Jira, Zoom) goes to
 * `/refresh-token` for a refresh. Anything else on Raycast's proxy hosts is refused, and so is a token or refresh
 * grant to any of Raycast's hosts (`isRaycastDomainHost`, SPEC-132 §2 step 5); everything else is untouched.
 */
export function route(
    method: string,
    url: string,
    grant: string | null,
    providers: OAuthProvider[],
    domains?: readonly string[],
): Route {
    const parsed = parse(url);
    if (parsed === null) return { kind: "untouched" };
    const provider = providerFor(parsed, providers);
    const raycast = isRaycastHost(parsed.hostname);
    if (provider && method.toUpperCase() === "POST" && grant !== null && grants.has(grant)) {
        const token = parse(provider.tokenURL);
        const refresh = parse(provider.refreshURL);
        const shared = token !== null && refresh !== null && key(token) === key(refresh);
        const endpoint = shared
            ? grant === "refresh_token"
                ? "refresh-token"
                : "token"
            : token !== null && key(token) === key(parsed)
              ? "token"
              : "refresh-token";
        // A table match on any of Raycast's hosts (FUD-166's Todoist proxy, `*.oauth-proxy.raycast.com`, included) is
        // Raycast's address, never the provider's own host. The narrow check stays, since `domains` is empty when
        // `FUDGE_RAYCAST_DOMAINS` isn't set.
        const ownHost = !(raycast || isRaycastDomainHost(parsed.hostname, domains));
        return { kind: "relay", provider, endpoint, ownHost };
    }
    if (raycast) return { kind: "refused" };
    if (grant !== null && grants.has(grant) && isRaycastDomainHost(parsed.hostname, domains)) return { kind: "refused" };
    return { kind: "untouched" };
}

/** A request body's `grant_type`: from URL-encoded parameters, a JSON object or a URL-encoded string. */
export function grantType(body: unknown): string | null {
    if (body instanceof URLSearchParams) return body.get("grant_type");
    if (typeof body !== "string") return null;
    try {
        const parsed: unknown = JSON.parse(body);
        if (parsed && typeof parsed === "object") {
            const value = (parsed as Record<string, unknown>).grant_type;
            return typeof value === "string" ? value : null;
        }
    } catch {
        // Not JSON: read it as URL-encoded below.
    }
    return new URLSearchParams(body).get("grant_type");
}

/** What the app says about a provider: the relay in use (null while sign-in is off), and whether this extension has
 * a relay sign-in for it, pending or stored. */
export type ServerAnswer = { server: string | null; signedIn: boolean };

type Fetch = typeof fetch;

/** Refused: a request to Raycast's sign-in proxies. */
export function refusedMessage(host: string, off: boolean): string {
    return off ? signInOffMessage : `Fudge doesn't send requests to ${host}.`;
}

/** The redirect statuses `fetch` and `node-fetch` follow. */
export const redirectStatuses = new Set([301, 302, 303, 307, 308]);

/** Refused: the relay answered a token or refresh request with a redirect, which would send its body on. */
export const redirectedMessage = "The sign-in server redirected the token request, and Fudge doesn't follow that.";

/** Where a request goes, all things considered: untouched, refused (with what to say), or to the relay at `target`. */
/** A refusal while sign-in is off carries its `notice` (SPEC-095), so the command shows a notice, not a failure. */
export type Decision =
    | { kind: "untouched" }
    | { kind: "refused"; message: string; notice?: string }
    | { kind: "relay"; target: string };

/** The error a refused request fails with, marked with the refusal's notice when it has one. */
export function refusalError(decision: Extract<Decision, { kind: "refused" }>): Error {
    const error = new Error(decision.message);
    return decision.notice === undefined ? error : markNotice(error, decision.notice);
}

/** Whether a request to `url` needs a decision, and so its body: Raycast's proxy hosts, the table's token and
 * refresh URLs, and a request with a body to any of Raycast's hosts, which may be a token or refresh grant
 * (SPEC-132 §2 step 5). Everything else, a plain `GET` to raycast.com included, goes where it was going, untouched and
 * unread. */
export function needsDecision(
    url: URL,
    providers: OAuthProvider[],
    method = "GET",
    domains?: readonly string[],
): boolean {
    if (isRaycastHost(url.hostname) || providerFor(url, providers) !== null) return true;
    const bodiless = ["GET", "HEAD"].includes(method.toUpperCase());
    return !bodiless && isRaycastDomainHost(url.hostname, domains);
}

/**
 * The one rule set for every way a request leaves the worker (`fetch`, and `http`/`https` in `oauth-http.ts`), so
 * they can't drift apart. `server` is asked only for a request that may go to the relay, so a server changed while a
 * command runs is honoured. A provider's own token URL (Google, Jira, Zoom) goes to the relay only for an extension
 * with a relay sign-in for it; an extension's own flow there is left alone.
 */
export async function decide(
    method: string,
    url: URL,
    body: unknown,
    providers: OAuthProvider[],
    server: (provider: string) => Promise<ServerAnswer>,
): Promise<Decision> {
    const where = route(method, url.href, grantType(body), providers);
    if (where.kind === "untouched") return where;
    if (where.kind === "refused") return { kind: "refused", message: refusedMessage(url.host, false) };
    const answer = await server(where.provider.id);
    if (answer.server === null || (where.ownHost && !answer.signedIn)) {
        if (where.ownHost) return { kind: "untouched" };
        const off = answer.server === null;
        return { kind: "refused", message: refusedMessage(url.host, off), ...(off ? { notice: signInOffNotice } : {}) };
    }
    const target = `${answer.server.replace(/\/+$/, "")}/${where.provider.id}/${where.endpoint}${url.search}`;
    return { kind: "relay", target };
}

/**
 * The TLS options a connection to the relay takes. It carries the code and verifier, or the refresh token, so it
 * always verifies, whatever the worker's `NODE_TLS_REJECT_UNAUTHORIZED` or `tls.DEFAULT_MIN_VERSION` says
 * (`rejectUnauthorized: true`, TLS 1.2 at least). Of the caller's own options (the request's and its agent's), only
 * what adds trust or proves who the client is goes along (a CA, a revocation list, a client certificate), and a
 * `minVersion` of TLS 1.3. Nothing that weakens verification does (`checkServerIdentity`, ciphers, `secureOptions`,
 * a lower version, …). A request passed through unchanged keeps all its options; it goes where the caller sent it.
 */
const relayTLSKeys = ["ca", "crl", "cert", "key", "pfx", "passphrase"];

export function relayTLSOptions(options: Record<string, unknown> = {}): Record<string, unknown> {
    const agent = options.agent as { options?: Record<string, unknown> } | undefined;
    const picked: Record<string, unknown> = {};
    let minVersion: tls.SecureVersion = "TLSv1.2";
    for (const source of [agent && typeof agent === "object" ? (agent.options ?? {}) : {}, options]) {
        for (const key of relayTLSKeys) if (source[key] !== undefined) picked[key] = source[key];
        if (source.minVersion === "TLSv1.3") minVersion = "TLSv1.3";
    }
    return { ...picked, rejectUnauthorized: true, minVersion };
}

/** A request rewritten to the relay, sent as `fetch` would send it. */
export type RelaySend = (request: Request) => Promise<Response>;

const nullBodyStatuses = new Set([101, 103, 204, 205, 304]);

// The relay's own agents, made when the worker starts, before any extension runs. Node merges an agent's options
// over a request's, so the global agents, which an extension can replace or loosen, never carry a relay request.
// They keep no TLS sessions: a resumed session isn't verified again, so every relay connection gets a full handshake
// checked against the trust of the moment.
const relayAgents = { "https:": new https.Agent({ maxCachedSessions: 0 }), "http:": new http.Agent() };

/**
 * Sends a request rewritten to the relay through Node's `http`/`https`, never undici, whose verification follows
 * the worker's environment: what goes out is the `Request` `fetch` would send (its method, headers and serialized
 * body, its `signal`), over a connection that always verifies (`relayTLSOptions`). The answer comes back as the
 * `Response` `fetch` would give: its status and headers, and its body streamed and decoded (gzip, deflate, br),
 * though it asks for none. A redirect isn't followed.
 */
export const sendToRelay: RelaySend = async (request) => {
    const url = new URL(request.url);
    const body =
        request.method === "GET" || request.method === "HEAD" ? undefined : Buffer.from(await request.arrayBuffer());
    const headers: Record<string, string> = {};
    request.headers.forEach((value, name) => {
        if (name !== "host" && name !== "accept-encoding" && name !== "content-length") headers[name] = value;
    });
    headers["accept-encoding"] = "identity";
    if (body !== undefined) headers["content-length"] = String(body.length);
    const secure = url.protocol === "https:";
    return new Promise<Response>((resolve, reject) => {
        const agent = relayAgents[secure ? "https:" : "http:"];
        const tlsPins = secure ? relayTLSOptions() : {};
        const options = { method: request.method, headers, signal: request.signal, agent, ...tlsPins };
        const sent = (secure ? https : http).request(url, options, (answer) => {
            const status = answer.statusCode ?? 0;
            const answerHeaders = new Headers();
            for (let at = 0; at + 1 < answer.rawHeaders.length; at += 2) {
                answerHeaders.append(answer.rawHeaders[at], answer.rawHeaders[at + 1]);
            }
            if (nullBodyStatuses.has(status) || request.method === "HEAD" || redirectStatuses.has(status)) {
                answer.resume();
                return resolve(new Response(null, { status, statusText: answer.statusMessage, headers: answerHeaders }));
            }
            const encoding = (answer.headers["content-encoding"] ?? "").toLowerCase().trim();
            const decoder =
                encoding === "gzip" || encoding === "x-gzip"
                    ? zlib.createGunzip()
                    : encoding === "deflate"
                      ? zlib.createInflate()
                      : encoding === "br"
                        ? zlib.createBrotliDecompress()
                        : null;
            const stream = decoder ? answer.pipe(decoder) : answer;
            if (decoder) answer.on("error", (error) => decoder.destroy(error));
            const readable = Readable.toWeb(stream) as unknown as ReadableStream<Uint8Array>;
            resolve(new Response(readable, { status, statusText: answer.statusMessage, headers: answerHeaders }));
        });
        sent.on("error", (cause) =>
            reject(cause.name === "AbortError" ? cause : new TypeError("fetch failed", { cause })),
        );
        sent.end(body);
    });
};

/** Wraps `original` with `decide`'s rules. */
export function rewriteFetch(
    original: Fetch,
    providers: OAuthProvider[],
    server: (provider: string) => Promise<ServerAnswer>,
    send: RelaySend = sendToRelay,
): Fetch {
    const wrapped = async function fetch(input: Parameters<Fetch>[0], init?: Parameters<Fetch>[1]) {
        const request = typeof Request !== "undefined" && input instanceof Request ? input : null;
        // Anything but a Request is read as `fetch` reads it, as a string: a URL, a URL from another realm, or any
        // object with a `toString()`.
        const parsed = parse(request ? request.url : String(input));
        const method = init?.method ?? request?.method ?? "GET";
        if (parsed === null || !needsDecision(parsed, providers, method)) return original(input, init);

        const body = init?.body ?? (request ? await request.clone().text() : undefined);
        const decision = await decide(method, parsed, body, providers, server);
        if (decision.kind === "untouched") return original(input, init);
        if (decision.kind === "refused") throw refusalError(decision);
        // The relay gets the request as fetch would send it, over a connection that always verifies, and a
        // redirect is never followed: a 307 or 308 would send the body (the code, the verifier or the refresh
        // token) on to wherever the relay points.
        const outgoing = request ? new Request(decision.target, request) : new Request(decision.target, init);
        const response = await send(outgoing);
        if (redirectStatuses.has(response.status)) {
            await response.body?.cancel().catch(() => {});
            throw new Error(redirectedMessage);
        }
        return response;
    };
    return wrapped as Fetch;
}
