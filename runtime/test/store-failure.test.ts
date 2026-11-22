// SPEC-116: a failed store install shows the whole error, its likely cause, Copy Error and Try Again. Made-up output
// only: nothing here runs npm, git or the network.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import os, { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { build } from "esbuild";
import React, { createElement, type FunctionComponent } from "react";
import * as jsxRuntime from "react/jsx-runtime";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";
import type { UINode } from "../src/renderer/serialize.ts";
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
import { GitError, installCommandLineTools, storeEnvironment, type Run } from "../store-extension/src/git.ts";
import { proxyVariables, systemProxy } from "../store-extension/src/proxy.ts";
import { failureDetails } from "../store-extension/src/store.ts";
import { mount, type Mounted } from "./support/mount.ts";

const npmCommand = "fudge build /Users/someone/x --into /Users/someone/ext";

test("npm missing means a damaged Fudge, since npm and Node.js come with it: Reinstall Fudge", () => {
    const damaged =
        "Fudge couldn't find npm, which it needs to install extensions. npm and Node.js come with Fudge, so this copy " +
        "of Fudge is damaged. Reinstall Fudge.";
    for (const output of [
        // `fudge build` with no Node.js beside it (BuildError.noNode).
        "  installing dependencies\nfudge: the extension's dependencies need npm, from Fudge's own Node.js, which " +
            "isn't beside this fudge tool; use the fudge inside Fudge.app\n",
        // The bundled node there but unable to start (posix_spawn's error, through ChildProcesses).
        "  installing dependencies\nfudge: couldn't run /Applications/Fudge.app/Contents/Helpers/node: Bad CPU type in executable\n",
        // The bundled node running, its npm gone.
        "  installing dependencies\nfudge: `node npm-cli.js ci --ignore-scripts --no-audit --no-fund --loglevel=error` failed " +
            "(exit 1):\nnode:internal/modules/cjs/loader:1228\n  throw err;\n  ^\n\nError: Cannot find module " +
            "'/Applications/Fudge.app/Contents/Resources/node/npm/bin/npm-cli.js'\n    at Module._resolveFilename\n" +
            "  code: 'MODULE_NOT_FOUND',\n",
        // The shell's words for a missing npm or node, as before Fudge brought its own.
        "fudge: `env npm ci --ignore-scripts` failed (exit 127):\nenv: npm: No such file or directory\n",
        "env: node: No such file or directory",
        "zsh: npm: command not found",
    ]) {
        const cause = causeOf({ output, command: npmCommand, code: 1 });
        assert.equal(cause.kind, "npmMissing", output);
        assert.equal(cause.text, damaged);
    }
    assert.equal(causeOf({ output: "exit status 127", command: "npm ci", code: 127 }).kind, "npmMissing");
    // No PATH or Terminal advice any more: there's nothing the user's own npm could fix.
    assert.doesNotMatch(causeOf({ output: "env: npm: No such file or directory" }).text, /PATH|open -n|Terminal/);
    // A package the extension imports that isn't there is its own build's problem, not a missing npm.
    assert.notEqual(
        causeOf({ output: "Error: Cannot find module '/x/node_modules/left-pad/index.js'", command: npmCommand, code: 1 })
            .kind,
        "npmMissing",
    );
    // Something else that couldn't run isn't Node.js.
    assert.notEqual(
        causeOf({ output: "fudge: couldn't run /usr/bin/git: Permission denied", command: npmCommand, code: 1 }).kind,
        "npmMissing",
    );
});

test("the compile step missing is a damaged Fudge too, in its own words rather than npm's (SPEC-147)", () => {
    // `fudge build` with no Node.js or bundling script beside it (BuildError.noBundler), as it prints it.
    const output =
        "fudge: compiling needs Fudge's own Node.js and its bundling script, which aren't beside this fudge tool; " +
        "use the fudge inside Fudge.app\n";
    const cause = causeOf({ output, command: npmCommand, code: 1 });
    assert.equal(cause.kind, "bundlerMissing");
    assert.equal(
        cause.text,
        "Fudge couldn't find a part it needs to build extensions. It comes with Fudge, so this copy of Fudge is " +
            "damaged. Reinstall Fudge.",
    );
    assert.doesNotMatch(cause.text, /npm/);
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
    // Since Fudge brings its own npm (#142), `fudge build` names it as `node …/npm-cli.js ci`, by the executable's last
    // path component: still npm.
    const bundled =
        "  installing dependencies\nfudge: `node /Applications/Fudge.app/Contents/Resources/node/npm/bin/npm-cli.js ci " +
        "--ignore-scripts --no-audit --no-fund --loglevel=error` failed (exit 1):\nnpm error code ENOTFOUND\nnpm error " +
        "errno ENOTFOUND\nnpm error network request to https://registry.npmjs.org/react failed, reason: getaddrinfo " +
        "ENOTFOUND registry.npmjs.org\n";
    assert.equal(causeOf({ output: bundled, command: npmCommand, code: 1 }).kind, "registryUnreachable");
    // Even if npm's own words were only the code, its command says it's npm.
    assert.equal(
        causeOf({ output: "`node /x/npm-cli.js ci --ignore-scripts` failed (exit 1):\ngetaddrinfo ENOTFOUND", command: npmCommand })
            .kind,
        "registryUnreachable",
    );
    // The same code from something that isn't npm isn't the registry.
    assert.notEqual(causeOf({ output: "ETIMEDOUT", command: "something else" }).kind, "registryUnreachable");
    // A proxy auto-configuration file is named, since npm and git can't read it.
    const pac = causeOf({ output: "npm error code ENOTFOUND", command: npmCommand }, { autoConfig: true });
    assert.match(pac.text, /automatic configuration file, which npm and git can't read\.$/);
});

test("GitHub unreachable, by git's own words", () => {
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

test("a repository on another host is named by its host in \"couldn't reach\" (SPEC-157 C.6)", () => {
    for (const [output, host] of [
        ["fatal: unable to access 'https://gitlab.com/group/tools/': Could not resolve host: gitlab.com", "gitlab.com"],
        ["fatal: unable to access 'https://git.example.com:8443/tools/': Failed to connect to git.example.com port 8443", "git.example.com:8443"],
        ["fatal: unable to access 'https://codeberg.org/someone/tools/': Proxy CONNECT aborted", "codeberg.org"],
        // Only git's "unable to access" says it here, as it does for GitHub.
        ["fatal: unable to access 'https://git.example.org/tools/': getaddrinfo() thread failed to start", "git.example.org"],
    ] as const) {
        const cause = causeOf({ output, command: "git clone --filter=blob:none", host });
        assert.equal(cause.kind, "githubUnreachable", output);
        assert.equal(cause.text, `Fudge couldn't reach ${host}. A proxy or firewall may be blocking it.`);
        assert.equal(
            causeOf({ output, command: "git clone", host }, { autoConfig: true }).text,
            `Fudge couldn't reach ${host}. A proxy or firewall may be blocking it. Your Mac picks its proxy with an automatic configuration file, which npm and git can't read.`,
        );
    }
    const github = "fatal: unable to access 'https://github.com/owner/tools/': Could not resolve host: github.com";
    for (const host of [undefined, "github.com"]) {
        assert.match(causeOf({ output: github, command: "git fetch", ...(host ? { host } : {}) }).text, /^Fudge couldn't reach GitHub \(github\.com\)\./);
    }
    // Only git's words name a host: an npm failure on another repository's row still names the registry.
    const npm = causeOf({ output: "npm error code ENOTFOUND\nnpm error network request to https://registry.npmjs.org/x failed", command: "node npm-cli.js ci", host: "gitlab.com" });
    assert.equal(npm.kind, "registryUnreachable");
});

test("the store's list failing to download: a failed git clone says GitHub can't be reached, with the proxy note", () => {
    // As `StoreRepository.clone` throws it: git's stderr, and the command that ran.
    const error = new GitError(
        "Cloning into '/Users/someone/Library/Application Support/fudge/extension-data/fudge-extension-store/repo'...\n" +
            "fatal: unable to access 'https://github.com/raycast/extensions/': Could not resolve host: github.com",
        "git clone --depth 1 --filter=blob:none --sparse --no-checkout https://github.com/raycast/extensions /Users/someone/repo",
    );
    const details = failureDetails(error);
    assert.equal(details.command?.startsWith("git clone "), true);
    const cause = causeOf(details);
    assert.equal(cause.kind, "githubUnreachable");
    assert.equal(cause.text, "Fudge couldn't reach GitHub (github.com). A proxy or firewall may be blocking it.");
    assert.match(causeOf(details, { autoConfig: true }).text, /automatic configuration file, which npm and git can't read\.$/);
    // A clone that failed some other way is the generic line, which fits a list download as well as an install.
    assert.equal(
        causeOf(failureDetails(new GitError("fatal: something odd", "git clone x y"))).text,
        "Something went wrong. Copy Error copies the whole error.",
    );
});

test("git missing, a build error with its first line, and anything else", () => {
    assert.equal(causeOf({ output: "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)" }).kind, "gitMissing");
    const build = causeOf({
        output: '✘ [ERROR] Could not resolve "left-pad"\n\n    src/index.tsx:1:20:\n✘ [ERROR] Another one',
        command: npmCommand,
        code: 1,
    });
    assert.deepEqual(build, { kind: "buildFailed", text: 'The extension didn\'t build: Could not resolve "left-pad"' });
    // The same, as `fudge build` prints it: the compile step's own first line, then esbuild's output (SPEC-147).
    const printed = causeOf({
        output:
            '  compiling 1 command\nfudge: compiling the extension failed (exit 1):\n✘ [ERROR] Could not resolve "left-pad"' +
            "\n\n    src/index.tsx:1:20:\n",
        command: npmCommand,
        code: 1,
    });
    assert.deepEqual(printed, build);
    assert.equal(causeOf({ output: "something odd happened", code: 1 }).text, "Something went wrong. Copy Error copies the whole error.");
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
    const markdown = failureMarkdown("Couldn't install Jira", { kind: "other", text: "Something went wrong. Copy Error copies the whole error." }, hostile);
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
    const markdown = failureMarkdown("Couldn't install Jira", { kind: "other", text: "Something went wrong. Copy Error copies the whole error." }, output);
    assert.ok(markdown.includes("The last 40 lines of 100\\. Copy Error copies them all\\."));
    assert.ok(!markdown.includes("line 60\n"));
    const report = failureReport(
        "Couldn't install Jira",
        { kind: "other", text: "Something went wrong. Copy Error copies the whole error." },
        { output, command: "fudge build ~/x --into ~/ext", code: 1 },
        output,
        "v0.3.0",
    );
    assert.ok(report.startsWith("Couldn't install Jira\n\nSomething went wrong. Copy Error copies the whole error.\n\nCommand: fudge build ~/x --into ~/ext\nExit: 1\nFudge: v0.3.0\n\nline 1\n"));
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
    // Only the whole folder: another user whose name starts the same isn't the home folder.
    assert.equal(
        cleanOutput("/Users/someonex/a /Users/someone/b /Users/someone\n'/Users/someone' (/Users/someone) /Users/someone.", "/Users/someone"),
        "/Users/someonex/a ~/b ~\n'~' (~) ~.",
    );
    assert.equal(cleanOutput("/Users/someone.old/x /Users/some.one/y", "/Users/some.one/"), "/Users/someone.old/x ~/y");
});

test("the Mac's proxy reaches npm and git only where no proxy variable is set", () => {
    const value = JSON.stringify({ https: "http://proxy.example.test:3128", http: "http://proxy.example.test:3128", noProxy: ".local,localhost", autoConfig: false });
    const base = { FUDGE_SYSTEM_PROXY: value, PATH: "/usr/bin" };
    assert.deepEqual(proxyVariables(base), {
        HTTPS_PROXY: "http://proxy.example.test:3128",
        https_proxy: "http://proxy.example.test:3128",
        HTTP_PROXY: "http://proxy.example.test:3128",
        http_proxy: "http://proxy.example.test:3128",
        NO_PROXY: "localhost,127.0.0.1,.local",
        no_proxy: "localhost,127.0.0.1,.local",
    });
    // The Mac itself never goes through the proxy, even with no bypass list.
    assert.deepEqual(
        proxyVariables({ FUDGE_SYSTEM_PROXY: JSON.stringify({ https: "http://proxy.example.test:3128" }) }).NO_PROXY,
        "localhost,127.0.0.1",
    );
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
        NO_PROXY: "localhost,127.0.0.1",
        no_proxy: "localhost,127.0.0.1",
    });
    assert.equal(systemProxy({ FUDGE_SYSTEM_PROXY: JSON.stringify({ autoConfig: true }) }).autoConfig, true);
});

test("a code block's fence is longer than any run of backticks in it", () => {
    assert.equal(codeBlock("plain"), "```text\nplain\n```");
    assert.equal(codeBlock("a ```` b"), "`````text\na ```` b\n`````");
});

// The views, compiled as `fudge build` compiles the store, against Fudge's own `@raycast/api`. `fudge version` is a
// made-up script; nothing here runs npm, git or the network.

let viewFolder = "";
let cli = "";
let calls: RpcRequest[] = [];

beforeEach(() => {
    viewFolder = mkdtempSync(path.join(tmpdir(), "fudge-store-failure-"));
    cli = path.join(viewFolder, "fudge");
    writeFileSync(cli, "#!/bin/sh\necho v9.9.9\n", { mode: 0o755 });
    calls = [];
    setLaunchContext({
        preferences: {},
        environment: { ...placeholderEnvironment, extensionName: "fudge-extension-store", commandName: "extension-store", commandMode: "view" },
        launchProps: {},
    });
    connect((request) => {
        calls.push(request);
        setImmediate(() => settle(request.id, null));
    });
});
afterEach(() => {
    connect(null);
    rmSync(viewFolder, { recursive: true, force: true });
});

type Views = {
    FailureView: FunctionComponent<{ title: string; details: object; cli: string; retry: () => void; retryTitle?: string }>;
    LoadFailure: FunctionComponent<{ title: string; details: object; cli: string; refresh: () => void }>;
    NeedsGit: FunctionComponent<{ refresh: () => void; run?: Run }>;
};
let compiled: Promise<string> | null = null;

async function loadViews(): Promise<Views> {
    compiled ??= build({
        entryPoints: [path.join(import.meta.dirname, "../store-extension/src/failure-view.tsx")],
        bundle: true,
        platform: "node",
        format: "cjs",
        target: "node22",
        jsx: "automatic",
        external: ["@raycast/api", "react", "react/jsx-runtime"],
        write: false,
        logLevel: "silent",
    }).then((result) => result.outputFiles[0]!.text);
    const provided: Record<string, unknown> = { "@raycast/api": createApiModule(), react: React, "react/jsx-runtime": jsxRuntime };
    const fallback = createRequire(import.meta.url);
    const require = (name: string) => (Object.hasOwn(provided, name) ? provided[name] : fallback(name));
    const module = { exports: {} as Views };
    new Function("module", "exports", "require", await compiled)(module, module.exports, require);
    return module.exports;
}

/** Every node of `type` under `node`, props included, depth first. */
function all(node: UINode | null | undefined, type: string): UINode[] {
    if (!node) return [];
    const found = node.type === type ? [node] : [];
    for (const value of Object.values(node.props)) {
        if (typeof value === "object" && value !== null && "type" in value && "children" in value) found.push(...all(value as UINode, type));
    }
    for (const child of node.children) found.push(...all(child, type));
    return found;
}
const top = (mounted: Mounted) => mounted.snapshots.at(-1)!.view!;
const action = (mounted: Mounted, title: string) => all(top(mounted), "Action").find((each) => each.props.title === title)!;

/** Waits until `fudge version` has answered and the view has drawn again with it. */
async function versionArrives(mounted: Mounted) {
    // Up to 10 s: the made-up `fudge --version` is a process of its own, slow to start on a busy Mac.
    for (let i = 0; i < 1000 && mounted.snapshots.length < 2; i++) await new Promise((resolve) => setTimeout(resolve, 10));
    await mounted.settle();
}

test("Try Again runs once per view: a second ↵ before the view has gone does nothing", async () => {
    const { FailureView } = await loadViews();
    let retries = 0;
    // As the root, where `pop` can't take it away, so both presses reach it.
    const mounted = await mount(
        createElement(FailureView, {
            title: "Couldn't install Jira",
            details: { output: "something odd", command: "fudge build x", code: 1 },
            cli,
            retry: () => retries++,
        }),
    );
    const tryAgain = action(mounted, "Try Again");
    mounted.root.dispatch(tryAgain.id, ["onAction"], []);
    mounted.root.dispatch(tryAgain.id, ["onAction"], []);
    await mounted.settle();
    assert.equal(retries, 1);
});

test("Try Again goes back to the list, then runs the install again", async () => {
    const { FailureView } = await loadViews();
    let retries = 0;
    const mounted = await mount(createElement("Detail", { markdown: "the list" }));
    mounted.navigation.current!.push(
        createElement(FailureView, { title: "Couldn't install Jira", details: { output: "x" }, cli, retry: () => retries++ }),
    );
    await mounted.settle();
    assert.equal(top(mounted).props.navigationTitle, "Couldn't install Jira");
    mounted.root.dispatch(action(mounted, "Try Again").id, ["onAction"], []);
    await mounted.settle();
    assert.equal(retries, 1);
    assert.equal(top(mounted).props.markdown, "the list");
});

test("the store's list failing before it has loaded: its cause, Refresh, Copy Error and the details (SPEC-116 §1)", async () => {
    const { LoadFailure } = await loadViews();
    const home = os.homedir();
    const details = failureDetails(
        new GitError(
            "fatal: unable to access 'https://github.com/raycast/extensions/': Could not resolve host: github.com",
            `git clone --depth 1 --filter=blob:none --sparse --no-checkout https://github.com/raycast/extensions ${home}/repo`,
        ),
    );
    let refreshes = 0;
    const saved = process.env.FUDGE_SYSTEM_PROXY;
    process.env.FUDGE_SYSTEM_PROXY = JSON.stringify({ autoConfig: true });
    try {
        const title = "Couldn't download the store's list";
        const mounted = await mount(
            createElement("List", {}, createElement(LoadFailure, { title, details, cli, refresh: () => refreshes++ })),
        );
        await versionArrives(mounted);
        const empty = all(top(mounted), "List.EmptyView")[0]!;
        assert.equal(empty.props.title, title);
        assert.equal(
            empty.props.description,
            "Fudge couldn't reach GitHub (github.com). A proxy or firewall may be blocking it. Your Mac picks its proxy " +
                "with an automatic configuration file, which npm and git can't read.",
        );
        const actions = all(empty, "Action");
        assert.deepEqual(
            actions.map((each) => [each.props.title, (each.props.shortcut as { key?: string } | undefined)?.key]),
            [["Refresh", "r"], ["Copy Error", "c"], ["Show Details", "d"]],
            "Refresh first, so ↵ and ⌘R both refresh",
        );

        mounted.root.dispatch(action(mounted, "Refresh").id, ["onAction"], []);
        assert.equal(refreshes, 1);

        await mounted.root.dispatch(action(mounted, "Copy Error").id, ["onAction"], []);
        const copied = (calls.find((call) => call.method === "clipboard.copy")?.params as { text?: string }).text!;
        assert.ok(copied.startsWith(`${title}\n\nFudge couldn't reach GitHub (github.com).`), copied);
        assert.ok(copied.includes("Command: git clone --depth 1 --filter=blob:none --sparse --no-checkout https://github.com/raycast/extensions ~/repo\n"));
        assert.ok(copied.includes("Fudge: v9.9.9"));
        assert.ok(copied.endsWith("Could not resolve host: github.com"));
        assert.ok(!copied.includes(home + "/"), "the home folder is ~");

        // Show Details pushes the failure view with git's output; its Refresh goes back and refreshes once.
        mounted.root.dispatch(action(mounted, "Show Details").id, ["onAction"], []);
        await mounted.settle();
        assert.equal(top(mounted).type, "Detail");
        assert.match(String(top(mounted).props.markdown), /Could not resolve host: github\.com\n```$/);
        mounted.root.dispatch(action(mounted, "Refresh").id, ["onAction"], []);
        await mounted.settle();
        assert.equal(refreshes, 2);
        assert.equal(top(mounted).type, "List");
    } finally {
        if (saved === undefined) delete process.env.FUDGE_SYSTEM_PROXY;
        else process.env.FUDGE_SYSTEM_PROXY = saved;
    }
});

// The store without git (N8, SPEC-114): never runs `xcode-select` here, only a fake.

/** A fake `xcode-select`: records each call and answers as given. */
function fakeXcodeSelect(answer: { code: number; stdout?: string; stderr?: string }) {
    const calls: { program: string; args: string[] }[] = [];
    const run: Run = async (program, args) => {
        calls.push({ program, args });
        return { stdout: "", stderr: "", ...answer };
    };
    return { run, calls };
}

test("Install Command Line Tools asks macOS's installer with xcode-select --install, and says why it couldn't", async () => {
    const started = fakeXcodeSelect({ code: 0 });
    assert.equal(await installCommandLineTools(started.run), undefined);
    assert.deepEqual(started.calls, [{ program: "/usr/bin/xcode-select", args: ["--install"] }]);
    const installed = fakeXcodeSelect({
        code: 1,
        stderr: 'xcode-select: note: Command line tools are already installed. Use "Software Update" in System Settings to install updates\n',
    });
    assert.match((await installCommandLineTools(installed.run))!, /already installed/);
    assert.equal(await installCommandLineTools(fakeXcodeSelect({ code: 2 }).run), "xcode-select exited with 2");
});

test("the store without git says what it needs in plain words, offers the installer, and Refresh checks again", async () => {
    const { NeedsGit } = await loadViews();
    const installer = fakeXcodeSelect({ code: 0 });
    let refreshes = 0;
    const mounted = await mount(createElement("List", {}, createElement(NeedsGit, { refresh: () => refreshes++, run: installer.run })));
    const empty = all(top(mounted), "List.EmptyView")[0]!;
    assert.equal(empty.props.title, "The Extension Store needs Git");
    assert.equal(empty.props.description, "Git comes with Apple's Command Line Tools. Install them, then refresh.");
    assert.doesNotMatch(String(empty.props.description), /`/, "drawn as written, so no Markdown");
    assert.deepEqual(
        all(empty, "Action").map((each) => [each.props.title, (each.props.shortcut as { key?: string } | undefined)?.key]),
        [["Install Command Line Tools", undefined], ["Refresh", "r"]],
        "↵ installs",
    );

    await mounted.root.dispatch(action(mounted, "Install Command Line Tools").id, ["onAction"], []);
    assert.deepEqual(installer.calls, [{ program: "/usr/bin/xcode-select", args: ["--install"] }]);
    const toast = calls.find((call) => call.method === "toast.show")?.params as { title?: string; message?: string };
    assert.equal(toast.title, "Follow macOS's installer");
    assert.equal(toast.message, "Then refresh the store.");

    mounted.root.dispatch(action(mounted, "Refresh").id, ["onAction"], []);
    assert.equal(refreshes, 1);
});

test("a failure whose cause is a missing git offers the installer too; others don't", async () => {
    const { FailureView } = await loadViews();
    const titles = async (output: string) => {
        const mounted = await mount(createElement(FailureView, { title: "Couldn't install Jira", details: { output }, cli, retry: () => {} }));
        return all(top(mounted), "Action").map((each) => each.props.title);
    };
    assert.ok((await titles("xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)")).includes("Install Command Line Tools"));
    assert.ok(!(await titles("something odd")).includes("Install Command Line Tools"));
});
