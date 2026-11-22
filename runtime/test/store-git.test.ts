// The store's git for every repository's copy (SPEC-157 C.3, C.4, C.7): https only, no prompts, the list's branch, and
// a clone or fetch stopped when the server ignores the filter. Real git against local repositories in temporary folders.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import {
    cancelGrace,
    NoBranch,
    NoPartialClone,
    partialCloneWarning,
    spawnProgram,
    StoreRepository,
    type Run,
} from "../store-extension/src/git.ts";

const folders: string[] = [];
after(async () => {
    for (const folder of folders) await rm(folder, { recursive: true, force: true });
});

async function temporary(): Promise<string> {
    const folder = await mkdtemp(path.join(tmpdir(), "fudge-store-git-"));
    folders.push(folder);
    return folder;
}

async function sh(cwd: string, ...args: string[]): Promise<string> {
    const result = await spawnProgram(
        "/usr/bin/git",
        ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", ...args],
        { cwd, timeout: 60_000 },
    );
    assert.equal(result.code, 0, `git ${args.join(" ")}: ${result.stderr}`);
    return result.stdout;
}

/** A bare repository with `extensions/<name>/package.json` on `main`, and its working copy to commit more from. */
async function remote(root: string, names: string[] = ["alpha"]): Promise<{ source: string; bare: string }> {
    const source = path.join(root, "source");
    const bare = path.join(root, "bare.git");
    for (const name of names) {
        await mkdir(path.join(source, "extensions", name), { recursive: true });
        await writeFile(path.join(source, "extensions", name, "package.json"), JSON.stringify({ name, title: name }));
    }
    await sh(source, "init", "--quiet", "--initial-branch=main");
    await sh(source, "add", ".");
    await sh(source, "commit", "--quiet", "-m", "first");
    await sh(root, "clone", "--quiet", "--bare", source, bare);
    // The test pushes and fetches as a server would allow it, filters and tree wants included.
    await sh(bare, "config", "uploadpack.allowFilter", "true");
    await sh(bare, "config", "uploadpack.allowAnySHA1InWant", "true");
    return { source, bare };
}

/** Every run's arguments and options, through the real runner. */
function recording() {
    const calls: { args: string[]; options: Parameters<Run>[2]; stopped?: true }[] = [];
    const run: Run = async (program, args, options) => {
        const result = await spawnProgram(program, args, options);
        calls.push({ args, options, ...(result.stopped ? { stopped: true as const } : {}) });
        return result;
    };
    return { run, calls };
}

// MARK: - https only, no prompts (C.4)

test("https only: a file:// remote with the default allowProtocols fails to clone, and git names the transport", async () => {
    const root = await temporary();
    const { bare } = await remote(root);
    const repo = new StoreRepository(path.join(root, "support/repo"), { url: `file://${bare}` });
    await assert.rejects(repo.clone(), /transport 'file' not allowed/);
    // Through the seam, the same remote clones.
    const allowed = new StoreRepository(path.join(root, "support/allowed"), { url: `file://${bare}`, allowProtocols: "file" });
    await allowed.clone();
    assert.ok(await allowed.exists());
});

test("no prompts: a server asking for a password gets none, from an askpass program or a credential helper", async () => {
    const root = await temporary();
    const marker = path.join(root, "asked");
    const script = path.join(root, "ask.sh");
    await writeFile(script, `#!/bin/sh\necho "$0 $*" >> '${marker}'\necho secret\n`);
    await chmod(script, 0o755);
    let requests = 0;
    const server = createServer((_request, response) => {
        requests++;
        response.writeHead(401, { "WWW-Authenticate": 'Basic realm="test"' });
        response.end("no");
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const { port } = server.address() as { port: number };
    // The test's own environment, which the store's programs inherit: each of these would answer if git asked.
    const names = ["GIT_ASKPASS", "SSH_ASKPASS", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"] as const;
    const saved = Object.fromEntries(names.map((name) => [name, process.env[name]]));
    Object.assign(process.env, {
        GIT_ASKPASS: script,
        SSH_ASKPASS: script,
        GIT_CONFIG_COUNT: "1",
        GIT_CONFIG_KEY_0: "credential.helper",
        GIT_CONFIG_VALUE_0: `!${script}`,
    });
    try {
        // `http` allowed for this test only: otherwise git refuses it before it connects.
        const repo = new StoreRepository(path.join(root, "support/repo"), {
            url: `http://127.0.0.1:${port}/private.git`,
            allowProtocols: "http",
        });
        await assert.rejects(repo.clone(), /terminal prompts disabled|Authentication failed|401/);
        assert.ok(requests > 0, "git reached the server");
        await assert.rejects(stat(marker), "nothing was asked");
    } finally {
        for (const name of names) {
            if (saved[name] === undefined) delete process.env[name];
            else process.env[name] = saved[name];
        }
        server.close();
        await once(server, "close");
    }
});

// MARK: - The list's branch (C.3)

test("a branch given: the clone and the refresh follow it; a missing branch is noBranch", async () => {
    const root = await temporary();
    const { source, bare } = await remote(root, ["alpha"]);
    await sh(source, "checkout", "--quiet", "-b", "tools");
    await mkdir(path.join(source, "extensions/beta"), { recursive: true });
    await writeFile(path.join(source, "extensions/beta/package.json"), JSON.stringify({ name: "beta", title: "Beta" }));
    await sh(source, "add", ".");
    await sh(source, "commit", "--quiet", "-m", "beta on tools");
    await sh(source, "push", "--quiet", bare, "tools");

    const repo = new StoreRepository(path.join(root, "support/repo"), { url: `file://${bare}`, allowProtocols: "file", branch: "tools" });
    await repo.clone();
    assert.deepEqual((await readdir(path.join(repo.path, "extensions"))).sort(), ["alpha", "beta"], "the branch's files");
    // A new commit on the branch, and one on main that the copy never takes.
    await writeFile(path.join(source, "extensions/beta/package.json"), JSON.stringify({ name: "beta", title: "Beta 2" }));
    await sh(source, "commit", "--quiet", "-am", "beta 2");
    await sh(source, "push", "--quiet", bare, "tools");
    await sh(source, "checkout", "--quiet", "main");
    await rm(path.join(source, "extensions/alpha"), { recursive: true });
    await sh(source, "commit", "--quiet", "-am", "alpha gone on main");
    await sh(source, "push", "--quiet", bare, "main");
    await repo.refresh();
    assert.equal(JSON.parse(await readFile(path.join(repo.path, "extensions/beta/package.json"), "utf8")).title, "Beta 2");
    assert.ok(await stat(path.join(repo.path, "extensions/alpha/package.json")), "main's change isn't followed");
    assert.equal((await sh(repo.path, "rev-parse", "--abbrev-ref", "HEAD")).trim(), "tools");

    const missing = new StoreRepository(path.join(root, "support/missing"), { url: `file://${bare}`, allowProtocols: "file", branch: "nope" });
    const cloned = await missing.clone().then(
        () => undefined,
        (error: unknown) => error,
    );
    assert.ok(cloned instanceof NoBranch, String(cloned));
    assert.equal(cloned.branch, "nope");
    // A branch deleted after the clone: the refresh says so, and the copy stays.
    await sh(bare, "branch", "-D", "tools");
    const refreshed = await repo.refresh().then(
        () => undefined,
        (error: unknown) => error,
    );
    assert.ok(refreshed instanceof NoBranch, String(refreshed));
    assert.ok(await repo.exists());
    assert.throws(() => new StoreRepository(path.join(root, "x"), { branch: "-bad" }), /Not a branch name/);
});

// MARK: - stopOn (C.7)

const sh2 = (script: string, signal = new AbortController().signal) =>
    spawnProgram("/bin/sh", ["-c", script], { timeout: 60_000, signal, stopOn: "filtering not recognized" });

test("stopOn: the text on stderr ends the program at once and the result says so; without it, it runs to its end", async () => {
    const started = Date.now();
    const stopped = await sh2('echo "warning: filtering not recognized by server, ignoring" >&2; sleep 30');
    assert.ok(Date.now() - started < cancelGrace + 2000, `ended within the grace: ${Date.now() - started} ms`);
    assert.equal(stopped.stopped, true);
    assert.notEqual(stopped.code, 0);

    const plain = await sh2('echo "warning: something else" >&2; sleep 0.3; echo done');
    assert.equal(plain.stopped, undefined);
    assert.equal(plain.code, 0);
    assert.equal(plain.stdout, "done\n");
});

test("stopOn: a text split across two writes still stops; one written by a program that exits at once still counts", async () => {
    const started = Date.now();
    const split = await sh2('printf "warning: filtering not rec" >&2; sleep 0.3; printf "ognized by server\\n" >&2; sleep 30');
    assert.ok(Date.now() - started < cancelGrace + 2000, `ended within the grace: ${Date.now() - started} ms`);
    assert.equal(split.stopped, true);

    const quick = await sh2('echo "warning: filtering not recognized by server, ignoring" >&2; exit 0');
    assert.equal(quick.stopped, true, "seen even when it ended before the signal landed");
});

test("stopOn needs a signal: without one the program isn't started", async () => {
    const result = await spawnProgram("/bin/sh", ["-c", "echo ran"], { timeout: 5_000, stopOn: "x" });
    assert.equal(result.code, -1);
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /stopOn needs a signal/);
});

// MARK: - A server that ignores the filter (C.7, R1)

/** 20 MB of random bytes in one extension's folder, which a partial clone would never download. */
async function bigFile(source: string): Promise<void> {
    await mkdir(path.join(source, "extensions/alpha/assets"), { recursive: true });
    await writeFile(path.join(source, "extensions/alpha/assets/big.bin"), randomBytes(20 * 1024 * 1024));
}

test("no partial clone: the clone is stopped, no copy is left, and the run had stopOn and LC_ALL=C", async () => {
    const root = await temporary();
    const { source, bare } = await remote(root);
    await bigFile(source);
    await sh(source, "add", ".");
    await sh(source, "commit", "--quiet", "-m", "big");
    await sh(source, "push", "--quiet", bare, "main");
    await sh(bare, "config", "uploadpack.allowFilter", "false");

    const { run, calls } = recording();
    const repo = new StoreRepository(path.join(root, "support/repo"), { url: `file://${bare}`, allowProtocols: "file", run });
    await assert.rejects(repo.clone(), (error: unknown) => error instanceof NoPartialClone);
    assert.equal(await repo.exists(), false);
    await assert.rejects(stat(repo.path), "no partial copy left");
    const clone = calls.find((call) => call.args.includes("clone"))!;
    assert.equal(clone.options.stopOn, partialCloneWarning);
    assert.equal(clone.options.env?.LC_ALL, "C");
    assert.ok(clone.options.signal);
    assert.equal(clone.stopped, true);
    assert.equal(calls.length, 1, "nothing ran after the stopped clone");
});

test("no partial clone on a refresh: the fetch is stopped and the copy stays as it was", async () => {
    const root = await temporary();
    const { source, bare } = await remote(root);
    const { run, calls } = recording();
    const repo = new StoreRepository(path.join(root, "support/repo"), { url: `file://${bare}`, allowProtocols: "file", run });
    await repo.clone();
    const before = await repo.commit();
    await bigFile(source);
    await writeFile(path.join(source, "extensions/alpha/package.json"), JSON.stringify({ name: "alpha", title: "Alpha 2" }));
    await sh(source, "add", ".");
    await sh(source, "commit", "--quiet", "-m", "big");
    await sh(source, "push", "--quiet", bare, "main");
    await sh(bare, "config", "uploadpack.allowFilter", "false");

    await assert.rejects(repo.refresh(), (error: unknown) => error instanceof NoPartialClone);
    assert.equal(await repo.commit(), before, "the copy's commit is as it was");
    assert.equal(JSON.parse(await readFile(path.join(repo.path, "extensions/alpha/package.json"), "utf8")).title, "alpha");
    const fetch = calls.find((call) => call.args.includes("fetch"))!;
    assert.equal(fetch.options.stopOn, partialCloneWarning);
    assert.equal(fetch.options.env?.LC_ALL, "C");
    assert.equal(fetch.stopped, true);
    assert.deepEqual(
        calls.slice(calls.indexOf(fetch) + 1).map((call) => call.args.join(" ")),
        ["rev-parse HEAD"],
        "nothing after the stopped fetch but the test's own read",
    );
});
