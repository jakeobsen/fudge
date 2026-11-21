// Sign-in requests below `fetch` (SPEC-075): `http` and `https` follow `decide`'s rules, and nothing connects to
// Raycast's proxy hosts, whatever the client. Everything here runs on 127.0.0.1; a refusal happens before any DNS
// lookup or socket.

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import http, { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import http2 from "node:http2";
import https from "node:https";
import { createRequire, syncBuiltinESMExports } from "node:module";
import net, { type AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import tls from "node:tls";
import { pathToFileURL } from "node:url";
import {
    providersFromEnvironment,
    redirectedMessage,
    refusedMessage,
    type OAuthProvider,
    type ServerAnswer,
} from "../src/api/oauth-fetch.ts";
import { guardConnections, guardRequests, requestURL } from "../src/api/oauth-http.ts";
import { signInOffMessage } from "../src/api/oauth.ts";

const table = providersFromEnvironment(readFileSync(new URL("./fixtures/oauth-providers.json", import.meta.url), "utf8"));
const sendFetch = globalThis.fetch;

type Seen = { method: string; path: string; host: string; body: string };
const relaySeen: Seen[] = [];
const ownSeen: Seen[] = [];
let relayStatus = 200;
let relay: Server;
let own: Server;
let elsewhere: Server;
let elsewhereHits = 0;
let answer: ServerAnswer = { server: null, signedIn: false };

async function listen(handler: (request: IncomingMessage, response: ServerResponse) => void): Promise<Server> {
    const server = createServer(handler);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    return server;
}
const port = (server: Server) => (server.address() as AddressInfo).port;
const base = (server: Server) => `http://127.0.0.1:${port(server)}`;

async function record(into: Seen[], request: IncomingMessage) {
    let body = "";
    for await (const chunk of request) body += chunk;
    into.push({ method: request.method!, path: request.url!, host: request.headers.host!, body });
}

/** The table, plus a provider whose own token URL is a local server (as Google's, Jira's and Zoom's are their own). */
let providers: OAuthProvider[];
const restore: (() => void)[] = [];

before(async () => {
    relay = await listen(async (request, response) => {
        await record(relaySeen, request);
        if (relayStatus >= 300 && relayStatus < 400) {
            response.writeHead(relayStatus, { Location: `${base(elsewhere)}/steal` }).end();
            return;
        }
        response.writeHead(relayStatus, { "Content-Type": "application/json" }).end('{"access_token":"at"}');
    });
    own = await listen(async (request, response) => {
        await record(ownSeen, request);
        response.writeHead(200, { "Content-Type": "application/json" }).end('{"own":true}');
    });
    elsewhere = await listen((_request, response) => {
        elsewhereHits++;
        response.end("stolen");
    });
    providers = [
        ...table,
        {
            id: "localco",
            name: "LocalCo",
            authorizeURL: `${base(own)}/authorize`,
            tokenURL: `${base(own)}/token`,
            refreshURL: `${base(own)}/token`,
        },
    ];
    restore.push(
        guardRequests({ http, https }, providers, async () => answer),
        guardConnections(),
    );
    syncBuiltinESMExports();
});

after(() => {
    restore.reverse().forEach((undo) => undo());
    syncBuiltinESMExports();
    relay.close();
    own.close();
    elsewhere.close();
});

/** A request through `send`, resolved with the status and body, or rejected with the request's error. */
function exchange(
    send: () => http.ClientRequest,
    body?: string,
): Promise<{ status: number; body: string; headers: http.IncomingHttpHeaders }> {
    return new Promise((resolve, reject) => {
        const request = send();
        request.on("error", reject);
        request.on("response", (response) => {
            let text = "";
            response.on("data", (chunk) => (text += chunk));
            response.on("end", () => resolve({ status: response.statusCode!, body: text, headers: response.headers }));
            response.on("error", reject);
        });
        if (!request.writableEnded) request.end(body);
    });
}

const codeGrant = JSON.stringify({ grant_type: "authorization_code", code: "c", code_verifier: "v" });
const post = { method: "POST", headers: { "Content-Type": "application/json" } };

test("Node reads a request's URL from any of its argument forms", () => {
    assert.equal(requestURL(["https://x.example/a?b=1"], "https:")?.url.href, "https://x.example/a?b=1");
    assert.equal(requestURL([new URL("https://x.example/a")], "https:")?.url.href, "https://x.example/a");
    assert.equal(requestURL([{ hostname: "x.example", path: "/t", method: "post" }], "https:")?.method, "POST");
    assert.equal(requestURL([{ host: "x.example", port: 8443 }], "https:")?.url.href, "https://x.example:8443/");
    assert.equal(requestURL(["http://x.example/a", { path: "/b" }], "http:")?.url.href, "http://x.example/b");
    assert.equal(requestURL([{ socketPath: "/tmp/s" }], "http:"), null);
});

for (const [state, given] of [
    ["on", { server: "http://relay.invalid", signedIn: true }],
    ["off", { server: null, signedIn: false }],
] as const) {
    test(`with sign-in ${state}, http and https never reach Raycast's proxy hosts`, async () => {
        answer = given;
        const refused = /Fudge doesn't send requests to ([a-z]+\.)?oauth\.raycast\.com\.|Sign-in is off/;
        const sends: [string, () => http.ClientRequest, string?][] = [
            ["https.request", () => https.request("https://github.oauth.raycast.com/anything", post), codeGrant],
            ["https.get", () => https.get("https://slack.oauth.raycast.com/authorize")],
            ["http.request", () => http.request("http://github.oauth.raycast.com/token", post), codeGrant],
            [
                "an options object",
                () => https.request({ hostname: "linear.oauth.raycast.com", path: "/x", method: "POST" }),
                "{}",
            ],
            ["a URL object", () => https.request(new URL("https://oauth.raycast.com/"))],
            ["case and a trailing dot", () => https.get("https://X.OAUTH.RAYCAST.COM./token")],
            [
                "a token request with another grant",
                () => https.request("https://github.oauth.raycast.com/token", post),
                JSON.stringify({ grant_type: "client_credentials" }),
            ],
        ];
        for (const [name, send, body] of sends) {
            await assert.rejects(exchange(send, body), refused, name);
        }
        if (state === "off") {
            await assert.rejects(
                exchange(() => https.request("https://github.oauth.raycast.com/token", post), codeGrant),
                { message: signInOffMessage },
            );
        }
        assert.equal(relaySeen.length, 0, "nothing went anywhere");
    });
}

test("a token request through https goes to the relay, body and headers intact", async () => {
    answer = { server: `${base(relay)}/base/`, signedIn: false };
    relaySeen.length = 0;
    const got = await exchange(
        () => https.request("https://github.oauth.raycast.com/token?x=1", { ...post, headers: { ...post.headers, "X-Kept": "yes" } }),
        codeGrant,
    );
    assert.deepEqual(got.body, '{"access_token":"at"}');
    assert.deepEqual(relaySeen, [
        { method: "POST", path: "/base/github/token?x=1", host: `127.0.0.1:${port(relay)}`, body: codeGrant },
    ]);

    // A streamed (chunked) body is read for its grant and sent on as it was.
    relaySeen.length = 0;
    const refresh = new URLSearchParams({ grant_type: "refresh_token", refresh_token: "r" }).toString();
    await exchange(() => {
        const request = https.request({ hostname: "github.oauth.raycast.com", path: "/refresh-token", method: "POST" });
        request.write(refresh.slice(0, 10));
        request.write(refresh.slice(10));
        return request;
    });
    assert.deepEqual(relaySeen.map((seen) => [seen.path, seen.body]), [["/base/github/refresh-token", refresh]]);
});

test("a redirect from the relay fails the request, and its Location is never reached", async () => {
    answer = { server: base(relay), signedIn: false };
    for (const status of [301, 302, 303, 307, 308]) {
        relayStatus = status;
        await assert.rejects(
            exchange(() => https.request("https://github.oauth.raycast.com/token", post), codeGrant),
            { message: redirectedMessage },
            String(status),
        );
    }
    relayStatus = 200;
    assert.equal(elsewhereHits, 0);
});

test("a provider's own token URL goes to the relay only with a relay sign-in, and is sent on as it was otherwise", async () => {
    relaySeen.length = 0;
    ownSeen.length = 0;
    answer = { server: base(relay), signedIn: false };
    const answered = await exchange(() => http.request(`${base(own)}/token`, post), codeGrant);
    assert.equal(answered.body, '{"own":true}');
    assert.deepEqual(ownSeen, [{ method: "POST", path: "/token", host: `127.0.0.1:${port(own)}`, body: codeGrant }]);
    assert.equal(relaySeen.length, 0);

    answer = { server: base(relay), signedIn: true };
    await exchange(() => http.request(`${base(own)}/token`, post), codeGrant);
    assert.deepEqual(relaySeen.map((seen) => seen.path), ["/localco/token"]);
});

test("other traffic streams through untouched", async () => {
    const server = await listen((request, response) => {
        response.writeHead(200, { "X-Path": request.url! });
        response.write("one,");
        setTimeout(() => response.end("two"), 10);
    });
    const got = await exchange(() => http.get(`${base(server)}/plain?q=1`));
    assert.equal(got.body, "one,two");
    assert.equal(got.headers["x-path"], "/plain?q=1");
    server.close();
});

test("a library that keeps request and get at load, CommonJS or ESM, still goes through the rules", async () => {
    answer = { server: base(relay), signedIn: false };
    const folder = mkdtempSync(path.join(tmpdir(), "fudge-http-"));
    writeFileSync(
        path.join(folder, "kept.cjs"),
        'const { request, get } = require("https"); module.exports = { request, get };',
    );
    writeFileSync(path.join(folder, "kept.mjs"), 'export { request, get } from "node:https";');
    const commonjs = createRequire(import.meta.url)(path.join(folder, "kept.cjs"));
    const esm = await import(pathToFileURL(path.join(folder, "kept.mjs")).href);
    for (const kept of [commonjs, esm]) {
        relaySeen.length = 0;
        await exchange(() => kept.request("https://github.oauth.raycast.com/token", post), codeGrant);
        assert.deepEqual(relaySeen.map((seen) => seen.path), ["/github/token"]);
        await assert.rejects(exchange(() => kept.get("https://github.oauth.raycast.com/x")), /Fudge doesn't send/);
    }
});

test("no connection reaches Raycast's proxy hosts, whatever the client, before any DNS lookup", async () => {
    const lookups: string[] = [];
    const lookup = ((host: string) => void lookups.push(host)) as unknown as net.LookupFunction;
    const failure = (socket: { once(event: "error", listener: (error: Error) => void): unknown }) =>
        new Promise<Error>((resolve) => socket.once("error", resolve));

    const raw = new net.Socket();
    const rawError = failure(raw);
    raw.connect(443, "x.oauth.raycast.com");
    assert.equal((await rawError).message, refusedMessage("x.oauth.raycast.com", false));

    assert.match((await failure(net.connect({ host: "X.OAUTH.RAYCAST.COM.", port: 443, lookup }))).message, /x\.oauth\.raycast\.com/);
    assert.match((await failure(tls.connect({ host: "github.oauth.raycast.com", port: 443, lookup }))).message, /Fudge doesn't send/);
    // By a TLS connection's name, with an address for the host.
    assert.match((await failure(tls.connect({ host: "10.0.0.1", servername: "x.oauth.raycast.com", port: 443 }))).message, /Fudge doesn't send/);
    const session = http2.connect("https://x.oauth.raycast.com");
    assert.match((await failure(session)).message, /Fudge doesn't send/);
    session.destroy();
    // undici's own fetch, under the worker's wrapper.
    await assert.rejects(sendFetch("https://x.oauth.raycast.com/token"), (error: Error) =>
        /Fudge doesn't send/.test(String((error.cause as Error)?.message)),
    );
    assert.deepEqual(lookups, []);
});
