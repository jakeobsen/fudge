import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { createApiModule } from "../src/api/module.ts";
import { providersFromEnvironment, providersVariable, raycastDomainsVariable } from "../src/api/oauth-table.ts";
import { scanExtension, type SignIn } from "../scripts/compat/extension.ts";
import { resolveString } from "../scripts/compat/scan.ts";
import { raycastDeclarations, vendoredTypes } from "../scripts/raycast-types.ts";
import {
    compatibilityFile,
    compatibilityLine,
    compatibilityText,
    fromReport,
    readCompatibility,
    rememberCompatibility,
    signInTableFromEnvironment,
    signsInThroughRaycast,
    throughRaycastSentence,
    type ScanReport,
    type SignInTable,
} from "../store-extension/src/compatibility.ts";

// SPEC-132 §7: the store warns before install when signing in comes back through raycast.com.

const scratch = mkdtempSync(path.join(tmpdir(), "fudge-sign-in-scan-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const fixture = readFileSync(new URL("./fixtures/oauth-providers.json", import.meta.url), "utf8");
/** The app's table, as the runtime's tests have it, and Raycast's domains as core has them. */
const table: SignInTable = {
    authorizeURLs: providersFromEnvironment(fixture).map((provider) => provider.authorizeURL),
    raycastDomains: ["raycast.com"],
};
const googleTableURL = "https://accounts.google.com/o/oauth2/v2/auth";

/** Scans an extension made of `files` (paths under `src/`) and gives where it signs in. */
async function signIn(files: Record<string, string>): Promise<SignIn> {
    const folder = mkdtempSync(path.join(scratch, "extension-"));
    writeFileSync(path.join(folder, "package.json"), JSON.stringify({ name: "fixture", commands: [{ name: "index" }] }));
    for (const [file, source] of Object.entries(files)) {
        mkdirSync(path.dirname(path.join(folder, "src", file)), { recursive: true });
        writeFileSync(path.join(folder, "src", file), source);
    }
    const result = await scanExtension(folder, {
        api: createApiModule() as Record<string, unknown>,
        declared: raycastDeclarations(vendoredTypes()),
    });
    assert.deepEqual(result.unreadable, []);
    return result.signIn;
}

/** A PKCE client with `method` that signs in at `endpoint` (an expression). */
const pkce = (method: string, endpoint: string, before = "") => `
    import { OAuth } from "@raycast/api";
    ${before}
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.${method}, providerName: "Example" });
    export default async function Command() {
        const request = await client.authorizationRequest({ endpoint: ${endpoint}, clientId: "id", scope: "read" });
        await client.authorize(request);
    }
`;

/** An `OAuthService` with its own Web client that signs in at `authorizeUrl` (an expression). */
const service = (authorizeUrl: string, before = "") => `
    import { OAuth } from "@raycast/api";
    import { OAuthService } from "@raycast/utils";
    ${before}
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "Example" });
    export const provider = new OAuthService({
        client,
        clientId: "id",
        scope: "read",
        authorizeUrl: ${authorizeUrl},
        tokenUrl: "https://auth.example.com/token",
    });
`;

const warns = (found: SignIn) => signsInThroughRaycast(found, table);

/** `fromReport`'s `signsInThroughRaycast`, judged by `lists` (the worker's own unless given). */
function throughRaycast(report: ScanReport, lists?: SignInTable): boolean {
    const result = fromReport(report, lists);
    assert.ok(!result.notChecked);
    return result.signsInThroughRaycast;
}

test("the scan's fixtures: Web with its own URL warns, the table's doesn't, a preference's does, AppURI never", async () => {
    const own = await signIn({ "index.ts": pkce("Web", '"https://auth.example.com/oauth/authorize"') });
    assert.deepEqual(own, { methods: ["Web"], authorizeURLs: ["https://auth.example.com/oauth/authorize"], unresolved: false });
    assert.equal(warns(own), true, "Web with an own URL");

    const tableOnly = await signIn({ "index.ts": service(JSON.stringify(googleTableURL)) });
    assert.deepEqual(tableOnly, { methods: ["Web"], authorizeURLs: [googleTableURL], unresolved: false });
    assert.equal(warns(tableOnly), false, "Web with the table's URL takes the relay path");

    const both = await signIn({
        "index.ts": pkce("Web", '"https://auth.example.com/oauth/authorize"'),
        "google.ts": service(JSON.stringify(googleTableURL)),
    });
    assert.deepEqual(both.authorizeURLs, ["https://accounts.google.com/o/oauth2/v2/auth", "https://auth.example.com/oauth/authorize"]);
    assert.equal(warns(both), true, "Web with both: one own URL is enough");

    const preference = await signIn({
        "index.ts": service(
            "getPreferenceValues<{ authorizeUrl: string }>().authorizeUrl",
            'import { getPreferenceValues } from "@raycast/api";',
        ),
    });
    assert.deepEqual(preference, { methods: ["Web"], authorizeURLs: [], unresolved: true });
    assert.equal(warns(preference), true, "a URL from a preference is never the table's, whose URLs are fixed");

    const appURI = await signIn({ "index.ts": pkce("AppURI", '"https://auth.example.com/oauth/authorize"') });
    assert.deepEqual(appURI, { methods: ["AppURI"], authorizeURLs: ["https://auth.example.com/oauth/authorize"], unresolved: false });
    assert.equal(warns(appURI), false, "AppURI comes straight back");
    assert.equal(warns(await signIn({ "index.ts": pkce("App", '"https://auth.example.com/authorize"') })), false, "so does App");

    const builtIn = await signIn({
        "index.ts": `import { OAuthService } from "@raycast/utils";\nexport const github = OAuthService.github({ scope: "repo" });\n`,
    });
    assert.deepEqual(builtIn, { methods: [], authorizeURLs: [], unresolved: false }, "OAuthService only: no method of its own");
    assert.equal(warns(builtIn), false);
});

test("authorize URLs are resolved from constants across the extension's files, templates and sums", async () => {
    const config = `export const BASE = "https://auth.example.com";\nexport const AUTHORIZE_URL = \`\${BASE}/oauth/authorize\`;\n`;
    assert.deepEqual(
        (await signIn({ "config.ts": config, "index.ts": pkce("Web", "AUTHORIZE_URL", 'import { AUTHORIZE_URL } from "./config";') }))
            .authorizeURLs,
        ["https://auth.example.com/oauth/authorize"],
        "a constant in another file, itself a template of another",
    );
    assert.deepEqual(
        (await signIn({ "index.ts": pkce("Web", 'BASE + "/authorize?prompt=" + "consent"', 'const BASE = "https://a.example";') }))
            .authorizeURLs,
        ["https://a.example/authorize?prompt=consent"],
        "a sum",
    );
    assert.deepEqual(
        (await signIn({ "index.ts": service("authorizeUrl", 'const authorizeUrl = "https://b.example/authorize";').replace(
            "authorizeUrl: authorizeUrl,",
            "authorizeUrl,",
        ) })).authorizeURLs,
        ["https://b.example/authorize"],
        "a shorthand property",
    );
    const unresolved = async (files: Record<string, string>) => (await signIn(files)).unresolved;
    assert.equal(await unresolved({ "index.ts": pkce("Web", "`https://${host}/authorize`", "declare const host: string;") }), true, "a template with an unknown value");
    assert.equal(
        await unresolved({
            "a.ts": 'export const URL_A = "https://a.example";\nexport const AUTH = URL_A;\n',
            "index.ts": pkce("Web", "AUTH", 'import { AUTH } from "./a";'),
            "b.ts": 'export const AUTH = "https://b.example";\n',
        }),
        true,
        "a name with two values across files",
    );
    const passed = `
        import { OAuth } from "@raycast/api";
        const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "Example" });
        export async function signIn(options: OAuth.AuthorizationRequestOptions) {
            await client.authorizationRequest(options);
            await client.authorizationRequest({ ...options, scope: "read" });
        }
    `;
    assert.deepEqual(await signIn({ "index.ts": passed }), { methods: ["Web"], authorizeURLs: [], unresolved: true }, "an argument the scan can't read");
});

test("resolveString reads literals and their escapes, and gives up on anything it can't tell", () => {
    const constants = new Map([
        ["A", ['"https://a.example"']],
        ["SELF", ["SELF"]],
        ["TWO", ['"x"', '"y"']],
    ]);
    assert.equal(resolveString('"https:\\/\\/a.example\\u002Fx"', constants), "https://a.example/x");
    assert.equal(resolveString("('https://' + \"b.example\")", constants), "https://b.example");
    assert.equal(resolveString("`${A}/authorize`", constants), "https://a.example/authorize");
    assert.equal(resolveString("SELF", constants), undefined, "a cycle ends");
    assert.equal(resolveString("TWO", constants), undefined);
    assert.equal(resolveString("UNKNOWN", constants), undefined);
    assert.equal(resolveString("config.authorizeUrl", constants), undefined);
    assert.equal(resolveString("flag ? A : TWO", constants), undefined);
    assert.equal(resolveString('"\\q"', constants), undefined, "an escape it doesn't know");
});

test("signsInThroughRaycast: Web and a URL neither the table's nor on Raycast's hosts, by the app's lists", () => {
    const web = (...authorizeURLs: string[]) => ({ methods: ["Web"], authorizeURLs, unresolved: false });
    assert.equal(signsInThroughRaycast(web("https://auth.example.com/authorize"), table), true);
    assert.equal(signsInThroughRaycast(web(googleTableURL), table), false, "the table's exact URL");
    assert.equal(
        signsInThroughRaycast(web(`${googleTableURL}?x=1`), table),
        true,
        "only the exact URL is the table's, as oauth.prepare matches it",
    );
    for (const raycast of [
        "https://notion.oauth-proxy.raycast.com/authorize",
        "https://apple-music-oauth.raycast.com/authorize",
        "https://www.raycast.com/oauth/authorize",
        "https://oauth.raycast.com/v1/authorize/x",
        "https://RAYCAST.com./x",
    ]) {
        assert.equal(signsInThroughRaycast(web(raycast), table), false, `${raycast} is Raycast's, which is refused`);
        assert.equal(signsInThroughRaycast(web(raycast), { ...table, raycastDomains: [] }), true, "the domains are the app's list");
    }
    assert.equal(signsInThroughRaycast(web("not a URL"), table), true, "a URL that doesn't read is no table's or Raycast's");
    assert.equal(signsInThroughRaycast(web(), table), false, "no authorize URL: nothing signs in through a redirect");
    assert.equal(signsInThroughRaycast({ methods: ["Web"], authorizeURLs: [], unresolved: true }, table), true);
    assert.equal(signsInThroughRaycast({ methods: ["App", "AppURI"], authorizeURLs: [], unresolved: true }, table), false);
    for (const bad of [undefined, null, "Web", { methods: "Web", authorizeURLs: [], unresolved: true }, { methods: ["Web"], unresolved: true }]) {
        assert.equal(signsInThroughRaycast(bad, table), false, JSON.stringify(bad));
    }
});

test("the table and Raycast's domains are the ones the app hands the worker", () => {
    const previous = { providers: process.env[providersVariable], domains: process.env[raycastDomainsVariable] };
    try {
        process.env[providersVariable] = fixture;
        process.env[raycastDomainsVariable] = '["raycast.com"]';
        assert.deepEqual(signInTableFromEnvironment(), table);
        const report: ScanReport = {
            supported: false,
            gaps: [],
            unreadable: [],
            signIn: { methods: ["Web"], authorizeURLs: ["https://www.raycast.com/oauth/authorize"], unresolved: false },
        };
        assert.equal(throughRaycast(report), false, "fromReport reads them by default");
        delete process.env[raycastDomainsVariable];
        assert.equal(throughRaycast(report), true);
    } finally {
        for (const [variable, value] of [
            [providersVariable, previous.providers],
            [raycastDomainsVariable, previous.domains],
        ] as const) {
            if (value === undefined) delete process.env[variable];
            else process.env[variable] = value;
        }
    }
});

test("the confirmation and the detail say signing in goes through raycast.com, in place of the server's sentence", () => {
    assert.equal(throughRaycastSentence, "Signing in goes through raycast.com. The extension's author chose that, so Fudge can't change it.");
    const report = (signIn: ScanReport["signIn"], ...gaps: { api: string; byDesign?: string }[]): ScanReport => ({
        supported: false,
        gaps: [{ api: "OAuth.RedirectMethod.Web", byDesign: "OAuth" }, ...gaps],
        unreadable: [],
        signIn,
    });
    const through = report({ methods: ["Web"], authorizeURLs: ["https://auth.example.com/authorize"], unresolved: false });
    assert.equal(compatibilityLine(fromReport(through, table)), throughRaycastSentence);
    assert.equal(compatibilityText(fromReport(through, table)), throughRaycastSentence);
    const withMore = report(through.signIn, { api: "AI.ask", byDesign: "AI" }, { api: "Clipboard.read" });
    assert.equal(
        compatibilityLine(fromReport(withMore, table)),
        "Not compatible with Fudge: this extension uses Raycast AI, which Fudge doesn't support. Commands that use it won't work. It also uses things Fudge doesn't have yet: Clipboard.read. Some of its commands may not work. " +
            throughRaycastSentence,
    );
    assert.equal(compatibilityText(fromReport(withMore, table)), `Not compatible: Raycast AI. Missing: \`Clipboard.read\`. ${throughRaycastSentence}`);

    const app = report({ methods: ["App"], authorizeURLs: ["https://auth.example.com/authorize"], unresolved: false });
    assert.equal(throughRaycast(app, table), false);
    assert.equal(
        compatibilityLine(fromReport(app, table)),
        "This extension signs in with OAuth, which works if the sign-in server chosen in Settings → Sign-in supports its provider.",
        "App: the server's sentence, as before",
    );
    assert.equal(compatibilityText(fromReport(app, table)), "Signs in with OAuth (Settings → Sign-in)");
    assert.equal(throughRaycast(report(undefined), table), false, "a report without signIn");
});

test("the cache keeps the new field, and a file or entry from before it is scanned again", async () => {
    const support = mkdtempSync(path.join(scratch, "support-"));
    const tree = "1".repeat(40);
    const result = { notSupported: [], missing: [], signsIn: true, signsInThroughRaycast: true, unreadable: false };
    await rememberCompatibility(support, "s", tree, result);
    assert.deepEqual((await readCompatibility(support, "s")).get(tree), result);
    const written = JSON.parse(await readFile(compatibilityFile(support), "utf8")) as Record<string, unknown>;
    assert.equal(written.version, 2);

    const { signsInThroughRaycast: _, ...before } = result;
    await writeFile(compatibilityFile(support), JSON.stringify({ scanner: "s", trees: { [tree]: result } }));
    assert.deepEqual(await readCompatibility(support, "s"), new Map(), "a file without the version");
    await writeFile(compatibilityFile(support), JSON.stringify({ version: 1, scanner: "s", trees: { [tree]: result } }));
    assert.deepEqual(await readCompatibility(support, "s"), new Map(), "an older version");
    await writeFile(compatibilityFile(support), JSON.stringify({ version: 2, scanner: "s", trees: { [tree]: before } }));
    assert.deepEqual(await readCompatibility(support, "s"), new Map(), "an entry without the field");
    await writeFile(compatibilityFile(support), JSON.stringify({ version: 2, scanner: "s", trees: { [tree]: { ...before, signsInThroughRaycast: "yes" } } }));
    assert.deepEqual(await readCompatibility(support, "s"), new Map(), "a field that isn't a boolean");
});
