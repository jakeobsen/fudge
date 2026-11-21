// OAuth within D-50: the client can be built and asked for tokens; only signing in fails (SPEC-054). The second half
// runs the real @raycast/utils (the pinned devDependency) against Fudge's API module, as an extension bundles it.

import assert from "node:assert/strict";
import Module, { createRequire } from "node:module";
import { after, test } from "node:test";
import { createElement as h } from "react";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";
import { explainRenderError, signInMessage } from "../src/api/oauth.ts";
import { NavigationRoot } from "../src/api/navigation.ts";
import { createRoot } from "../src/renderer/root.ts";
import { mount } from "./support/mount.ts";

const api = createApiModule() as Record<string, any>;
const { OAuth, Detail } = api;

test("an OAuth client can be built with every redirect method, and holds no tokens", async () => {
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
        assert.equal(client.providerName, "GitHub");
        assert.equal(client.providerId, "github", "the provider's name, lowercased");
        assert.equal(await client.getTokens(), undefined);
        await client.setTokens({ accessToken: "ignored" });
        assert.equal(await client.getTokens(), undefined, "nothing is stored");
        await client.removeTokens();
    }
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "X", providerId: "custom" });
    assert.equal(client.providerId, "custom");
});

test("signing in fails, saying to use a token from the extension's settings", async () => {
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "GitHub" });
    await assert.rejects(client.authorizationRequest({ endpoint: "https://example.com", clientId: "x", scope: "" }), {
        message: signInMessage,
    });
    await assert.rejects(client.authorize({ url: "https://example.com" }), { message: signInMessage });
    assert.equal(
        signInMessage,
        "Fudge doesn't support signing in with OAuth. If this extension takes a token in its settings (⌘⇧,), use that.",
    );
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

test("OAuthService.github builds, and withAccessToken renders with a token, after onAuthorize, without Suspense", async () => {
    launch("view");
    const { OAuthService, withAccessToken, getAccessToken } = freshUtils();
    const authorized: string[] = [];
    let finishAuthorizing!: () => void;
    const github = OAuthService.github({
        personalAccessToken: "t",
        scope: "repo",
        // GitHub's own setup passes one; withAccessToken suspends on it (React.use), even with a token.
        onAuthorize: ({ token }: { token: string }) =>
            new Promise<void>((resolve) => {
                authorized.push(token);
                finishAuthorizing = resolve;
            }),
    });
    function Search() {
        return h(Detail, { markdown: `token ${getAccessToken().token} (${getAccessToken().type})` });
    }
    const Command = withAccessToken(github)(Search);

    // Mounted as the worker mounts a command: no <Suspense> anywhere. It suspends on the client's tokens, then on
    // onAuthorize, and sends nothing meanwhile.
    let rendered = false;
    const mounted = mount(h(Command)).then((m) => ((rendered = true), m));
    for (let i = 0; i < 50 && authorized.length === 0; i++) await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(authorized, ["t"]);
    assert.equal(rendered, false, "nothing is drawn while onAuthorize runs");
    finishAuthorizing();
    const { first, settle, errors } = await mounted;
    await settle();
    assert.equal(first.view?.type, "Detail");
    assert.equal(first.view?.props.markdown, "token t (personal)");
    assert.deepEqual(errors, []);
});

test("without a token, a no-view command fails with the sign-in message", async () => {
    launch("no-view");
    const { OAuthService, withAccessToken } = freshUtils();
    let ran = false;
    const run = withAccessToken(OAuthService.github({ scope: "repo" }))(async () => {
        ran = true;
    });
    await assert.rejects(run({}), { message: signInMessage });
    assert.equal(ran, false);
});

test("without a token, a view command reports the sign-in message as its error", async () => {
    launch("view");
    const { OAuthService, withAccessToken } = freshUtils();
    const Command = withAccessToken(OAuthService.github({ scope: "repo" }))(() => h(Detail, { markdown: "never" }));
    const errors: unknown[] = [];
    const snapshots: unknown[] = [];
    // As the worker reports a view command's render errors.
    const root = createRoot({
        onRender: (snapshot) => snapshots.push(snapshot),
        onError: (error) => errors.push(explainRenderError(error)),
    });
    root.render(h(NavigationRoot, { root: h(Command), handle: { current: null } }));
    for (let i = 0; i < 50 && errors.length === 0; i++) await new Promise((resolve) => setTimeout(resolve, 10));
    assert.deepEqual(
        errors.map((error) => (error as Error).message),
        [signInMessage],
    );
    assert.equal(JSON.stringify(snapshots).includes("never"), false);
    root.unmount();
});

test("only React's suspend-loop error, after a refused sign-in, is explained", async () => {
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "GitHub" });
    await assert.rejects(client.authorize({ url: "https://example.com" }));
    const loop = new Error("Minified React error #482; visit https://react.dev/errors/482 for the full message");
    assert.equal((explainRenderError(loop) as Error).message, signInMessage);
    const other = new Error("Something else broke");
    assert.equal(explainRenderError(other), other);
    assert.equal(explainRenderError("not an error"), "not an error");
});
