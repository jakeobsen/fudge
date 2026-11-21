// SPEC-116: a failed store install shows the whole error, its likely cause, Copy Error and Try Again. Made-up output
// only: nothing here runs npm, git or the network.
import assert from "node:assert/strict";
import { test } from "node:test";
import {
    causeOf,
    cleanOutput,
    codeBlock,
    escapeMarkdown,
    failureMarkdown,
    failureReport,
    lastLines,
    shownLines,
} from "../store-extension/src/failure.ts";
import { storeEnvironment } from "../store-extension/src/git.ts";
import { proxyVariables, systemProxy } from "../store-extension/src/proxy.ts";

const npmCommand = "fudge build /Users/someone/x --into /Users/someone/ext";

test("npm missing, as the architect's work laptop had it: Fudge opened from Finder can't see the shell's PATH", () => {
    const output =
        "  installing dependencies…\nfudge: `env npm ci --ignore-scripts --no-audit --no-fund --loglevel=error` failed (exit 127):\n" +
        "env: npm: No such file or directory\n";
    const cause = causeOf({ output, command: npmCommand, code: 1 });
    assert.equal(cause.kind, "npmMissing");
    assert.match(cause.text, /^Fudge couldn't find npm, which it needs to install extensions\./);
    assert.match(cause.text, /open -n -a Fudge/);
    // npm's own `#!/usr/bin/env node` finding no node is the same thing.
    assert.equal(causeOf({ output: "env: node: No such file or directory" }).kind, "npmMissing");
    assert.equal(causeOf({ output: "exit status 127", command: "npm ci", code: 127 }).kind, "npmMissing");
});

test("the npm registry unreachable, by npm's own error codes, and only when npm said so", () => {
    for (const line of [
        "npm error code ENOTFOUND\nnpm error network request to https://registry.npmjs.org/react failed, reason: getaddrinfo ENOTFOUND registry.npmjs.org",
        "npm error code ECONNREFUSED",
        "npm error code ETIMEDOUT",
        "npm error code EAI_AGAIN",
        "npm error code SELF_SIGNED_CERT_IN_CHAIN\nnpm error self-signed certificate in certificate chain",
        "npm ERR! code E403\nnpm ERR! 403 Forbidden - GET https://registry.npmjs.org/react",
        "npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
    ]) {
        const cause = causeOf({ output: line, command: npmCommand, code: 1 });
        assert.equal(cause.kind, "registryUnreachable", line);
        assert.equal(cause.text, "Fudge couldn't reach the npm registry (registry.npmjs.org). A proxy or firewall may be blocking it.");
    }
    // The same code from something that isn't npm isn't the registry.
    assert.notEqual(causeOf({ output: "ETIMEDOUT", command: "something else" }).kind, "registryUnreachable");
    // A proxy auto-configuration file is named, since npm and git can't read it.
    const pac = causeOf({ output: "npm error code ENOTFOUND", command: npmCommand }, { autoConfig: true });
    assert.match(pac.text, /automatic configuration file, which npm and git can't read\.$/);
});

test("GitHub unreachable for the extension's source, by git's own words", () => {
    for (const output of [
        "fatal: unable to access 'https://github.com/raycast/extensions.git/': Could not resolve host: github.com",
        "fatal: unable to access 'https://github.com/raycast/extensions.git/': Failed to connect to github.com port 443 after 75000 ms: Couldn't connect to server",
        "fatal: unable to access 'https://github.com/raycast/extensions.git/': SSL certificate problem: self signed certificate in certificate chain",
        "fatal: unable to access 'https://github.com/raycast/extensions.git/': Proxy CONNECT aborted",
    ]) {
        const cause = causeOf({ output, command: "git sparse-checkout add /extensions/jira/" });
        assert.equal(cause.kind, "githubUnreachable", output);
        assert.match(cause.text, /^Fudge couldn't reach GitHub \(github\.com\)/);
    }
});

test("git missing, a build error with its first line, and anything else", () => {
    assert.equal(causeOf({ output: "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)" }).kind, "gitMissing");
    const build = causeOf({
        output: '✘ [ERROR] Could not resolve "left-pad"\n\n    src/index.tsx:1:20:\n✘ [ERROR] Another one',
        command: npmCommand,
        code: 1,
    });
    assert.deepEqual(build, { kind: "buildFailed", text: 'The extension didn\'t build: Could not resolve "left-pad"' });
    assert.equal(causeOf({ output: "something odd happened", code: 1 }).text, "Something went wrong while installing.");
    assert.deepEqual(causeOf({ output: "Another extension called a is installed. Uninstall it first.", refused: true }), {
        kind: "refused",
        text: "Another extension called a is installed. Uninstall it first.",
    });
});

test("the output is untrusted: a fence, an image and HTML in it stay text (the spec review's MUST)", () => {
    const hostile = [
        "```",
        "![pixel](https://tracker.example/p.png)",
        '<img src="https://tracker.example/p.png">',
        "````",
        "[link](https://evil.example)",
    ].join("\n");
    const markdown = failureMarkdown("Couldn't install Jira", { kind: "other", text: "Something went wrong while installing." }, hostile);
    const fence = /\n(`{3,})text\n/.exec(markdown)![1]!;
    assert.equal(fence.length, 5, "longer than the longest run of backticks inside");
    const body = markdown.slice(markdown.indexOf(`${fence}text\n`) + fence.length + 5);
    assert.ok(body.endsWith(`\n${fence}`));
    const inside = body.slice(0, -fence.length - 1);
    assert.ok(!inside.split("\n").some((line) => /^`{5,}\s*$/.test(line)), "no line inside can close it");
    assert.equal(inside, hostile, "shown exactly as written");

    // The title and cause come from the extension and its packages too: every punctuation mark is escaped, so
    // nothing in them can be an image, a link, HTML or formatting, and they stay on one line.
    const title = "Couldn't install ![x](https://tracker.example/p.png) <img src=x> *b*\n# h";
    const escaped = escapeMarkdown(title);
    assert.equal(escaped, "Couldn\\'t install \\!\\[x\\]\\(https\\:\\/\\/tracker\\.example\\/p\\.png\\) \\<img src\\=x\\> \\*b\\* \\# h");
    assert.ok(!escaped.includes("\n"));
    // A combining mark after `*` is one character to the eye but still a `*` to Markdown (FUD-142).
    assert.equal(escapeMarkdown("*\u0301x*\u0301"), "\\*\u0301x\\*\u0301");
    const build = failureMarkdown("t", { kind: "buildFailed", text: "The extension didn't build: ![a](https://x.example/a.png)" }, "x");
    assert.ok(build.includes("\\!\\[a\\]\\(https\\:\\/\\/x\\.example\\/a\\.png\\)"));
});

test("the view shows the last 40 lines, and Copy Error copies them all with the command, exit and version", () => {
    const output = Array.from({ length: 100 }, (_, i) => `line ${i + 1}`).join("\n");
    assert.equal(lastLines(output).split("\n").length, shownLines);
    assert.ok(lastLines(output).startsWith("line 61\n") && lastLines(output).endsWith("line 100"));
    const markdown = failureMarkdown("Couldn't install Jira", { kind: "other", text: "Something went wrong while installing." }, output);
    assert.ok(markdown.includes("The last 40 lines of 100\\. Copy Error copies them all\\."));
    assert.ok(!markdown.includes("line 60\n"));
    const report = failureReport(
        "Couldn't install Jira",
        { kind: "other", text: "Something went wrong while installing." },
        { output, command: "fudge build ~/x --into ~/ext", code: 1 },
        output,
        "v0.3.0",
    );
    assert.ok(report.startsWith("Couldn't install Jira\n\nSomething went wrong while installing.\n\nCommand: fudge build ~/x --into ~/ext\nExit: 1\nFudge: v0.3.0\n\nline 1\n"));
    assert.ok(report.endsWith("line 100"));
    assert.match(failureReport("t", { kind: "other", text: "c" }, { output: "o" }, "o", undefined), /Fudge: unknown/);
    // A refusal is the store's own sentence; it isn't shown twice.
    const refusal = failureMarkdown("Couldn't install A", { kind: "refused", text: "Uninstall it first." }, "Uninstall it first.");
    assert.equal(refusal, "## Couldn\\'t install A\n\nUninstall it first\\.");
});

test("the output loses terminal codes and anything like a credential, and the home folder is ~", () => {
    const raw =
        "\x1b[31mnpm error\x1b[0m code E401\r\n" +
        "npm error //registry.npmjs.org/:_authToken=npm_abcdefghijklmnopqrstuvwxyz0123456789\n" +
        "fetching https://alice:hunter2@proxy.example.test:3128/x\n" +
        "Authorization: Bearer abcdef1234567890\n" +
        "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n" +
        "in /Users/someone/Library/Application Support/fudge\n" +
        "bell\x07 and \x1b]0;title\x07 gone";
    const clean = cleanOutput(raw, "/Users/someone");
    assert.ok(!/\x1b|\x07|\r/.test(clean));
    assert.ok(!clean.includes("npm_abcdefghijklmnopqrstuvwxyz0123456789"));
    assert.ok(!clean.includes("hunter2") && !clean.includes("alice"));
    assert.ok(!clean.includes("abcdef1234567890"));
    assert.ok(!clean.includes("ghp_"));
    assert.ok(clean.includes("_authToken=***"));
    assert.ok(clean.includes("https://***@proxy.example.test:3128/x"));
    assert.ok(clean.includes("in ~/Library/Application Support/fudge"));
    assert.ok(!clean.includes("/Users/someone"));
    assert.ok(clean.startsWith("npm error code E401\n"));
});

test("the Mac's proxy reaches npm and git only where no proxy variable is set", () => {
    const value = JSON.stringify({ https: "http://proxy.example.test:3128", http: "http://proxy.example.test:3128", noProxy: ".local,localhost", autoConfig: false });
    const base = { FUDGE_SYSTEM_PROXY: value, PATH: "/usr/bin" };
    assert.deepEqual(proxyVariables(base), {
        HTTPS_PROXY: "http://proxy.example.test:3128",
        https_proxy: "http://proxy.example.test:3128",
        HTTP_PROXY: "http://proxy.example.test:3128",
        http_proxy: "http://proxy.example.test:3128",
        NO_PROXY: ".local,localhost",
        no_proxy: ".local,localhost",
    });
    const environment = storeEnvironment(base);
    assert.equal(environment.https_proxy, "http://proxy.example.test:3128", "git's curl reads the lower-case one");
    assert.equal(environment.GIT_CONFIG_GLOBAL, "/dev/null");
    // The user's own wins, whichever variable they set, and their NO_PROXY too.
    for (const key of ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]) {
        assert.deepEqual(proxyVariables({ ...base, [key]: "http://mine.example.test:1" }), {}, key);
    }
    assert.equal(proxyVariables({ ...base, NO_PROXY: "corp" }).NO_PROXY, undefined);
    // Nothing set, nothing added; a malformed value is left out.
    assert.deepEqual(proxyVariables({ PATH: "/usr/bin" }), {});
    assert.deepEqual(proxyVariables({ FUDGE_SYSTEM_PROXY: "not json" }), {});
    for (const bad of ["http://user:pw@proxy.example.test:1", "https://proxy.example.test:1", "http://proxy.example.test", "http://a b:1", "http://-x:1"]) {
        assert.deepEqual(proxyVariables({ FUDGE_SYSTEM_PROXY: JSON.stringify({ https: bad }) }), {}, bad);
    }
    assert.deepEqual(proxyVariables({ FUDGE_SYSTEM_PROXY: JSON.stringify({ https: "http://[fd00::1]:3128" }) }), {
        HTTPS_PROXY: "http://[fd00::1]:3128",
        https_proxy: "http://[fd00::1]:3128",
    });
    assert.equal(systemProxy({ FUDGE_SYSTEM_PROXY: JSON.stringify({ autoConfig: true }) }).autoConfig, true);
});

test("a code block's fence is longer than any run of backticks in it", () => {
    assert.equal(codeBlock("plain"), "```text\nplain\n```");
    assert.equal(codeBlock("a ```` b"), "`````text\na ```` b\n`````");
});
