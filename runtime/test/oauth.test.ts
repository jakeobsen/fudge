// OAuth sign-in through a relay (SPEC-056): the client asks the app (faked here) for the request's redirect and for
// sign-in, makes the PKCE values itself, and passes the app's refusals on. The second half runs the real
// @raycast/utils (the pinned devDependency) against Fudge's API module, as an extension bundles it.

import assert from "node:assert/strict";
import Module, { createRequire } from "node:module";
import { after, afterEach, test } from "node:test";
import { createElement as h } from "react";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";
import { codeChallenge, codeVerifier, explainRenderError, signInOffMessage, storedTokens } from "../src/api/oauth.ts";
import { NavigationRoot } from "../src/api/navigation.ts";
import { createRoot } from "../src/renderer/root.ts";
import { mount } from "./support/mount.ts";

const api = createApiModule() as Record<string, any>;
const { OAuth, Detail } = api;

const relay = "https://relay.example";
const redirectURI = "http://127.0.0.1:5000/oauth/callback/abc";

type Handler = (params: any) => unknown;

/** Answers the worker's calls as the app would, from `handlers`; a thrown error becomes the call's error. */
function fakeApp(handlers: Record<string, Handler>): RpcRequest[] {
    const calls: RpcRequest[] = [];
    connect((request) => {
        calls.push(request);
        setImmediate(async () => {
            const handler = handlers[request.method];
            if (!handler) return settle(request.id, undefined, `no fake for ${request.method}`);
            try {
                settle(request.id, await handler(request.params));
            } catch (error) {
                settle(request.id, undefined, (error as Error).message);
            }
        });
    });
    return calls;
}
afterEach(() => connect(null));

/** The app with sign-in on and GitHub's request prepared, keeping tokens in memory. */
function signedInApp(tokens = new Map<string, unknown>()) {
    return fakeApp({
        "oauth.prepare": ({ endpoint }) => {
            if (endpoint !== "https://github.oauth.raycast.com/authorize") throw new Error("Fudge can't sign in to X yet.");
            return { provider: "github", authorizeURL: `${relay}/github/authorize`, redirectURI };
        },
        "oauth.tokens.get": ({ providerId }) => tokens.get(providerId) ?? null,
        "oauth.tokens.set": ({ providerId, tokens: set }) => void tokens.set(providerId, set),
        "oauth.tokens.remove": ({ providerId }) => void tokens.delete(providerId),
    });
}

test("an OAuth client can be built with every redirect method", () => {
    const methods = ["Web", "App", "AppURI", "ClientIdMetadataDocument"];
    assert.deepEqual(
        methods.map((name) => OAuth.RedirectMethod[name]),
        ["web", "app", "appURI", "clientIdMetadataDocument"],
    );
    for (const name of methods) {
        const client = new OAuth.PKCEClient({
            redirectMethod: OAuth.RedirectMethod[name],
            providerName: "GitHub",
            providerIcon: "github.png",
            description: "Connect your GitHub account",
        });
        assert.ok(client instanceof OAuth.PKCEClient);
        assert.equal(client.redirectMethod, OAuth.RedirectMethod[name]);
        assert.equal(client.providerId, "github", "the provider's name, lowercased");
    }
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "X", providerId: "custom" });
    assert.equal(client.providerId, "custom");
});

test("a PKCE verifier has 43–128 unreserved characters, and its challenge is S256", () => {
    for (const length of [43, 64, 128]) {
        const verifier = codeVerifier(length);
        assert.equal(verifier.length, length);
        assert.match(verifier, /^[A-Za-z0-9\-._~]+$/);
    }
    assert.equal(codeVerifier().length, 64);
    assert.notEqual(codeVerifier(), codeVerifier());
    assert.throws(() => codeVerifier(42), RangeError);
    assert.throws(() => codeVerifier(129), RangeError);
    // RFC 7636, appendix B.
    assert.equal(codeChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
});

test("authorizationRequest points at the relay with OAuthService's parameters", async () => {
    const calls = signedInApp();
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "GitHub" });
    const request = await client.authorizationRequest({
        endpoint: "https://github.oauth.raycast.com/authorize",
        clientId: "raycast-client",
        scope: "repo read:user",
        extraParameters: { actor: "user", state: "ignored" },
    });
    assert.deepEqual(calls[0].params, {
        endpoint: "https://github.oauth.raycast.com/authorize",
        providerName: "GitHub",
        providerId: "github",
    });
    assert.equal(request.redirectURI, redirectURI);
    assert.equal(request.clientId, "raycast-client");
    assert.equal(request.codeChallenge, codeChallenge(request.codeVerifier));
    assert.match(request.state, /^[A-Za-z0-9_-]{22}$/);

    const url = new URL(request.toURL());
    assert.equal(`${url.origin}${url.pathname}`, `${relay}/github/authorize`);
    assert.deepEqual(Object.fromEntries(url.searchParams), {
        client_id: "raycast-client",
        redirect_uri: redirectURI,
        response_type: "code",
        scope: "repo read:user",
        state: request.state,
        code_challenge: request.codeChallenge,
        code_challenge_method: "S256",
        actor: "user",
    });
});

test("while sign-in is off, signing in rejects with the app's message, and the render error says it", async () => {
    fakeApp({
        "oauth.prepare": () => {
            throw new Error(signInOffMessage);
        },
    });
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "GitHub" });
    await assert.rejects(client.authorizationRequest({ endpoint: "https://github.oauth.raycast.com/authorize" }), {
        message: signInOffMessage,
    });
    assert.equal(
        signInOffMessage,
        "Sign-in is off. Turn it on in Fudge's Settings → Sign-in, or use a token in this extension's settings (⌘⇧,).",
    );
    const loop = new Error("Minified React error #482; visit https://react.dev/errors/482 for the full message");
    const other = new Error("Something else broke");
    assert.equal(explainRenderError(other), other);
    assert.equal((explainRenderError(loop) as Error).message, signInOffMessage);
    assert.equal(explainRenderError(loop), loop, "once: a later #482 isn't the sign-in's");
    assert.equal(explainRenderError(other), other);
});

test("authorize hands the app the URL, its state and the provider's prompt, and returns its code", async () => {
    const answers: Record<string, unknown> = {};
    const all = fakeApp({
        "oauth.prepare": () => ({ provider: "github", authorizeURL: `${relay}/github/authorize`, redirectURI }),
        "oauth.authorize": (params) => {
            answers.seen = params;
            return { authorizationCode: "c0de" };
        },
    });
    const client = new OAuth.PKCEClient({
        redirectMethod: OAuth.RedirectMethod.Web,
        providerName: "GitHub",
        providerIcon: "data:image/svg+xml,%3Csvg%2F%3E",
        description: "Connect your GitHub account",
    });
    const request = await client.authorizationRequest({ endpoint: "https://github.oauth.raycast.com/authorize", clientId: "x" });
    assert.deepEqual(await client.authorize(request), { authorizationCode: "c0de" });
    assert.deepEqual(answers.seen, {
        url: request.toURL(),
        state: request.state,
        providerName: "GitHub",
        providerId: "github",
        providerIcon: "data:image/svg+xml,%3Csvg%2F%3E",
        description: "Connect your GitHub account",
    });
    // A URL the extension built itself: the state comes from it.
    await client.authorize({ url: request.toURL() });
    assert.equal((answers.seen as any).state, request.state);
    assert.deepEqual(
        all.map((call) => call.method),
        ["oauth.prepare", "oauth.authorize", "oauth.authorize"],
    );
});

test("tokens are kept by the app per provider, with isExpired from expiresIn", async () => {
    const tokens = new Map<string, any>();
    signedInApp(tokens);
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "GitHub" });
    assert.equal(await client.getTokens(), undefined);
    await client.setTokens({ access_token: "a", refresh_token: "r", expires_in: 3600, scope: ["repo", "user"] });
    const stored = tokens.get("github");
    assert.equal(stored.accessToken, "a");
    assert.equal(stored.refreshToken, "r");
    assert.equal(stored.scope, "repo user", "a scope array is joined");
    assert.equal(stored.providerName, "GitHub");
    assert.equal(stored.relayProvider, undefined, "no relay sign-in from this client");

    const set = await client.getTokens();
    assert.equal(set.accessToken, "a");
    assert.ok(set.updatedAt instanceof Date);
    assert.equal(set.isExpired(), false);
    tokens.set("github", { ...stored, updatedAt: new Date(Date.now() - 3595 * 1000).toISOString() });
    assert.equal((await client.getTokens()).isExpired(), true, "10 seconds early");
    tokens.set("github", { ...stored, expiresIn: undefined });
    assert.equal((await client.getTokens()).isExpired(), false, "never without expiresIn");
    // A provider's `expires_in: 0` counts as not set, so @raycast/utils doesn't refresh on every call.
    await client.setTokens({ access_token: "a", refresh_token: "r", expires_in: 0 });
    assert.equal(tokens.get("github").expiresIn, 0, "stored as given");
    tokens.set("github", { ...tokens.get("github"), updatedAt: new Date(Date.now() - 86_400_000).toISOString() });
    assert.equal((await client.getTokens()).isExpired(), false, "never with expiresIn 0, a day later");

    await client.removeTokens();
    assert.equal(await client.getTokens(), undefined);
    assert.throws(() => storedTokens({}, "GitHub"), /access token/);
});

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

const require = createRequire(import.meta.url);

/** A fresh copy of @raycast/utils: it keeps the access token in module state. */
function freshUtils(): Record<string, any> {
    const path = require.resolve("@raycast/utils");
    delete require.cache[path];
    return require(path) as Record<string, any>;
}

function launch(commandMode: "view" | "no-view") {
    setLaunchContext({
        preferences: {},
        environment: { ...placeholderEnvironment, extensionName: "github", commandName: "search", commandMode },
        launchProps: {},
    });
}

test("with a personal token, OAuthService.github renders after onAuthorize, never signing in", async () => {
    launch("view");
    const calls = signedInApp();
    const { OAuthService, withAccessToken, getAccessToken } = freshUtils();
    const authorized: string[] = [];
    let finishAuthorizing!: () => void;
    const github = OAuthService.github({
        personalAccessToken: "t",
        scope: "repo",
        onAuthorize: ({ token }: { token: string }) =>
            new Promise<void>((resolve) => {
                authorized.push(token);
                finishAuthorizing = resolve;
            }),
    });
    const Command = withAccessToken(github)(() =>
        h(Detail, { markdown: `token ${getAccessToken().token} (${getAccessToken().type})` }),
    );
    let rendered = false;
    const mounted = mount(h(Command)).then((m) => ((rendered = true), m));
    for (let i = 0; i < 50 && authorized.length === 0; i++) await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(authorized, ["t"]);
    assert.equal(rendered, false, "nothing is drawn while onAuthorize runs");
    finishAuthorizing();
    const { first, settle: settled, errors } = await mounted;
    await settled();
    assert.equal(first.view?.props.markdown, "token t (personal)");
    assert.deepEqual(errors, []);
    assert.equal(
        calls.some((call) => call.method === "oauth.prepare"),
        false,
        "a personal token never signs in",
    );
});

test("while sign-in is off, a view command without a token reports the message as its error", async () => {
    launch("view");
    fakeApp({
        "oauth.tokens.get": () => null,
        "oauth.prepare": () => {
            throw new Error(signInOffMessage);
        },
    });
    const { OAuthService, withAccessToken } = freshUtils();
    const Command = withAccessToken(OAuthService.github({ scope: "repo" }))(() => h(Detail, { markdown: "never" }));
    const errors: unknown[] = [];
    const snapshots: unknown[] = [];
    const root = createRoot({
        onRender: (snapshot) => snapshots.push(snapshot),
        onError: (error) => errors.push(explainRenderError(error)),
    });
    root.render(h(NavigationRoot, { root: h(Command), handle: { current: null } }));
    for (let i = 0; i < 100 && errors.length === 0; i++) await new Promise((resolve) => setTimeout(resolve, 10));
    assert.deepEqual(
        errors.map((error) => (error as Error).message),
        [signInOffMessage],
    );
    assert.equal(JSON.stringify(snapshots).includes("never"), false);
    root.unmount();
});
