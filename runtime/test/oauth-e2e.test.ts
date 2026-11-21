// Sign-in end to end (SPEC-056, SPEC-075): the real @raycast/utils' `OAuthService.github()` signs in through a fake
// relay to a fake provider, gets its access token, refreshes it, and signs out. It runs with 2.x, which uses the
// global `fetch`, and with 1.18.1, whose token requests go through `cross-fetch` → `node-fetch` → `https.request`, as
// store extensions bundle it. Everything runs on 127.0.0.1 in this process:
// the relay and the provider are local servers, the app's side is faked (its loopback listener included), and the
// browser is simulated by following the redirects to the loopback URL. Nothing contacts a real server.

import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import http, { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import https from "node:https";
import net, { type AddressInfo } from "node:net";
import Module, { createRequire } from "node:module";
import { after, before, test } from "node:test";
import { connect, settle } from "../src/bridge.ts";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";
import { providersFromEnvironment, rewriteFetch } from "../src/api/oauth-fetch.ts";
import { guardConnections, guardRequests } from "../src/api/oauth-http.ts";

const api = createApiModule() as Record<string, any>;
const sendFetch = globalThis.fetch;

/** Only 127.0.0.1: a request anywhere else fails the test instead of leaving the machine. */
const localOnly = ((input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.hostname !== "127.0.0.1") throw new Error(`the test tried to reach ${url.href}`);
    return sendFetch(input, init);
}) as typeof fetch;

async function listen(handler: (request: IncomingMessage, response: ServerResponse) => void): Promise<Server> {
    const server = createServer(handler);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    return server;
}

const base = (server: Server) => `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

async function body(request: IncomingMessage): Promise<Record<string, string>> {
    let text = "";
    for await (const chunk of request) text += chunk;
    if ((request.headers["content-type"] ?? "").includes("json")) return JSON.parse(text);
    return Object.fromEntries(new URLSearchParams(text));
}

function json(response: ServerResponse, status: number, value: unknown) {
    response.writeHead(status, { "Content-Type": "application/json" });
    response.end(JSON.stringify(value));
}

function redirect(response: ServerResponse, location: string) {
    response.writeHead(302, { Location: location });
    response.end();
}

const seal = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
const open = (value: string) => JSON.parse(Buffer.from(value, "base64url").toString());

let provider: Server;
let relay: Server;
let loopback: Server | null = null;
const relayLog: string[] = [];
const providerLog: string[] = [];
let issued = 0;

before(async () => {
    // The provider: it knows only the relay's app.
    provider = await listen(async (request, response) => {
        const url = new URL(request.url!, "http://x");
        providerLog.push(`${request.method} ${url.pathname}`);
        if (url.pathname === "/authorize") {
            assert.equal(url.searchParams.get("client_id"), "relay-app");
            const back = new URL(url.searchParams.get("redirect_uri")!);
            back.searchParams.set("code", "provider-code");
            back.searchParams.set("state", url.searchParams.get("state")!);
            return redirect(response, back.href);
        }
        const form = await body(request);
        assert.equal(form.client_secret, "relay-secret");
        if (form.grant_type === "authorization_code" && form.code === "provider-code") {
            issued++;
            return json(response, 200, { access_token: `at${issued}`, refresh_token: "rt", expires_in: 3600, scope: "repo" });
        }
        if (form.grant_type === "refresh_token" && form.refresh_token === "rt") {
            issued++;
            return json(response, 200, { access_token: `at${issued}`, expires_in: 3600 });
        }
        json(response, 400, { error: "invalid_grant" });
    });

    // The relay, as SPEC-055 describes it (with base64 for its sealing, which is enough here).
    relay = await listen(async (request, response) => {
        const url = new URL(request.url!, "http://x");
        relayLog.push(`${request.method} ${url.pathname}`);
        if (url.pathname === "/github/authorize") {
            const redirectURI = url.searchParams.get("redirect_uri")!;
            assert.match(redirectURI, /^http:\/\/127\.0\.0\.1:\d+\/oauth\/callback\//);
            assert.equal(url.searchParams.get("code_challenge_method"), "S256");
            const state = seal({
                redirectURI,
                state: url.searchParams.get("state"),
                challenge: url.searchParams.get("code_challenge"),
            });
            const to = new URL(`${base(provider)}/authorize`);
            to.searchParams.set("client_id", "relay-app");
            to.searchParams.set("redirect_uri", `${base(relay)}/github/callback`);
            to.searchParams.set("scope", url.searchParams.get("scope")!);
            to.searchParams.set("state", state);
            return redirect(response, to.href);
        }
        if (url.pathname === "/github/callback") {
            const sealed = open(url.searchParams.get("state")!);
            const back = new URL(sealed.redirectURI);
            back.searchParams.set("code", seal({ code: url.searchParams.get("code"), challenge: sealed.challenge }));
            back.searchParams.set("state", sealed.state);
            return redirect(response, back.href);
        }
        const form = await body(request);
        const exchange = (grant: Record<string, string>) =>
            sendFetch(`${base(provider)}/token`, {
                method: "POST",
                body: new URLSearchParams({ ...grant, client_id: "relay-app", client_secret: "relay-secret" }),
            });
        if (url.pathname === "/github/token") {
            const code = open(form.code);
            const challenge = createHash("sha256").update(form.code_verifier).digest("base64url");
            if (challenge !== code.challenge) return json(response, 400, { error: "invalid_grant" });
            const answer = await exchange({ grant_type: "authorization_code", code: code.code });
            return json(response, answer.status, await answer.json());
        }
        if (url.pathname === "/github/refresh-token") {
            const answer = await exchange({ grant_type: "refresh_token", refresh_token: form.refresh_token });
            return json(response, answer.status, await answer.json());
        }
        json(response, 404, { error: "not_found" });
    });

    // As the worker installs them: fetch, http and https, and the connection backstop, with only 127.0.0.1 allowed
    // under them all, so nothing in the test can leave the machine whatever client it uses.
    const providers = providersFromEnvironment(
        readFileSync(new URL("./fixtures/oauth-providers.json", import.meta.url), "utf8"),
    );
    const server = async (provider: string) => {
        assert.equal(provider, "github");
        return { server: base(relay), signedIn: false };
    };
    globalThis.fetch = rewriteFetch(localOnly, providers, server);
    const connect = net.Socket.prototype.connect;
    net.Socket.prototype.connect = function (this: net.Socket, ...args: unknown[]) {
        const options = (Array.isArray(args[0]) ? args[0][0] : args[0]) as { host?: string; path?: string } | number;
        if (typeof options === "object" && options.path !== undefined) return Reflect.apply(connect, this, args);
        const host = typeof options === "object" ? options.host : args[1];
        if (host !== "127.0.0.1") throw new Error(`the test tried to reach ${String(host)}`);
        return Reflect.apply(connect, this, args);
    } as typeof connect;
    restore.push(() => (net.Socket.prototype.connect = connect));
    restore.push(guardConnections(), guardRequests({ http, https }, providers, server));
});

const restore: (() => void)[] = [];

after(() => {
    restore.reverse().forEach((undo) => undo());
    globalThis.fetch = sendFetch;
    provider.close();
    relay.close();
    loopback?.close();
    connect(null);
});

/** The browser: follows the relay's and the provider's redirects until one leaves for the loopback URL. */
async function browse(url: string, loopbackBase: string): Promise<void> {
    let next = url;
    for (let hops = 0; hops < 10; hops++) {
        if (next.startsWith(loopbackBase)) {
            const answer = await sendFetch(next);
            assert.equal(answer.status, 200);
            assert.match(await answer.text(), /Signed in\. You can close this tab\./);
            return;
        }
        const answer = await sendFetch(next, { redirect: "manual" });
        assert.equal(answer.status, 302, next);
        next = answer.headers.get("location")!;
    }
    throw new Error("too many redirects");
}

// The app: sign-in on, the loopback listener, and tokens kept in memory per extension and provider.
const tokens = new Map<string, unknown>();
let waiting: { path: string; state?: string; resolve?: (code: string) => void } | null = null;

const app: Record<string, (params: any) => Promise<unknown> | unknown> = {
    "oauth.server": () => ({ server: base(relay) }),
    async "oauth.prepare"({ endpoint }) {
        assert.equal(endpoint, "https://github.oauth.raycast.com/authorize");
        const path = `/oauth/callback/${randomBytes(16).toString("base64url")}`;
        loopback ??= await listen((request, response) => {
            const url = new URL(request.url!, "http://x");
            if (request.method !== "GET" || !waiting || url.pathname !== waiting.path) {
                response.writeHead(404).end();
                return;
            }
            assert.equal(url.searchParams.get("state"), waiting.state);
            response.writeHead(200, { "Content-Type": "text/html" }).end("Signed in. You can close this tab.");
            waiting.resolve?.(url.searchParams.get("code")!);
        });
        waiting = { path };
        return { provider: "github", authorizeURL: `${base(relay)}/github/authorize`, redirectURI: `${base(loopback)}${path}` };
    },
    async "oauth.authorize"({ url, state, providerName }) {
        assert.equal(providerName, "GitHub");
        const code = new Promise<string>((resolve) => Object.assign(waiting!, { state, resolve }));
        // The user presses ↵: the browser opens the URL.
        await browse(url, base(loopback!));
        return { authorizationCode: await code };
    },
    "oauth.tokens.get": ({ providerId }) => tokens.get(`github/${providerId}`) ?? null,
    "oauth.tokens.set": ({ providerId, tokens: set }) => void tokens.set(`github/${providerId}`, set),
    "oauth.tokens.remove": ({ providerId }) => void tokens.delete(`github/${providerId}`),
};

// The real @raycast/utils, given Fudge's module for `require("@raycast/api")`, as the worker does for extensions.
type Load = (this: unknown, request: string, parent: unknown, isMain: boolean) => unknown;
const internals = Module as unknown as { _load: Load };
const load = internals._load;
internals._load = function (request, parent, isMain) {
    if (request === "@raycast/api") return api;
    return load.call(this, request, parent, isMain);
};
after(() => {
    internals._load = load;
});

for (const [version, utils] of [
    ["2.3.3, through fetch", "@raycast/utils"],
    ["1.18.1, through cross-fetch and https.request", "raycast-utils-1"],
]) {
    test(`OAuthService.github (@raycast/utils ${version}) signs in through the relay, refreshes, and signs out`, async () => {
            relayLog.length = 0;
        providerLog.length = 0;
        issued = 0;
        connect((request) => {
            setImmediate(async () => {
                try {
                    settle(request.id, await app[request.method](request.params));
                } catch (error) {
                    settle(request.id, undefined, (error as Error).message);
                }
            });
        });
        setLaunchContext({
            preferences: {},
            environment: { ...placeholderEnvironment, extensionName: "github", commandName: "search", commandMode: "no-view" },
            launchProps: {},
        });
        const { OAuthService, withAccessToken, getAccessToken } = createRequire(import.meta.url)(utils);
        const github = OAuthService.github({ scope: "repo" });

        // Signing in: the command runs once the token is there.
        const run = withAccessToken(github)(async () => getAccessToken());
        assert.deepEqual(await run({}), { token: "at1", type: "oauth" });
        assert.deepEqual(relayLog, ["GET /github/authorize", "GET /github/callback", "POST /github/token"]);
        assert.deepEqual(providerLog, ["GET /authorize", "POST /token"]);
        const stored = tokens.get("github/github") as Record<string, unknown>;
        assert.equal(stored.accessToken, "at1");
        assert.equal(stored.refreshToken, "rt");
        assert.equal(stored.scope, "repo");
        assert.equal(stored.providerName, "GitHub");
        assert.equal(stored.relayProvider, "github", "the app keeps it only for a sign-in it prepared");

        // Signed in: no sign-in, no request.
        relayLog.length = 0;
        assert.equal(await github.authorize(), "at1");
        assert.deepEqual(relayLog, []);

        // Expired: OAuthService refreshes through the relay, keeping the refresh token.
        tokens.set("github/github", { ...stored, updatedAt: new Date(Date.now() - 3600 * 1000).toISOString() });
        assert.equal(await github.authorize(), "at2");
        assert.deepEqual(relayLog, ["POST /github/refresh-token"]);
        assert.equal((tokens.get("github/github") as Record<string, unknown>).refreshToken, "rt");

        // Signing out.
        await github.client.removeTokens();
        assert.equal(await github.client.getTokens(), undefined);
        assert.equal(tokens.size, 0);
    });
}
