// The worker's fetch rewrite (SPEC-056 §2, with #174's MUST items): only a POST to a table token or refresh URL with
// an authorization-code or refresh grant goes to the relay; a provider's own URL (Google, Jira, Zoom) only for an
// extension with a relay sign-in there; and nothing ever goes to Raycast's proxy hosts. The table is core's, pinned
// in `fixtures/oauth-providers.json` by a Swift test.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import {
    grantType,
    providersFromEnvironment,
    redirectedMessage,
    rewriteFetch,
    route,
    type ServerAnswer,
} from "../src/api/oauth-fetch.ts";
import { signInOffMessage } from "../src/api/oauth.ts";

const fixture = readFileSync(new URL("./fixtures/oauth-providers.json", import.meta.url), "utf8");
const providers = providersFromEnvironment(fixture);
const on: ServerAnswer = { server: "https://relay.example/base/", signedIn: true };

/** A fetch that records what it was asked for, and never sends anything. */
function recorder() {
    const sent: { url: string; method?: string; body?: unknown }[] = [];
    const send = (async (input: string | URL | Request, init?: RequestInit) => {
        const url = input instanceof Request ? input.url : String(input);
        const body = input instanceof Request ? await input.text() : init?.body;
        sent.push({ url, method: input instanceof Request ? input.method : init?.method, body });
        return new Response("{}", { status: 200 });
    }) as typeof globalThis.fetch;
    return { sent, fetch: send };
}

const post = (grant: string, extra: Record<string, string> = {}) => ({
    method: "POST",
    body: JSON.stringify({ grant_type: grant, ...extra }),
    headers: { "Content-Type": "application/json" },
});

test("the table reads from the app's variable, and a bad one is empty", () => {
    assert.deepEqual(
        providers.map((provider) => provider.id),
        ["github", "linear", "slack", "asana", "google", "jira", "zoom"],
    );
    assert.deepEqual(providersFromEnvironment("not json"), []);
    assert.deepEqual(providersFromEnvironment('{"id":"x"}'), []);
    assert.deepEqual(providersFromEnvironment('[{"id":"x"}]'), [], "entries without every URL are dropped");
    assert.deepEqual(providersFromEnvironment(undefined), []);
});

test("exactly the seven providers' token and refresh requests go to the relay", async () => {
    const { sent, fetch } = recorder();
    const asked: string[] = [];
    const wrapped = rewriteFetch(fetch, providers, async (provider) => (asked.push(provider), on), fetch);
    const expected: [string, string, string][] = [
        ["https://github.oauth.raycast.com/token", "github/token", "authorization_code"],
        ["https://github.oauth.raycast.com/refresh-token", "github/refresh-token", "refresh_token"],
        ["https://linear.oauth.raycast.com/token", "linear/token", "authorization_code"],
        ["https://linear.oauth.raycast.com/refresh-token", "linear/refresh-token", "refresh_token"],
        ["https://slack.oauth.raycast.com/token", "slack/token", "authorization_code"],
        ["https://slack.oauth.raycast.com/refresh-token", "slack/refresh-token", "refresh_token"],
        ["https://asana.oauth.raycast.com/token", "asana/token", "authorization_code"],
        ["https://asana.oauth.raycast.com/refresh-token", "asana/refresh-token", "refresh_token"],
        // These refresh at their token URL: the grant decides.
        ["https://oauth2.googleapis.com/token", "google/token", "authorization_code"],
        ["https://oauth2.googleapis.com/token", "google/refresh-token", "refresh_token"],
        ["https://auth.atlassian.com/oauth/token", "jira/token", "authorization_code"],
        ["https://auth.atlassian.com/oauth/token", "jira/refresh-token", "refresh_token"],
        ["https://zoom.us/oauth/token", "zoom/token", "authorization_code"],
        ["https://zoom.us/oauth/token", "zoom/refresh-token", "refresh_token"],
    ];
    for (const [url, target, grant] of expected) {
        const init = post(grant, { code: "c" });
        await wrapped(url, init);
        const last = sent.at(-1)!;
        assert.equal(last.url, `https://relay.example/base/${target}`, url);
        assert.equal(last.method, "POST");
        assert.equal(last.body, init.body, "the body goes unchanged");
    }
    assert.deepEqual(asked, expected.map(([, target]) => target.split("/")[0]));
});

test("anything else at a provider's own token URL is left alone", async () => {
    const { sent, fetch } = recorder();
    const wrapped = rewriteFetch(fetch, providers, async () => on, fetch);
    const untouched: [string, RequestInit | undefined][] = [
        // Not a POST, or not a code or refresh grant: a service account's JWT grant stays with Google.
        ["https://oauth2.googleapis.com/token", { method: "GET" }],
        ["https://oauth2.googleapis.com/token", undefined],
        ["https://oauth2.googleapis.com/token", post("urn:ietf:params:oauth:grant-type:jwt-bearer")],
        ["https://zoom.us/oauth/token", post("client_credentials")],
        ["https://zoom.us/oauth/token", { method: "POST", body: "no grant here" }],
        // Not a table URL.
        ["https://api.github.com/user", post("authorization_code")],
        ["https://github.com/login/oauth/access_token", post("authorization_code")],
        ["https://oauth2.googleapis.com/tokeninfo", post("authorization_code")],
        ["https://relay.example/base/github/token", post("authorization_code")],
    ];
    for (const [url, init] of untouched) {
        await wrapped(url, init);
        assert.equal(sent.at(-1)!.url, url, url);
    }
    assert.equal(sent.length, untouched.length);
});

test("a provider's own URL goes to the relay only for an extension with a relay sign-in there", async () => {
    const { sent, fetch } = recorder();
    const wrapped = rewriteFetch(fetch, providers, async () => ({ ...on, signedIn: false }), fetch);
    await wrapped("https://oauth2.googleapis.com/token", post("refresh_token", { refresh_token: "r" }));
    await wrapped("https://auth.atlassian.com/oauth/token", post("authorization_code", { code: "c" }));
    assert.deepEqual(
        sent.map((request) => request.url),
        ["https://oauth2.googleapis.com/token", "https://auth.atlassian.com/oauth/token"],
        "its own flow goes where it was going",
    );
    // Raycast's hosts don't depend on it: the relay is the only place they can go.
    await wrapped("https://github.oauth.raycast.com/token", post("authorization_code"));
    assert.equal(sent.at(-1)!.url, "https://relay.example/base/github/token");
});

test("a URL object or a Request is rewritten the same way", async () => {
    const { sent, fetch } = recorder();
    const wrapped = rewriteFetch(fetch, providers, async () => ({ server: "https://relay.example", signedIn: true }), fetch);
    await wrapped(new URL("https://linear.oauth.raycast.com/token"), {
        method: "POST",
        body: new URLSearchParams({ grant_type: "authorization_code" }),
    });
    assert.equal(sent.at(-1)!.url, "https://relay.example/linear/token");
    const params = new URLSearchParams({ grant_type: "refresh_token", refresh_token: "r" });
    await wrapped(new Request("https://zoom.us/oauth/token", { method: "POST", body: params }));
    assert.equal(sent.at(-1)!.url, "https://relay.example/zoom/refresh-token");
    assert.equal(sent.at(-1)!.method, "POST");
    assert.equal(sent.at(-1)!.body, "grant_type=refresh_token&refresh_token=r");
    await wrapped("HTTPS://GitHub.oauth.raycast.com/token", post("authorization_code"));
    assert.equal(sent.at(-1)!.url, "https://relay.example/github/token", "matched as fetch would request it");
    await wrapped({ toString: () => "https://slack.oauth.raycast.com/token" } as unknown as string, post("authorization_code"));
    assert.equal(sent.at(-1)!.url, "https://relay.example/slack/token", "any other input, read as a string");
    const elsewhere = { toString: () => "https://api.github.com/user" };
    await wrapped(elsewhere as unknown as string);
    assert.equal(sent.at(-1)!.url, "https://api.github.com/user", "and anything else goes where it was going");
});

for (const [state, answer] of [
    ["on", on],
    ["off", { server: null, signedIn: false }],
] as const) {
    test(`with sign-in ${state}, nothing is sent to Raycast's proxy hosts`, async () => {
        const { sent, fetch } = recorder();
        const wrapped = rewriteFetch(fetch, providers, async () => answer, fetch);
        const refused: [string, RequestInit | undefined][] = [
            ["https://github.oauth.raycast.com/anything-else", post("authorization_code")],
            ["https://github.oauth.raycast.com/token", { method: "GET" }],
            ["https://github.oauth.raycast.com/token", post("client_credentials")],
            ["https://slack.oauth.raycast.com/authorize", undefined],
            ["https://notion.oauth.raycast.com/token", post("authorization_code")],
            ["https://oauth.raycast.com/", undefined],
            // DNS ignores a trailing dot, so these are the same hosts.
            ["https://github.oauth.raycast.com./token", post("authorization_code")],
            ["https://github.oauth.raycast.com../anything-else", undefined],
            ["https://OAUTH.raycast.com./", undefined],
        ];
        for (const [url, init] of refused) {
            await assert.rejects(wrapped(url, init), /Fudge doesn't send requests to|Sign-in is off/, url);
            // Any other input is read as `fetch` reads it, as a string: an object with a `toString()`, or a URL
            // from another realm.
            const stringy = { toString: () => url } as unknown as string;
            await assert.rejects(wrapped(stringy, init), /Fudge doesn't send requests to|Sign-in is off/, `{ ${url} }`);
        }
        const foreign = { href: "https://github.oauth.raycast.com/x", toString: () => "https://github.oauth.raycast.com/x" };
        await assert.rejects(wrapped(foreign as unknown as URL), /Fudge doesn't send requests to|Sign-in is off/);
        if (state === "off") {
            await assert.rejects(wrapped("https://github.oauth.raycast.com/token", post("authorization_code")), {
                message: signInOffMessage,
            });
            // The providers' own token URLs, and everything else, go where they were going.
            await wrapped("https://oauth2.googleapis.com/token", post("refresh_token"));
            await wrapped("https://api.github.com/user");
            assert.deepEqual(
                sent.map((request) => request.url),
                ["https://oauth2.googleapis.com/token", "https://api.github.com/user"],
            );
        } else {
            assert.equal(sent.length, 0, "nothing was sent");
        }
    });
}

for (const status of [301, 302, 303, 307, 308]) {
    test(`a ${status} from the relay is an error, never followed`, async () => {
        const sent: { url: string }[] = [];
        let cancelled = 0;
        const answer = (async (input: string | URL | Request, init?: RequestInit) => {
            sent.push({ url: input instanceof Request ? input.url : String(input) });
            const body = new ReadableStream({ cancel: () => void cancelled++ });
            return new Response(body, { status, headers: { Location: "https://elsewhere.example/steal" } });
        }) as typeof globalThis.fetch;
        const wrapped = rewriteFetch(answer, providers, async () => on, answer);
        await assert.rejects(wrapped("https://github.oauth.raycast.com/token", post("authorization_code")), {
            message: redirectedMessage,
        });
        const params = new URLSearchParams({ grant_type: "refresh_token", refresh_token: "r" });
        await assert.rejects(wrapped(new Request("https://zoom.us/oauth/token", { method: "POST", body: params })), {
            message: redirectedMessage,
        });
        assert.deepEqual(sent, [
            { url: "https://relay.example/base/github/token" },
            { url: "https://relay.example/base/zoom/refresh-token" },
        ]);
        assert.equal(cancelled, 2, "the redirect's body isn't left open");
    });
}

test("with Node's own fetch, the relay's redirect never reaches its Location", async () => {
    let reached = 0;
    const listen = (server: Server) =>
        new Promise<number>((resolve) => server.listen(0, "127.0.0.1", () => resolve((server.address() as AddressInfo).port)));
    const elsewhere = createServer((_request, response) => {
        reached++;
        response.end("{}");
    });
    const elsewherePort = await listen(elsewhere);
    let status = 307;
    const relay = createServer((_request, response) => {
        response.writeHead(status, { Location: `http://127.0.0.1:${elsewherePort}/steal` });
        response.end();
    });
    const relayPort = await listen(relay);
    try {
        const wrapped = rewriteFetch(globalThis.fetch, providers, async () => ({
            server: `http://127.0.0.1:${relayPort}`,
            signedIn: true,
        }));
        for (const answer of [307, 302]) {
            status = answer;
            await assert.rejects(wrapped("https://github.oauth.raycast.com/token", post("authorization_code")), {
                message: redirectedMessage,
            });
        }
        assert.equal(reached, 0, "nothing was sent on");
    } finally {
        relay.close();
        elsewhere.close();
    }
});

test("a request that isn't rewritten keeps fetch's own redirects", async () => {
    const seen: (RequestInit | undefined)[] = [];
    const answer = (async (_input: string | URL | Request, init?: RequestInit) => {
        seen.push(init);
        return new Response("{}", { status: 302, headers: { Location: "https://example.com/next" } });
    }) as typeof globalThis.fetch;
    // No relay sign-in for Google here, so its own token URL is left alone.
    const wrapped = rewriteFetch(answer, providers, async () => ({ server: on.server, signedIn: false }));
    const response = await wrapped("https://api.github.com/user");
    assert.equal(response.status, 302, "handed back as fetch gave it");
    await wrapped("https://oauth2.googleapis.com/token", { ...post("refresh_token"), redirect: "follow" });
    assert.deepEqual(seen, [undefined, { ...post("refresh_token"), redirect: "follow" }]);
});

test("routing and grant types", () => {
    assert.deepEqual(route("GET", "https://example.com/", null, providers), { kind: "untouched" });
    assert.equal(route("POST", "https://slack.oauth.raycast.com/x", "authorization_code", providers).kind, "refused");
    const zoom = route("post", "https://zoom.us/oauth/token?x=1", "refresh_token", providers);
    assert.equal(zoom.kind === "relay" && `${zoom.provider.id}/${zoom.endpoint}/${zoom.ownHost}`, "zoom/refresh-token/true");
    assert.equal(grantType(new URLSearchParams({ grant_type: "refresh_token" })), "refresh_token");
    assert.equal(grantType('{"grant_type":"authorization_code"}'), "authorization_code");
    assert.equal(grantType("grant_type=refresh_token&x=1"), "refresh_token");
    assert.equal(grantType(undefined), null);
    assert.equal(grantType("{}"), null);
});
