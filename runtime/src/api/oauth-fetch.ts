// The worker's `fetch`, for sign-in through the relay (SPEC-056 §2). `OAuthService` fetches its token and refresh
// URLs itself, so exactly the built-in providers' default token and refresh URLs go to `<server>/<provider>/token`
// or `/refresh-token` instead. Nothing else is changed. With sign-in off, a request to one of Raycast's proxy hosts
// is refused here, never sent.
//
// The provider table is core's (`OAuthProviders`), handed over by the app in `FUDGE_OAUTH_PROVIDERS`.

import { signInOffMessage } from "./oauth.ts";

export type OAuthProvider = { id: string; name: string; authorizeURL: string; tokenURL: string; refreshURL: string };

export const providersVariable = "FUDGE_OAUTH_PROVIDERS";

/** The table the app passed; empty when it's missing or doesn't read. */
export function providersFromEnvironment(value = process.env[providersVariable]): OAuthProvider[] {
    try {
        const parsed: unknown = JSON.parse(value ?? "[]");
        if (!Array.isArray(parsed)) return [];
        return parsed.filter(
            (entry): entry is OAuthProvider =>
                typeof entry === "object" &&
                entry !== null &&
                ["id", "name", "authorizeURL", "tokenURL", "refreshURL"].every(
                    (key) => typeof (entry as Record<string, unknown>)[key] === "string",
                ),
        );
    } catch {
        return [];
    }
}

/** Raycast's sign-in proxies, `*.oauth.raycast.com`: Fudge never sends anything there. DNS ignores a trailing dot,
 * so `github.oauth.raycast.com.` is one of them too. */
export function isRaycastHost(hostname: string): boolean {
    const host = hostname.toLowerCase().replace(/\.+$/, "");
    return host === "oauth.raycast.com" || host.endsWith(".oauth.raycast.com");
}

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
 * `/refresh-token` for a refresh. Anything else on Raycast's proxy hosts is refused; everything else is untouched.
 */
export function route(method: string, url: string, grant: string | null, providers: OAuthProvider[]): Route {
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
        return { kind: "relay", provider, endpoint, ownHost: !raycast };
    }
    return raycast ? { kind: "refused" } : { kind: "untouched" };
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

/** Refused: the relay answered a token or refresh request with a redirect. */
export const redirectedMessage = "The sign-in server redirected the token request, and Fudge doesn't follow that.";

/** The statuses `fetch` follows. */
const redirects = new Set([301, 302, 303, 307, 308]);

/**
 * Wraps `original`. `server` is asked only for a request that may go to the relay, so a server changed while a
 * command runs is honoured. A provider's own token URL (Google, Jira, Zoom) goes to the relay only for an extension
 * with a relay sign-in for it; an extension's own flow there is left alone.
 */
export function rewriteFetch(
    original: Fetch,
    providers: OAuthProvider[],
    server: (provider: string) => Promise<ServerAnswer>,
): Fetch {
    const wrapped = async function fetch(input: Parameters<Fetch>[0], init?: Parameters<Fetch>[1]) {
        const request = typeof Request !== "undefined" && input instanceof Request ? input : null;
        // Anything but a Request is read as `fetch` reads it, as a string: a URL, a URL from another realm, or any
        // object with a `toString()`.
        const parsed = parse(request ? request.url : String(input));
        if (parsed === null) return original(input, init);
        const raycast = isRaycastHost(parsed.hostname);
        if (!raycast && providerFor(parsed, providers) === null) return original(input, init);

        const method = init?.method ?? request?.method ?? "GET";
        const body = init?.body ?? (request ? await request.clone().text() : undefined);
        const where = route(method, parsed.href, grantType(body), providers);
        if (where.kind === "untouched") return original(input, init);
        if (where.kind === "refused") throw new Error(refusedMessage(parsed.host, false));

        const answer = await server(where.provider.id);
        if (answer.server === null || (where.ownHost && !answer.signedIn)) {
            if (where.ownHost) return original(input, init);
            throw new Error(refusedMessage(parsed.host, answer.server === null));
        }
        const target = `${answer.server.replace(/\/+$/, "")}/${where.provider.id}/${where.endpoint}${parsed.search}`;
        // A redirect is never followed: a 307 or 308 would send the body (the code, the verifier or the refresh
        // token) on to wherever the relay points.
        const manual = { ...init, redirect: "manual" as const };
        const response = await (request ? original(new Request(target, request), manual) : original(target, manual));
        if (redirects.has(response.status)) {
            await response.body?.cancel().catch(() => {});
            throw new Error(redirectedMessage);
        }
        return response;
    };
    return wrapped as Fetch;
}
