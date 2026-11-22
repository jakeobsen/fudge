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
    isRaycastDomainHost,
    needsDecision,
    providersFromEnvironment,
    raycastDomainsFromEnvironment,
    raycastDomainsVariable,
    redirectedMessage,
    rewriteFetch,
    route,
    type ServerAnswer,
} from "../src/api/oauth-fetch.ts";
import { signInOffMessage } from "../src/api/oauth.ts";
import { noticeOf } from "../src/notice.ts";

const fixture = readFileSync(new URL("./fixtures/oauth-providers.json", import.meta.url), "utf8");
// Raycast's domains, as the app always hands them to the host (core's `OAuthProviders.raycastDomains`).
process.env[raycastDomainsVariable] = '["raycast.com"]';
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
        [
            "github",
            "github",
            "linear",
            "slack",
            "asana",
            "google",
            "atlassian",
            "atlassian",
            "zoom",
            "zoom",
            "notion",
            "notion",
            "todoist",
            "basecamp",
            "gumroad",
            "moneybird",
            "freeagent",
            "mollie",
            "plane",
            "homey",
            "figma",
        ],
    );
    assert.deepEqual(providersFromEnvironment("not json"), []);
    assert.deepEqual(providersFromEnvironment('{"id":"x"}'), []);
    assert.deepEqual(providersFromEnvironment('[{"id":"x"}]'), [], "entries without every URL are dropped");
    assert.deepEqual(providersFromEnvironment(undefined), []);
});

test("exactly the table's token and refresh requests go to the relay", async () => {
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
        // Raycast's Jira and Zoom proxies, as the store's Jira and Zoom extensions set them (FUD-137).
        ["https://jira.oauth.raycast.com/token", "atlassian/token", "authorization_code"],
        ["https://jira.oauth.raycast.com/refresh-token", "atlassian/refresh-token", "refresh_token"],
        ["https://zoom.oauth.raycast.com/token", "zoom/token", "authorization_code"],
        ["https://zoom.oauth.raycast.com/refresh-token", "zoom/refresh-token", "refresh_token"],
        // These refresh at their token URL: the grant decides.
        ["https://oauth2.googleapis.com/token", "google/token", "authorization_code"],
        ["https://oauth2.googleapis.com/token", "google/refresh-token", "refresh_token"],
        ["https://auth.atlassian.com/oauth/token", "atlassian/token", "authorization_code"],
        ["https://auth.atlassian.com/oauth/token", "atlassian/refresh-token", "refresh_token"],
        ["https://zoom.us/oauth/token", "zoom/token", "authorization_code"],
        ["https://zoom.us/oauth/token", "zoom/refresh-token", "refresh_token"],
        // Raycast's other sign-in addresses that store extensions use (FUD-166). Notion's extension refreshes at its
        // token URL, which isn't the entry's refresh URL, so it stays /token, and the relay's /token takes the refresh.
        ["https://notion.oauth.raycast.com/token", "notion/token", "authorization_code"],
        ["https://notion.oauth.raycast.com/token", "notion/token", "refresh_token"],
        ["https://notion.oauth.raycast.com/refresh-token", "notion/refresh-token", "refresh_token"],
        // Todoist's proxy refreshes at its token URL: the grant decides.
        ["https://todoist.oauth-proxy.raycast.com/token", "todoist/token", "authorization_code"],
        ["https://todoist.oauth-proxy.raycast.com/token", "todoist/refresh-token", "refresh_token"],
        // The extensions' own apps on Raycast's shared proxy.
        ["https://oauth.raycast.com/v1/token/iJqg8WNq5LKdm75IypyhlNY97FAffYDPq76nQ4XfEjlPF1ZwUq4mSlldpwhViz46X_biMUY6MOvB2ytQ8xP2s3y0dJ142g_0ywNHkuKpPYhs-nnzcXDFsfcDMMqvuDQNXDAte_jVRkXsKRD2r7o4Ucc", "github/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/token/iJqg8WNq5LKdm75IypyhlNY97FAffYDPq76nQ4XfEjlPF1ZwUq4mSlldpwhViz46X_biMUY6MOvB2ytQ8xP2s3y0dJ142g_0ywNHkuKpPYhs-nnzcXDFsfcDMMqvuDQNXDAte_jVRkXsKRD2r7o4Ucc", "github/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/Dcc7jqB2FwkuyDVKpiBI71VgY3qKbGWZxbmrHn9OHUvNSu-X63-RQgOGSgpb2jsY8IC-mVjl7Zrn1M_LvTt4VUgWRTLnf6Pf5dUJZ1T1clSJBps1mD0Vs00412TZofmQulfQMErWB5du-_2fACC_Rfe7xYY-", "notion/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/token/Dcc7jqB2FwkuyDVKpiBI71VgY3qKbGWZxbmrHn9OHUvNSu-X63-RQgOGSgpb2jsY8IC-mVjl7Zrn1M_LvTt4VUgWRTLnf6Pf5dUJZ1T1clSJBps1mD0Vs00412TZofmQulfQMErWB5du-_2fACC_Rfe7xYY-", "notion/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/wMaXr3BdE5QWGZQ_RE_7GyB37_wTuBYOg_9C7CxiqtwHYOELsCyxDKiOshV4mPWXj9NZ_cZ9-dLIkELMnqbN08GDHCnmBp0i2Z950v2kWuOU88VMf3YxkiQAxj5HiAGYW9ceuj9hTDeIBYyBIXciFpDsR6WPhJAjJsHqvz2j8IQQe28efSJFi18", "basecamp/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/refresh-token/zUVueWjJBw5e_3E04mUmut6L1LiT8fa6FdubGOtITFX_Gx3nilkwNIUISui62gZbvu6yXqDWHy7UKdM9R5RXPUQu-9q-zEsgnK2NhTktNwp2wmGT60Rg-mXFUUd_jg4fwBzIXj5cOBculalOYYodpTWi8bJJBp60XCxA_0C4hctAhKftD8soF-A", "basecamp/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/cAfVd74pOuU0WIWMymDxtIHXg2c1Hai7gBXmE4DZGFk4tRZczsTQlJzrFzbwSYE3TmlIEse4FP4uUy9EYX35zYfsI0_2mfKmLudJ4wsC-8zUsEXhJwnIn11TJmNeH2bpiWxqQpU-K4Q", "gumroad/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/refresh-token/-8K39Rwy5HY5-DzNTOVLTMvKH6EQVd5E50z9mvLJ4bahXJu2susPq_DcGFFUYrhctLgTTXZLhmYRvlBnpIaGuxPDB7QTscbBrsz63tOA4RvPXoqJYh4JKtyUgQMAheFWBKh6gvNI08Q", "gumroad/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/HkdQIb7W7JlFwNFCj2yL6zDPvJHb-vnTCrL_iPlT_K77Z-hQHyRJ-iiLSrkfjNta8Yys7_qRGKHBiAIVVt5GnqiV-VvvegeT9INJ24TrXTHk_P2MT0GOTd8fD9ogDuOgdPyMahi1mePSjhGKHTsBuPloYZFqNnDSzr4_ioxJBQ", "moneybird/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/refresh-token/66Tt7sCc6O70T4V3Rf_Dr4B941f08fkyizdDhimTODW0M7niNRllwvyk7FLX3XLaj0WNAWZBeOG1fZ8E1aTYWQR8ThljnyaUy3zS68Ocd5oxI6p4SUY7q2oIs_IauacmW75epq8Mn-mrdcpnmpuL19R7iPHgFy3FBS1ZeHRbSg", "moneybird/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/csqaHeGaTfTpistIum6eBy7DDrJjcz7Z-FmW_HuU4Dsa3r-AhgMCGcEWYUCLR3k-5-PirrX1ilceu4WfRqUQlyCSEiYqzkZkIIKyx5n7khRbIe99FHiEBtENFXUZRz8", "freeagent/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/refresh-token/wg1eYlPV441y6BfHcmZi19x61W2tqw045Dup4C6M8VgERbxtFByj1J97OeYVaiPHbYWoLz3nNnZ3nzXoMnZbqP6EhVYkT8eJefM79ey5sQLcdRL9vGnlBsLMqaB_Ylg", "freeagent/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/5p7_7xQdzkXilZdhppv_or2B9wwd0Sm7Fx0khb74h_MHnro7AO5w4tr9-aj5vJe4C0NnlLsV1Onr24ndgmFR5J_yRpV6b_hD8BzYSg6lcH1Q7s-1DUfZ0JFlZjE2nF0j-vunQ34iLi8d8w", "mollie/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/refresh-token/hiXK17eErlQSoxjH5w0qTI3fjCmQt-Qw7TWqV0PhNEi6xvSqLjnklSkwNy7D0g67FwQAfXV3udahWqjl2tFPa5b7zO_rFNtJQTvPto9gQMrQDdQFFC6VvdGZstEn8K2juivJh2SwmBzBfg", "mollie/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/9KXLatvC9QrbuSafABDqcnA8IZW-JXwd4FF4CvZ-C6LFXfbl8FONXyjGuaO1n2XEFIW6bvDFFWDKH5IB_9gupDVVPiAHt5_mNmQJTQ_OmF7AYcKe6fF3I13O_hYIOETpCPknFn9ww9arA93J2knoGIWRSE-FFoVB2_lBGL8xP8FaRaj8_S6M-fsKUOg1YyyOFaK6dIIN5LF8i6P5J8y_L8Q6hWu4ZyyxmLCKHmEyPY9uoK-6ZZ27W0LMIrNzSHTS", "plane/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/refresh-token/dERRhlRqcHTtXPJLaZZqs7h8JYsRPZrQeWpVvNN_5F9qd_Z6Hb1q6xr_iVeLUmKBj9Ewk3xHAuADSKCpQ1fb0rJq07vziFLkate0VW2zkV0a-xfj23KBoVM2y50aA4geUo7XQT4PS0MKFBIt44ZaD0QRnr3gdZIf37xWollM66pK35YAmuIgo4uFDFJnj1-A1zJ8FvuYL16tHK5qO4nK6SBKE-AktYpraqpziJUINAwN6ByKe_JO1MdvtGGeMb-5", "plane/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/7EXpLgXJ1PDijhpr-BiJe3CVd8JGSZsST-oAdflCaTWLJuEE0vRMulR8bHGX4SRrBJWgXgZKC4A0b2jF90p7QELwCoXdZQnHrigsXbfLOolG1PwDUbDNB971f6EllEs4ndcak66nGw8", "homey/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/refresh-token/ptpJtGSqQUGUt9zDDZGzv4iW-Vn7965_rjjtPM3sOeRSXhXL_GIF4ZrNDUR21AhW5zg-MUeZuMdoKG1co7oEkas3HYBat5-W4rLPUMScN0yOM5zlapM6xD-ryNobzZ55v22lc_5qXKo", "homey/refresh-token", "refresh_token"],
        ["https://oauth.raycast.com/v1/token/rsuQtsavqnjuxmA3vCYSGa3E-D8_ruhzY4OqJIOA7aB4_wGaFh2WE0mQc_uMZ7E5Nk8-pAeW3JXE3WlUfgqu_-zNiM4yWU7i_z2-u0pO8HJFh7_H6ohVBh8fcDpk64nT", "figma/token", "authorization_code"],
        ["https://oauth.raycast.com/v1/refresh-token/qJfyXOqhjDouaj06_54vl2O3NoIfY36R_-OOExXZNAS073Bih0aeNaHLO9xEpW6lbooqWCpT6zO7zLvbTx1MtXF2dU5d4B_of5d05Yxh27JIAPHG0uBw7fINhej_ViQ-sbE", "figma/refresh-token", "refresh_token"],
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
        // Lookalikes of Raycast's Jira and Zoom proxies are other hosts.
        ["https://jira.oauth.raycast.com.evil.test/token", post("authorization_code")],
        ["https://zoom.oauth.raycast.com.evil.test/refresh-token", post("refresh_token")],
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
    await wrapped("https://oauth.raycast.com/v1/token/rsuQtsavqnjuxmA3vCYSGa3E-D8_ruhzY4OqJIOA7aB4_wGaFh2WE0mQc_uMZ7E5Nk8-pAeW3JXE3WlUfgqu_-zNiM4yWU7i_z2-u0pO8HJFh7_H6ohVBh8fcDpk64nT", post("authorization_code", { code: "c" }));
    assert.equal(sent.at(-1)!.url, "https://relay.example/base/figma/token", "nor does the shared proxy");
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
            ["https://x.oauth.raycast.com/token", post("authorization_code")],
            // FUD-166's addresses only exactly: an unknown blob on the shared proxy, a path added, or another scheme.
            ["https://oauth.raycast.com/v1/token/unknown", post("authorization_code")],
            ["https://oauth.raycast.com/v1/token/cAfVd74pOuU0WIWMymDxtIHXg2c1Hai7gBXmE4DZGFk4tRZczsTQlJzrFzbwSYE3TmlIEse4FP4uUy9EYX35zYfsI0_2mfKmLudJ4wsC-8zUsEXhJwnIn11TJmNeH2bpiWxqQpU-K4Q/x", post("authorization_code")],
            ["http://todoist.oauth-proxy.raycast.com/token", post("authorization_code")],
            ["https://todoist.oauth-proxy.raycast.com/token/x", post("authorization_code")],
            ["https://oauth.raycast.com/v1/token/9KXLatvC9QrbuSafABDqcnA8IZW-JXwd4FF4CvZ-C6LFXfbl8FONXyjGuaO1n2XEFIW6bvDFFWDKH5IB_9gupDVVPiAHt5_mNmQJTQ_OmF7AYcKe6fF3I13O_hYIOETpCPknFn9ww9arA93J2knoGIWRSE-FFoVB2_lBGL8xP8FaRaj8_S6M-fsKUOg1YyyOFaK6dIIN5LF8i6P5J8y_L8Q6hWu4ZyyxmLCKHmEyPY9uoK-6ZZ27W0LMIrNzSHTS/x", post("authorization_code")],
            ["http://oauth.raycast.com/v1/token/7EXpLgXJ1PDijhpr-BiJe3CVd8JGSZsST-oAdflCaTWLJuEE0vRMulR8bHGX4SRrBJWgXgZKC4A0b2jF90p7QELwCoXdZQnHrigsXbfLOolG1PwDUbDNB971f6EllEs4ndcak66nGw8", post("authorization_code")],
            ["https://oauth.raycast.com/v1/refresh-token/unknown", post("refresh_token")],
            // Only the Jira and Zoom proxies' exact token and refresh URLs, over https, go to the relay.
            ["https://jira.oauth.raycast.com/token/x", post("authorization_code")],
            ["http://jira.oauth.raycast.com/token", post("authorization_code")],
            ["https://jira.oauth.raycast.com/authorize", undefined],
            ["https://zoom.oauth.raycast.com/token/x", post("authorization_code")],
            ["http://zoom.oauth.raycast.com/refresh-token", post("refresh_token")],
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
            const off = await wrapped("https://github.oauth.raycast.com/token", post("authorization_code")).catch(
                (error: unknown) => error,
            );
            assert.deepEqual(noticeOf(off), { notice: "signInOff", message: signInOffMessage });
            // The providers' own token URLs, and everything else, go where they were going.
            await wrapped("https://oauth2.googleapis.com/token", post("refresh_token"));
            await wrapped("https://api.github.com/user");
            assert.deepEqual(
                sent.map((request) => request.url),
                ["https://oauth2.googleapis.com/token", "https://api.github.com/user"],
            );
        } else {
            // Refused with sign-in on: Fudge never sends there, which is a failure, not a notice.
            const proxy = await wrapped("https://github.oauth.raycast.com/anything-else", post("authorization_code")).catch(
                (error: unknown) => error,
            );
            assert.equal(noticeOf(proxy), undefined);
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

// SPEC-132 §2 step 5: token and refresh grants to any of Raycast's hosts are refused, by the one definition core hands
// over (`FUDGE_RAYCAST_DOMAINS`); every request to the proxies stays refused, and a plain GET to raycast.com doesn't.

const raycastDomains = ["raycast.com"];

test("Raycast's hosts are its domains and every host under them, read from the app's variable", () => {
    assert.equal(raycastDomainsVariable, "FUDGE_RAYCAST_DOMAINS");
    assert.deepEqual(raycastDomainsFromEnvironment('["raycast.com"]'), ["raycast.com"]);
    assert.deepEqual(raycastDomainsFromEnvironment('["Raycast.COM", 3, ""]'), ["raycast.com"]);
    for (const bad of ["not json", '{"x":1}', ""]) assert.deepEqual(raycastDomainsFromEnvironment(bad), []);
    const saved = process.env[raycastDomainsVariable];
    delete process.env[raycastDomainsVariable];
    try {
        assert.deepEqual(raycastDomainsFromEnvironment(), [], "a missing variable is an empty list");
    } finally {
        process.env[raycastDomainsVariable] = saved;
    }
    for (const host of [
        "raycast.com",
        "www.raycast.com",
        "WWW.Raycast.COM.",
        "raycast.com..",
        "x.oauth.raycast.com",
        "x.oauth-proxy.raycast.com",
        "apple-music-oauth.raycast.com",
    ]) {
        assert.ok(isRaycastDomainHost(host, raycastDomains), host);
    }
    for (const host of ["raycast.com.evil.test", "notraycast.com", "evilraycast.com", "example.com", ""]) {
        assert.ok(!isRaycastDomainHost(host, raycastDomains), host);
    }
    assert.ok(!isRaycastDomainHost("www.raycast.com", []), "nothing without the app's list");
});

test("token and refresh grants to any of Raycast's hosts are refused, and only those", () => {
    for (const url of [
        "https://www.raycast.com/oauth/token",
        "https://raycast.com/api/v1/oauth/token",
        "https://WWW.Raycast.COM./oauth/token",
        "https://x.oauth-proxy.raycast.com/token",
        "https://apple-music-oauth.raycast.com/refresh-token",
        "http://www.raycast.com/oauth/token",
    ]) {
        for (const grant of ["authorization_code", "refresh_token"]) {
            assert.equal(route("POST", url, grant, providers, raycastDomains).kind, "refused", `${url} ${grant}`);
        }
        assert.equal(route("POST", url, "client_credentials", providers, raycastDomains).kind, "untouched", url);
        assert.equal(route("POST", url, null, providers, raycastDomains).kind, "untouched", url);
    }
    assert.equal(route("GET", "https://www.raycast.com/", null, providers, raycastDomains).kind, "untouched");
    // The proxies keep today's rule: every request there is refused, a GET included.
    assert.equal(route("GET", "https://x.oauth.raycast.com/", null, providers, raycastDomains).kind, "refused");
    assert.equal(route("GET", "https://x.oauth.raycast.com/", null, providers, []).kind, "refused");
    // Only a request with a body to raycast.com is read for its grant; a plain GET goes straight through.
    assert.ok(needsDecision(new URL("https://www.raycast.com/oauth/token"), providers, "POST", raycastDomains));
    assert.ok(!needsDecision(new URL("https://www.raycast.com/"), providers, "GET", raycastDomains));
    assert.ok(!needsDecision(new URL("https://www.raycast.com/"), providers, "head", raycastDomains));
    assert.ok(needsDecision(new URL("https://x.oauth.raycast.com/"), providers, "GET", raycastDomains));
});

test("through fetch, a grant to raycast.com is refused while a GET there goes where it was going", async () => {
    const previous = process.env[raycastDomainsVariable];
    process.env[raycastDomainsVariable] = JSON.stringify(raycastDomains);
    try {
        for (const answer of [on, { server: null, signedIn: false }]) {
            const { sent, fetch } = recorder();
            const wrapped = rewriteFetch(fetch, providers, async () => answer, fetch);
            for (const [url, grant] of [
                ["https://www.raycast.com/oauth/token", "authorization_code"],
                ["https://x.oauth-proxy.raycast.com/token", "refresh_token"],
                ["https://apple-music-oauth.raycast.com/token", "authorization_code"],
            ]) {
                await assert.rejects(wrapped(url, post(grant)), /Fudge doesn't send requests to/, url);
            }
            await assert.rejects(wrapped("https://x.oauth.raycast.com/whatever"), /Fudge doesn't send requests to/);
            await wrapped("https://www.raycast.com/");
            await wrapped("https://www.raycast.com/store", { method: "POST", body: "q=x" });
            assert.deepEqual(
                sent.map((request) => request.url),
                ["https://www.raycast.com/", "https://www.raycast.com/store"],
            );
        }
    } finally {
        if (previous === undefined) delete process.env[raycastDomainsVariable];
        else process.env[raycastDomainsVariable] = previous;
    }
});

// FUD-166 (SPEC-135 §4.1): a table match on any of Raycast's hosts is Raycast's address, never the provider's own
// host, so Todoist's proxy (`*.oauth-proxy.raycast.com`) goes to the relay as GitHub's proxy does.

test("Todoist's proxy is Raycast's: refused with sign-in off, and sent to the relay without a relay sign-in", async () => {
    const off = recorder();
    const refusing = rewriteFetch(off.fetch, providers, async () => ({ server: null, signedIn: false }), off.fetch);
    const error = await refusing("https://todoist.oauth-proxy.raycast.com/token", post("authorization_code")).catch(
        (caught: unknown) => caught,
    );
    assert.deepEqual(noticeOf(error), { notice: "signInOff", message: signInOffMessage });
    assert.equal(off.sent.length, 0, "nothing is sent");

    const { sent, fetch } = recorder();
    const wrapped = rewriteFetch(fetch, providers, async () => ({ ...on, signedIn: false }), fetch);
    await wrapped("https://todoist.oauth-proxy.raycast.com/token", post("authorization_code"));
    assert.equal(sent.at(-1)!.url, "https://relay.example/base/todoist/token");

    const routed = route("POST", "https://todoist.oauth-proxy.raycast.com/token", "authorization_code", providers, [
        "raycast.com",
    ]);
    assert.equal(routed.kind === "relay" && `${routed.provider.id}/${routed.ownHost}`, "todoist/false");
});

test("without Raycast's domains, the proxy hosts in the table still aren't own hosts", () => {
    for (const url of ["https://github.oauth.raycast.com/token", "https://notion.oauth.raycast.com/token"]) {
        const routed = route("POST", url, "authorization_code", providers, []);
        assert.equal(routed.kind === "relay" && routed.ownHost, false, url);
    }
});
