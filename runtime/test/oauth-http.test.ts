// Sign-in requests below `fetch` (SPEC-075): `http` and `https` follow `decide`'s rules, and nothing connects to
// Raycast's proxy hosts, whatever the client. Everything here runs on 127.0.0.1; a refusal happens before any DNS
// lookup or socket.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
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
import zlib from "node:zlib";
import {
    providersFromEnvironment,
    redirectedMessage,
    rewriteFetch,
    refusedMessage,
    type OAuthProvider,
    type ServerAnswer,
} from "../src/api/oauth-fetch.ts";
import { guardConnections, guardRequests, relayTLSOptions, requestURL } from "../src/api/oauth-http.ts";
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

// A server with a self-signed certificate for 127.0.0.1, made for this run: reached only with its `ca`. It stands for
// a provider's own token URL (as Google's is) and for a relay.
const certs = mkdtempSync(path.join(tmpdir(), "fudge-tls-"));
execFileSync("openssl", [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
    "-addext", "subjectAltName=IP:127.0.0.1",
    "-keyout", path.join(certs, "key.pem"), "-out", path.join(certs, "cert.pem"),
], { stdio: "ignore" });
const ca = readFileSync(path.join(certs, "cert.pem"));
const secureSeen: Seen[] = [];
const secureHeaders: http.IncomingHttpHeaders[] = [];
let secure: https.Server;
const secureBase = () => `https://127.0.0.1:${(secure.address() as AddressInfo).port}`;

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
    secure = https.createServer({ key: readFileSync(path.join(certs, "key.pem")), cert: ca }, async (request, response) => {
        secureHeaders.push(request.headers);
        await record(secureSeen, request);
        if (request.headers["x-answer"] === "gzip") {
            // Compressed whatever was asked, in two pieces, as a relay behind a proxy might answer.
            const body = zlib.gzipSync('{"secure":true,"streamed":true}');
            response.writeHead(200, { "Content-Type": "application/json", "Content-Encoding": "gzip" });
            response.write(body.subarray(0, 10));
            setTimeout(() => response.end(body.subarray(10)), 20);
            return;
        }
        response.writeHead(200, { "Content-Type": "application/json" }).end('{"secure":true}');
    });
    await new Promise<void>((resolve) => secure.listen(0, "127.0.0.1", resolve));
    providers = [
        ...table,
        {
            id: "localco",
            name: "LocalCo",
            authorizeURL: `${base(own)}/authorize`,
            tokenURL: `${base(own)}/token`,
            refreshURL: `${base(own)}/token`,
        },
        {
            id: "secureco",
            name: "SecureCo",
            authorizeURL: `${secureBase()}/authorize`,
            tokenURL: `${secureBase()}/token`,
            refreshURL: `${secureBase()}/token`,
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
    secure.close();
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

test("a held request passed through goes out as the caller made it: its CA, its agent, and still the backstop", async () => {
    answer = { server: base(relay), signedIn: false };
    secureSeen.length = 0;
    const token = () => `${secureBase()}/token`;

    // The caller's own CA reaches the connection; without it, the certificate isn't trusted.
    const got = await exchange(() => https.request(token(), { ...post, ca }), codeGrant);
    assert.equal(got.body, '{"secure":true}');
    assert.deepEqual(secureSeen, [{ method: "POST", path: "/token", host: `127.0.0.1:${port(secure)}`, body: codeGrant }]);
    await assert.rejects(exchange(() => https.request(token(), post), codeGrant), /self[- ]signed/);

    // The caller's agent makes the connection, with its own options.
    const agent = new https.Agent({ ca });
    let made = 0;
    const create = agent.createConnection.bind(agent) as (...args: unknown[]) => net.Socket;
    agent.createConnection = ((...args: unknown[]) => {
        made++;
        return create(...args);
    }) as typeof agent.createConnection;
    const viaAgent = await exchange(() => https.request(token(), { ...post, agent }), codeGrant);
    assert.equal(viaAgent.body, '{"secure":true}');
    assert.equal(made, 1, "the caller's agent opened the connection");
    agent.destroy();

    // The backstop still sees the connection it opens.
    await assert.rejects(
        exchange(() => https.request(token(), { ...post, ca, servername: "x.oauth.raycast.com" }), codeGrant),
        /Fudge doesn't send requests to x\.oauth\.raycast\.com\./,
    );
});

test("a request rewritten to the relay keeps the caller's TLS options, but not its server name", async () => {
    answer = { server: secureBase(), signedIn: false };
    secureSeen.length = 0;
    const options = { ...post, ca, servername: "github.oauth.raycast.com" };
    const got = await exchange(() => https.request("https://github.oauth.raycast.com/token", options), codeGrant);
    assert.equal(got.body, '{"secure":true}');
    assert.deepEqual(secureSeen.map((seen) => seen.path), ["/github/token"]);
    await assert.rejects(
        exchange(() => https.request("https://github.oauth.raycast.com/token", post), codeGrant),
        /self[- ]signed/,
        "the relay's certificate is checked with the caller's CA, or the system's",
    );
});

test("a request rewritten to the relay never takes an option that weakens verification", async () => {
    // Only trust and identity go along, and a minimum version no lower than Node's.
    const agent = new https.Agent({ ca: "agent-ca", rejectUnauthorized: false });
    const kept = relayTLSOptions({
        agent,
        cert: "c",
        key: "k",
        crl: "r",
        rejectUnauthorized: false,
        checkServerIdentity: () => undefined,
        ciphers: "NULL",
        secureOptions: 4,
        minVersion: "TLSv1",
        maxVersion: "TLSv1",
        secureProtocol: "TLSv1_method",
        servername: "elsewhere.example",
    });
    const pinned = { rejectUnauthorized: true, minVersion: "TLSv1.2" };
    assert.deepEqual(kept, { ca: "agent-ca", cert: "c", key: "k", crl: "r", ...pinned });
    assert.deepEqual(relayTLSOptions({ minVersion: "TLSv1.3" }), { ...pinned, minVersion: "TLSv1.3" });
    agent.destroy();

    // End to end: with the relay's certificate unknown to the system, each weakening option on its own still
    // leaves the request refused by verification, and the caller's checkServerIdentity is never asked.
    answer = { server: secureBase(), signedIn: false };
    secureSeen.length = 0;
    let asked = 0;
    const weakening: Record<string, unknown>[] = [
        { rejectUnauthorized: false },
        { checkServerIdentity: () => void asked++ },
        { minVersion: "TLSv1" },
        { secureOptions: 0 },
        { ciphers: "ALL" },
        { agent: new https.Agent({ rejectUnauthorized: false }) },
    ];
    for (const option of weakening) {
        await assert.rejects(
            exchange(() => https.request("https://github.oauth.raycast.com/token", { ...post, ...option }), codeGrant),
            /self[- ]signed/,
            Object.keys(option).join(),
        );
    }
    assert.equal(asked, 0);
    assert.equal(secureSeen.length, 0, "nothing reached the relay unverified");

    // A request passed through unchanged keeps them: it goes where the caller sent it.
    const passed = await exchange(() => https.request(`${secureBase()}/token`, { ...post, rejectUnauthorized: false }), codeGrant);
    assert.equal(passed.body, '{"secure":true}');
});

test("a rewrite to the relay always verifies, whatever NODE_TLS_REJECT_UNAUTHORIZED says, through https and fetch", async () => {
    answer = { server: secureBase(), signedIn: false };
    secureSeen.length = 0;
    const before = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    try {
        await assert.rejects(
            exchange(() => https.request("https://github.oauth.raycast.com/token", post), codeGrant),
            /self[- ]signed/,
        );
        const wrapped = rewriteFetch(globalThis.fetch, providers, async () => answer);
        await assert.rejects(
            wrapped("https://github.oauth.raycast.com/token", { ...post, body: codeGrant }),
            (error: Error) => error instanceof TypeError && /self[- ]signed/.test(String((error.cause as Error)?.message)),
        );
        assert.equal(secureSeen.length, 0, "nothing reached the unverified relay");
        // The extension's own traffic follows its own setting.
        const own = await exchange(() => https.request(`${secureBase()}/token`, post), codeGrant);
        assert.equal(own.body, '{"secure":true}');
    } finally {
        if (before === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
        else process.env.NODE_TLS_REJECT_UNAUTHORIZED = before;
    }
});

test("a rewrite to a relay with a valid certificate works through fetch: sent as fetch would, answered as fetch would", async () => {
    answer = { server: secureBase(), signedIn: false };
    secureSeen.length = 0;
    secureHeaders.length = 0;
    const defaults = tls.getCACertificates("default");
    tls.setDefaultCACertificates([...defaults, ca.toString()]);
    try {
        const wrapped = rewriteFetch(globalThis.fetch, providers, async () => answer);
        const form = new URLSearchParams({ grant_type: "authorization_code", code: "c", code_verifier: "v" });
        const response = await wrapped("https://github.oauth.raycast.com/token", {
            method: "POST",
            body: form,
            headers: { "X-Answer": "gzip", Accept: "application/json" },
        });
        assert.equal(response.status, 200);
        assert.equal(await response.text(), '{"secure":true,"streamed":true}', "streamed and decoded, as fetch does");
        assert.deepEqual(secureSeen.map((seen) => [seen.path, seen.body]), [["/github/token", form.toString()]]);
        const sent = secureHeaders[0]!;
        assert.equal(sent["content-type"], "application/x-www-form-urlencoded;charset=UTF-8", "fetch's own serialization");
        assert.equal(sent["accept-encoding"], "identity");
        assert.equal(sent.accept, "application/json");
        assert.equal(sent.host, `127.0.0.1:${port(secure)}`);
    } finally {
        tls.setDefaultCACertificates(defaults);
    }
});

test("a pass-through keeps a Host header the caller set itself", async () => {
    answer = { server: base(relay), signedIn: false };
    ownSeen.length = 0;
    const headers = { ...post.headers, Host: "custom.example" };
    await exchange(() => http.request(`${base(own)}/token`, { ...post, headers }), codeGrant);
    await exchange(() => http.request(`${base(own)}/token`, post), codeGrant);
    assert.deepEqual(ownSeen.map((seen) => seen.host), ["custom.example", `127.0.0.1:${port(own)}`]);
});
