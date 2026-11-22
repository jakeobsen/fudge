// The Extension Store's repositories (SPEC-157 C.2, C.5, C.6, C.7): the copies of the repositories that are on, where
// they and their status files are, what went wrong with one, and the copies of repositories no longer listed.
import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { GitError, NoBranch, NoPartialClone, type Run } from "../store-extension/src/git.ts";
import {
    copyPath,
    copyStatus,
    CopyProblem,
    maxCopyExtensions,
    problemKinds,
    problemOf,
    problemSentence,
    readCopy,
    readStatus,
    removeCopy,
    removeUnlistedCopies,
    statusPath,
    storeCopies,
    unlistedCopies,
    waitsForRetry,
    writeStatus,
    type CopyStatus,
} from "../store-extension/src/repositories.ts";
import { parseRepositoryAddress, type ParsedRepository, type RepositoryEntry } from "../store-extension/src/repository-address.ts";

const folders: string[] = [];
after(async () => {
    for (const folder of folders) await rm(folder, { recursive: true, force: true });
});

async function temporary(): Promise<string> {
    const folder = await mkdtemp(path.join(tmpdir(), "fudge-store-repositories-"));
    folders.push(folder);
    return folder;
}

/** An added repository as the app answers it, from a made-up address. */
function added(address: string, branch?: string, on = true, list: ParsedRepository[] = []) {
    const parsed = parseRepositoryAddress(address, branch, list);
    assert.ok(!("refused" in parsed), `${address} parses`);
    const answer = {
        copyId: parsed.copyId,
        folder: parsed.folder,
        address: parsed.address,
        ...(parsed.branch === undefined ? {} : { branch: parsed.branch }),
        name: parsed.name,
        on,
    };
    return { parsed, answer };
}

const raycastAnswer = (on = true) => ({
    copyId: "raycast",
    folder: "raycast/extensions",
    address: "github.com/raycast/extensions",
    name: "Raycast",
    on,
});

/** Records every git call and answers each with success. */
function recordingRun(): { run: Run; calls: { args: string[]; env?: NodeJS.ProcessEnv }[] } {
    const calls: { args: string[]; env?: NodeJS.ProcessEnv }[] = [];
    const run: Run = async (_program, args, options) => {
        calls.push({ args, env: options.env });
        return { code: 0, stdout: "", stderr: "" };
    };
    return { run, calls };
}

// MARK: - Where copies are

test("Raycast's copy stays at repo/ with its status beside it; an added one's are under repositories/<copyId>/", () => {
    assert.equal(copyPath("/support", "raycast"), "/support/repo");
    assert.equal(statusPath("/support", "raycast"), "/support/repo-status.json");
    assert.equal(copyPath("/support", "0123456789abcdef"), "/support/repositories/0123456789abcdef/repo");
    assert.equal(statusPath("/support", "0123456789abcdef"), "/support/repositories/0123456789abcdef/status.json");
});

test("a copy of each repository that's on, Raycast's first, then the added ones in order, each with its own git", async () => {
    const support = await temporary();
    const tools = added("https://github.com/Owner/Tools", "dev");
    const off = added("https://git.example.org/team/extensions", undefined, false, [tools.parsed]);
    const third = added("https://github.com/someone/more.git", undefined, true, [tools.parsed, off.parsed]);
    const { run, calls } = recordingRun();
    const answer = [raycastAnswer(), tools.answer, off.answer, { copyId: "nonsense", on: true }, third.answer];
    const { listed, copies } = storeCopies(answer, support, { run, allowProtocols: "https" });

    assert.deepEqual(
        listed.map((entry) => [entry.copyId, entry.on]),
        [
            ["raycast", true],
            [tools.parsed.copyId, true],
            [off.parsed.copyId, false],
            [third.parsed.copyId, true],
        ],
        "every repository listed, the one the rule refuses left out",
    );
    assert.deepEqual(
        copies.map((copy) => copy.entry.copyId),
        ["raycast", tools.parsed.copyId, third.parsed.copyId],
        "a switched-off repository has no copy",
    );
    const [raycast, toolsCopy, thirdCopy] = copies as [(typeof copies)[0], (typeof copies)[0], (typeof copies)[0]];
    assert.equal(raycast.repo.path, path.join(support, "repo"));
    assert.equal(raycast.repo.branch, undefined);
    assert.deepEqual(raycast.copy, { copyId: "raycast", repositoryFolder: "raycast/extensions" });
    assert.equal(raycast.statusPath, path.join(support, "repo-status.json"));
    assert.equal(toolsCopy.repo.path, path.join(support, "repositories", tools.parsed.copyId, "repo"));
    assert.equal(toolsCopy.repo.branch, "dev", "an added copy follows its branch");
    assert.deepEqual(toolsCopy.copy, { copyId: tools.parsed.copyId, repositoryFolder: "owner/tools" });
    assert.equal(toolsCopy.statusPath, path.join(support, "repositories", tools.parsed.copyId, "status.json"));
    assert.equal(thirdCopy.repo.branch, undefined, "no branch: the default one");

    // Each is cloned from its own address, after `--`: Raycast's from Raycast's, an added one as typed.
    for (const copy of copies) await copy.repo.clone().catch(() => undefined);
    const clones = calls.filter((call) => call.args.includes("clone"));
    assert.equal(clones.length, 3);
    const urlOf = (args: string[]) => args[args.indexOf("--") + 1];
    assert.equal(urlOf(clones[0]!.args), "https://github.com/raycast/extensions.git");
    assert.equal(urlOf(clones[1]!.args), "https://github.com/Owner/Tools");
    assert.ok(clones[1]!.args.includes("--branch") && clones[1]!.args.includes("dev"));
    assert.equal(urlOf(clones[2]!.args), "https://github.com/someone/more.git");
    assert.ok(!clones[2]!.args.includes("--branch"));
    for (const clone of clones) assert.equal(clone.env?.GIT_ALLOW_PROTOCOL, "https");
});

test("with Raycast's switched off, only the added ones have copies; an answer that isn't a list has none", async () => {
    const support = await temporary();
    const tools = added("https://github.com/owner/tools");
    assert.deepEqual(
        storeCopies([raycastAnswer(false), tools.answer], support).copies.map((copy) => copy.entry.copyId),
        [tools.parsed.copyId],
    );
    assert.deepEqual(storeCopies([raycastAnswer(false)], support).copies, []);
    assert.deepEqual(storeCopies(undefined, support), { listed: [], copies: [] });
    assert.deepEqual(storeCopies({ copyId: "raycast" }, support), { listed: [], copies: [] });
});

// MARK: - Problems

test("each problem has the sentence Settings shows for it, from the shared fixture", async () => {
    const fixture = JSON.parse(
        await readFile(path.join(import.meta.dirname, "fixtures", "repository-addresses.json"), "utf8"),
    ) as { problems: Record<string, string> };
    assert.deepEqual(Object.keys(fixture.problems).sort(), [...problemKinds].sort());
    for (const kind of problemKinds) {
        assert.equal(problemSentence(kind, "main"), fixture.problems[kind]!.replace("<branch>", "main"), kind);
    }
});

test("a failed clone, refresh or read gets its kind: its own, git's words for an unreachable repository, else failed", () => {
    for (const kind of ["noExtensionsFolder", "empty", "tooMany"] as const) assert.equal(problemOf(new CopyProblem(kind)), kind);
    assert.equal(problemOf(new NoPartialClone("warning: filtering not recognized by server, ignoring", "git clone")), "noPartialClone");
    assert.equal(problemOf(new NoBranch("fatal: Remote branch dev not found in upstream origin", "dev", "git clone")), "noBranch");
    const unreachable = [
        "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
        "remote: Repository not found.\nfatal: repository 'https://github.com/owner/none/' not found",
        "fatal: unable to access 'https://git.example.org/team/x/': Could not resolve host: git.example.org",
        "fatal: unable to access 'https://git.example.org/team/x/': Failed to connect to git.example.org port 443",
        "fatal: unable to access 'https://git.example.org/team/x/': The requested URL returned error: 403",
        "fatal: Authentication failed for 'https://git.example.org/team/x/'",
        "fatal: unable to access 'https://git.example.org/team/x/': SSL certificate problem: self signed certificate",
    ];
    for (const words of unreachable) assert.equal(problemOf(new GitError(words, "git clone")), "unreachable", words);
    assert.equal(
        problemOf(new GitError("fatal: unable to access 'https://git.example.org/x/': The requested URL returned error: 500")),
        "failed",
        "a server's own error isn't the address's",
    );
    assert.equal(problemOf(new GitError("fatal: bad object HEAD")), "failed");
    assert.equal(problemOf(new Error("terminal prompts disabled")), "failed", "only git's words count");
    assert.equal(problemOf("nothing"), "failed");
});

async function manifestAt(repo: string, folder: string, name = folder): Promise<void> {
    await mkdir(path.join(repo, "extensions", folder), { recursive: true });
    await writeFile(
        path.join(repo, "extensions", folder, "package.json"),
        JSON.stringify({ name, title: name, commands: [{ name: "run", title: "Run" }] }),
    );
}

const addedCopy = { copyId: "0123456789abcdef", repositoryFolder: "owner/tools" };
const raycastCopy = { copyId: "raycast", repositoryFolder: "raycast/extensions" };

test("a copy's rows, or the problem that keeps it from having any: no extensions folder, or none Fudge can list", async () => {
    const repo = await temporary();
    await assert.rejects(readCopy(repo, addedCopy), (error) => problemOf(error) === "noExtensionsFolder");
    await writeFile(path.join(repo, "extensions"), "");
    await assert.rejects(readCopy(repo, addedCopy), (error) => problemOf(error) === "noExtensionsFolder", "a file");
    await rm(path.join(repo, "extensions"));
    const elsewhere = await temporary();
    await manifestAt(elsewhere, "alpha");
    await symlink(path.join(elsewhere, "extensions"), path.join(repo, "extensions"));
    await assert.rejects(readCopy(repo, addedCopy), (error) => problemOf(error) === "noExtensionsFolder", "a link isn't followed");
    await rm(path.join(repo, "extensions"));
    await mkdir(path.join(repo, "extensions", "broken"), { recursive: true });
    await writeFile(path.join(repo, "extensions", "broken", "package.json"), "{ not json");
    await assert.rejects(readCopy(repo, addedCopy), (error) => problemOf(error) === "empty");
    await manifestAt(repo, "alpha");
    const entries = await readCopy(repo, addedCopy);
    assert.deepEqual(
        entries.map((entry) => [entry.name, entry.copyId, entry.repositoryFolder]),
        [["alpha", addedCopy.copyId, "owner/tools"]],
    );
});

test("an added repository may list at most 5,000 extensions, counted by folder before any is read; Raycast's has no limit", async () => {
    const repo = await temporary();
    await manifestAt(repo, "alpha");
    // 4,999 more folders without a manifest: 5,000 folders in all.
    const names = Array.from({ length: maxCopyExtensions - 1 }, (_, index) => `x${index}`);
    for (let start = 0; start < names.length; start += 500) {
        await Promise.all(names.slice(start, start + 500).map((name) => mkdir(path.join(repo, "extensions", name))));
    }
    assert.equal((await readCopy(repo, addedCopy)).length, 1, "5,000 is allowed");
    await mkdir(path.join(repo, "extensions", "one-more"));
    await assert.rejects(readCopy(repo, addedCopy), (error) => error instanceof CopyProblem && error.kind === "tooMany");
    assert.equal((await readCopy(repo, raycastCopy)).length, 1, "Raycast's reads any number");
});

// MARK: - Status files

test("a status file is written atomically and read back; Settings' shape, with the list's branch", async () => {
    const support = await temporary();
    const file = statusPath(support, "0123456789abcdef");
    const at = new Date("2026-11-22T22:40:00.000Z");
    const counted = copyStatus(at, "dev", { extensions: 12 });
    assert.deepEqual(counted, { checkedAt: "2026-11-22T22:40:00.000Z", branch: "dev", extensions: 12 });
    await writeStatus(file, counted);
    assert.deepEqual(JSON.parse(await readFile(file, "utf8")), counted);
    assert.deepEqual(await readStatus(file), counted);
    assert.deepEqual(await readdir(path.dirname(file)), ["status.json"], "no file of its own is left beside it");
    assert.equal((await stat(file)).mode & 0o777, 0o644);

    const problem = copyStatus(at, undefined, { problem: "noPartialClone" });
    assert.deepEqual(problem, { checkedAt: "2026-11-22T22:40:00.000Z", problem: "noPartialClone" }, "no branch, none written");
    await writeStatus(file, problem);
    assert.deepEqual(await readStatus(file), problem);

    const raycast = statusPath(support, "raycast");
    await writeStatus(raycast, copyStatus(at, undefined, { extensions: 3600 }));
    assert.deepEqual(await readStatus(raycast), { checkedAt: "2026-11-22T22:40:00.000Z", extensions: 3600 });
});

test("a status file that isn't the store's reads as none", async () => {
    const support = await temporary();
    const file = path.join(support, "status.json");
    assert.equal(await readStatus(file), undefined, "no file");
    const unread: unknown[] = [
        [],
        "text",
        { problem: "noPartialClone" },
        { checkedAt: 5, extensions: 1 },
        { checkedAt: "2026-11-22T22:40:00Z", branch: 5, extensions: 1 },
        { checkedAt: "2026-11-22T22:40:00Z", problem: "unknown" },
        { checkedAt: "2026-11-22T22:40:00Z", extensions: 1.5 },
        { checkedAt: "2026-11-22T22:40:00Z", extensions: -1 },
        { checkedAt: "2026-11-22T22:40:00Z", extensions: "1" },
        { checkedAt: "2026-11-22T22:40:00Z" },
    ];
    for (const value of unread) {
        await writeFile(file, JSON.stringify(value));
        assert.equal(await readStatus(file), undefined, JSON.stringify(value));
    }
    await writeFile(file, "{ not json");
    assert.equal(await readStatus(file), undefined);
    await writeFile(file, JSON.stringify({ checkedAt: "2026-11-22T22:40:00Z", extensions: 1, pad: "x".repeat(4096) }));
    assert.equal(await readStatus(file), undefined, "over 4 KB");
    await rm(file);
    const real = path.join(support, "real.json");
    await writeFile(real, JSON.stringify({ checkedAt: "2026-11-22T22:40:00Z", problem: "noPartialClone" }));
    await symlink(real, file);
    assert.equal(await readStatus(file), undefined, "a link isn't followed");
});

test("a copy waits for ⌘R only when its status says no partial clones for the branch the list gives now", () => {
    const at = new Date("2026-11-22T22:40:00.000Z");
    const noPartial = (branch?: string): CopyStatus => copyStatus(at, branch, { problem: "noPartialClone" });
    assert.equal(waitsForRetry(noPartial(), undefined), true);
    assert.equal(waitsForRetry(noPartial("dev"), "dev"), true);
    assert.equal(waitsForRetry(noPartial("dev"), "main"), false, "a changed branch is tried again");
    assert.equal(waitsForRetry(noPartial("dev"), undefined), false);
    assert.equal(waitsForRetry(noPartial(), "dev"), false);
    assert.equal(waitsForRetry(copyStatus(at, undefined, { problem: "unreachable" }), undefined), false);
    assert.equal(waitsForRetry(copyStatus(at, undefined, { extensions: 3 }), undefined), false);
    assert.equal(waitsForRetry(undefined, undefined), false);
});

// MARK: - Removed repositories

test("a removed repository's copy is deleted, held under remove:<copyId>; listed ones, on or off, and anything else stay", async () => {
    const support = await temporary();
    const kept = added("https://github.com/owner/tools");
    const off = added("https://github.com/owner/other", undefined, false, [kept.parsed]);
    const gone = added("https://github.com/owner/gone");
    const listed: RepositoryEntry[] = [
        { ...kept.parsed, on: true },
        { ...off.parsed, on: false },
    ];
    const root = path.join(support, "repositories");
    for (const copyId of [kept.parsed.copyId, off.parsed.copyId, gone.parsed.copyId, "raycast", "not-a-copy"]) {
        await mkdir(path.join(root, copyId, "repo"), { recursive: true });
    }
    await writeFile(statusPath(support, gone.parsed.copyId), "{}");
    // A file and a link named like a copy id aren't copies.
    await writeFile(path.join(root, "aaaaaaaaaaaaaaaa"), "");
    const outside = await temporary();
    await symlink(outside, path.join(root, "bbbbbbbbbbbbbbbb"));

    assert.deepEqual(await unlistedCopies(support, listed), [gone.parsed.copyId]);
    const held: { key: string; step: () => Promise<void> }[] = [];
    const removing = removeUnlistedCopies(support, listed, (key, step) => {
        return new Promise<void>((resolve, reject) => held.push({ key, step: () => step().then(resolve, reject) }));
    });
    // The folder is listed first; wait for the hold to be asked, for at most 10 s.
    for (let waited = 0; held.length === 0 && waited < 10_000; waited += 10) {
        await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.deepEqual(held.map((entry) => entry.key), [`remove:${gone.parsed.copyId}`]);
    assert.ok(await lstat(path.join(root, gone.parsed.copyId)), "nothing is deleted while the hold waits");
    await held[0]!.step();
    await removing;
    assert.deepEqual(
        (await readdir(root)).sort(),
        [kept.parsed.copyId, off.parsed.copyId, "aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "not-a-copy", "raycast"].sort(),
    );
    assert.deepEqual(await readdir(outside), [], "a link's target is untouched");
    assert.deepEqual(await unlistedCopies(path.join(support, "missing"), listed), [], "no repositories folder");
});

test("removing a copy takes only an added copy id, and a failed removal leaves the rest going", async () => {
    const support = await temporary();
    await assert.rejects(removeCopy(support, "raycast"));
    await assert.rejects(removeCopy(support, "../repo"));
    const first = added("https://github.com/owner/first");
    const second = added("https://github.com/owner/second");
    for (const copyId of [first.parsed.copyId, second.parsed.copyId]) {
        await mkdir(path.join(support, "repositories", copyId), { recursive: true });
    }
    const keys: string[] = [];
    await removeUnlistedCopies(support, [], async (key, step) => {
        keys.push(key);
        if (key === `remove:${first.parsed.copyId}`) throw new Error("couldn't");
        await step();
    });
    assert.deepEqual(keys.sort(), [`remove:${first.parsed.copyId}`, `remove:${second.parsed.copyId}`].sort());
    assert.deepEqual(await readdir(path.join(support, "repositories")), [first.parsed.copyId]);
});
