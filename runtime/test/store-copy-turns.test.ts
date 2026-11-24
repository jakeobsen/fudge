// Opening and refreshing the copies (SPEC-157 C.1, C.3, C.6, C.7): each copy that's on in turns of its own, in the
// list's order, its rows shown as it's read, its problem shown and written, and a copy waiting for ⌘R left alone at
// open. The copies are fakes, so each path is driven exactly; `store-repositories.test.ts` covers the real reads.
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { copyTurn, fetchCopy, openCopies, openOne, refreshCopies, type CopySteps } from "../store-extension/src/copy-turns.ts";
import { GitError, NoPartialClone, type StoreRepository } from "../store-extension/src/git.ts";
import {
    copyStatus,
    CopyProblem,
    raycastLoadFailure,
    readStatus,
    shownRows,
    writeStatus,
    type CopyState,
    type ProblemKind,
    type StoreCopy,
} from "../store-extension/src/repositories.ts";
import { parseManifest, sections, type RepositoryCopy, type StoreEntry } from "../store-extension/src/catalog.ts";
import { oneAtATime } from "../store-extension/src/store.ts";
import { RAYCAST_COPY } from "../store-extension/src/repository-address.ts";

const folders: string[] = [];
after(async () => {
    for (const folder of folders) await rm(folder, { recursive: true, force: true });
});

async function temporary(): Promise<string> {
    const folder = await mkdtemp(path.join(tmpdir(), "fudge-store-turns-"));
    folders.push(folder);
    return folder;
}

/** A copy's git, faked: whether it exists, and what each step does, every call listed in `calls`. */
type FakeGit = {
    exists?: boolean;
    clone?: () => Promise<void>;
    refresh?: () => Promise<void>;
    needsRefresh?: boolean;
};

function fakeCopy(
    support: string,
    copyId: string,
    git: FakeGit,
    calls: string[],
    branch?: string,
): StoreCopy & { git: FakeGit } {
    let exists = git.exists ?? false;
    const repo = {
        path: path.join(support, copyId, "repo"),
        branch,
        exists: async () => exists,
        clone: async () => {
            calls.push(`clone ${copyId}`);
            await git.clone?.();
            exists = true;
        },
        refresh: async () => {
            calls.push(`refresh ${copyId}`);
            await git.refresh?.();
        },
        remove: async () => {
            calls.push(`remove ${copyId}`);
            exists = false;
        },
        needsRefresh: async () => git.needsRefresh ?? false,
    } as unknown as StoreRepository;
    const raycast = copyId === RAYCAST_COPY.copyId;
    return {
        git,
        entry: {
            copyId,
            folder: raycast ? "raycast/extensions" : `owner/${copyId}`,
            identity: `https://github.com/owner/${copyId}`,
            name: raycast ? "Raycast" : `owner/${copyId}`,
            address: `https://github.com/owner/${copyId}`,
            ...(branch === undefined ? {} : { branch }),
            on: true,
            label: raycast ? "Raycast" : `owner/${copyId}`,
        },
        repo,
        copy: { copyId, repositoryFolder: raycast ? "raycast/extensions" : `owner/${copyId}` },
        statusPath: path.join(support, copyId, "status.json"),
    };
}

const now = new Date("2026-11-22T22:50:00.000Z");

/** The view's steps, recorded: reads (each a count, or an error), problems, toasts, and holds by key. */
function steps(calls: string[], reads: Map<string, number | Error> = new Map()) {
    const problems: { copyId: string; kind: ProblemKind; error?: unknown }[] = [];
    const toasts: string[] = [];
    const held: string[] = [];
    const run: CopySteps = {
        others: {
            check: async () => void calls.push("check"),
            hold: <T>(key: string, step: () => Promise<T>) => {
                held.push(key);
                return step();
            },
        },
        now: () => now,
        read: async (copy) => {
            calls.push(`read ${copy.entry.copyId}`);
            const result = reads.get(copy.entry.copyId) ?? 1;
            if (result instanceof Error) throw result;
            return result;
        },
        problem: (copy, kind, error) => void problems.push({ copyId: copy.entry.copyId, kind, error }),
        fetching: (copy, first) => {
            toasts.push(`${first ? "download" : "update"} ${copy.entry.copyId}`);
            return (failure) => void toasts.push(failure ? `failed ${copy.entry.copyId} ${failure.kind}` : `done ${copy.entry.copyId}`);
        },
    };
    return { run, problems, toasts, held };
}

// MARK: - One copy's fetch

test("a copy's first fetch clones and reads it, and writes how many extensions it lists", async () => {
    const support = await temporary();
    const calls: string[] = [];
    const copy = fakeCopy(support, "0123456789abcdef", {}, calls, "dev");
    const { run, problems, toasts } = steps(calls, new Map([["0123456789abcdef", 7]]));
    await fetchCopy(copy, run);
    assert.deepEqual(calls, ["clone 0123456789abcdef", "read 0123456789abcdef"]);
    assert.deepEqual(problems, []);
    assert.deepEqual(toasts, ["download 0123456789abcdef", "done 0123456789abcdef"]);
    assert.deepEqual(await readStatus(copy.statusPath), { checkedAt: now.toISOString(), branch: "dev", extensions: 7 });
});

test("a refresh that fails shows the copy's problem and writes it, and the copy isn't read again", async () => {
    const support = await temporary();
    for (const [error, kind] of [
        [new NoPartialClone("warning: filtering not recognized by server, ignoring", "git fetch"), "noPartialClone"],
        [new GitError("fatal: could not read Username for 'https://github.com': terminal prompts disabled"), "unreachable"],
        [new Error("disk full"), "failed"],
    ] as const) {
        const calls: string[] = [];
        const copy = fakeCopy(support, "0123456789abcdef", { exists: true, refresh: async () => Promise.reject(error) }, calls);
        const { run, problems, toasts } = steps(calls);
        await fetchCopy(copy, run);
        assert.deepEqual(calls, ["refresh 0123456789abcdef"], "rows of the earlier refresh stay as they were");
        assert.deepEqual(problems, [{ copyId: "0123456789abcdef", kind, error }]);
        assert.deepEqual(toasts, ["update 0123456789abcdef", `failed 0123456789abcdef ${kind}`]);
        assert.deepEqual(await readStatus(copy.statusPath), { checkedAt: now.toISOString(), problem: kind });
    }
});

test("a fetch whose copy has a problem of its own writes that problem", async () => {
    const support = await temporary();
    const calls: string[] = [];
    const copy = fakeCopy(support, "0123456789abcdef", {}, calls);
    const { run, problems } = steps(calls, new Map([["0123456789abcdef", new CopyProblem("noExtensionsFolder")]]));
    await fetchCopy(copy, run);
    assert.deepEqual(problems.map((problem) => problem.kind), ["noExtensionsFolder"]);
    assert.deepEqual(await readStatus(copy.statusPath), { checkedAt: now.toISOString(), problem: "noExtensionsFolder" });
});

test("a copy's turn is held under refresh:<copyId>, then goes into the queue", async () => {
    const support = await temporary();
    const calls: string[] = [];
    const { run, held } = steps(calls);
    await copyTurn(fakeCopy(support, "raycast", { exists: true }, calls), run);
    await copyTurn(fakeCopy(support, "0123456789abcdef", { exists: true }, calls), run);
    assert.deepEqual(held, ["refresh:raycast", "refresh:0123456789abcdef"]);
});

// MARK: - Opening one copy

test("at open: a missing copy is cloned; one there is read, and refreshed only when it's a day old or asked", async () => {
    const support = await temporary();
    const cases: [FakeGit, boolean, string[]][] = [
        [{ exists: false }, false, ["check", "clone c", "read c"]],
        [{ exists: true }, false, ["check", "read c"]],
        [{ exists: true, needsRefresh: true }, false, ["check", "read c", "refresh c", "read c"]],
        [{ exists: true }, true, ["check", "read c", "refresh c", "read c"]],
    ];
    for (const [git, retry, expected] of cases) {
        const calls: string[] = [];
        const copy = fakeCopy(await temporary(), "c", git, calls);
        await openOne(copy, retry, steps(calls).run);
        assert.deepEqual(calls, expected, JSON.stringify({ git, retry }));
    }
    void support;
});

test("at open: a copy git can't read is cloned again, held under reload:<copyId>; one whose content has a problem isn't", async () => {
    const calls: string[] = [];
    const broken = fakeCopy(await temporary(), "0123456789abcdef", { exists: true }, calls);
    let reads = 0;
    const recorded = steps(calls);
    const run: CopySteps = {
        ...recorded.run,
        read: async (copy) => {
            calls.push(`read ${copy.entry.copyId}`);
            reads += 1;
            if (reads === 1) throw new GitError("fatal: not a git repository");
            return 3;
        },
    };
    await openOne(broken, false, run);
    assert.deepEqual(calls, ["check", "read 0123456789abcdef", "remove 0123456789abcdef", "clone 0123456789abcdef", "read 0123456789abcdef"]);
    assert.deepEqual(recorded.held, ["reload:0123456789abcdef", "refresh:0123456789abcdef"]);

    const emptyCalls: string[] = [];
    const empty = fakeCopy(await temporary(), "0123456789abcdef", { exists: true }, emptyCalls);
    const emptySteps = steps(emptyCalls, new Map([["0123456789abcdef", new CopyProblem("empty")]]));
    await openOne(empty, false, emptySteps.run);
    assert.deepEqual(emptyCalls, ["check", "read 0123456789abcdef"], "not removed or cloned again");
    assert.deepEqual(emptySteps.problems.map((problem) => problem.kind), ["empty"]);
    assert.deepEqual(await readStatus(empty.statusPath), { checkedAt: now.toISOString(), problem: "empty" }, "written: it had none");
});

test("at open without a fetch, a copy's status is written only when it has none yet", async () => {
    const calls: string[] = [];
    const copy = fakeCopy(await temporary(), "0123456789abcdef", { exists: true }, calls);
    const { run } = steps(calls, new Map([["0123456789abcdef", 4]]));
    await openOne(copy, false, run);
    assert.deepEqual(await readStatus(copy.statusPath), { checkedAt: now.toISOString(), extensions: 4 });
    // A problem from an earlier refresh stays until a fetch: a read alone doesn't replace it.
    const earlier = copyStatus(new Date("2026-11-22T20:00:00.000Z"), undefined, { problem: "unreachable" });
    await writeStatus(copy.statusPath, earlier);
    await openOne(copy, false, run);
    assert.deepEqual(await readStatus(copy.statusPath), earlier);
});

test("a copy whose server can't do partial clones waits for ⌘R at open, even a day old; its rows and problem show", async () => {
    const calls: string[] = [];
    const copy = fakeCopy(await temporary(), "0123456789abcdef", { exists: true, needsRefresh: true }, calls, "dev");
    await writeStatus(copy.statusPath, copyStatus(now, "dev", { problem: "noPartialClone" }));
    const waiting = steps(calls);
    await openOne(copy, false, waiting.run);
    assert.deepEqual(calls, ["read 0123456789abcdef"], "no clone or refresh");
    assert.deepEqual(waiting.problems, [{ copyId: "0123456789abcdef", kind: "noPartialClone", error: undefined }]);

    // With no copy left (a stopped clone deletes it), only its problem.
    const gone: string[] = [];
    const cloneless = fakeCopy(await temporary(), "0123456789abcdef", { exists: false }, gone);
    await writeStatus(cloneless.statusPath, copyStatus(now, undefined, { problem: "noPartialClone" }));
    const none = steps(gone);
    await openOne(cloneless, false, none.run);
    assert.deepEqual(gone, []);
    assert.deepEqual(none.problems.map((problem) => problem.kind), ["noPartialClone"]);

    // The load-error view's Refresh tries it, and so does a changed branch.
    const retried: string[] = [];
    await openOne(fakeCopy(path.dirname(path.dirname(copy.statusPath)), "0123456789abcdef", { exists: true }, retried, "dev"), true, steps(retried).run);
    assert.ok(retried.includes("refresh 0123456789abcdef"), "retry");
    const changed: string[] = [];
    await openOne(fakeCopy(path.dirname(path.dirname(copy.statusPath)), "0123456789abcdef", { exists: true }, changed, "main"), false, steps(changed).run);
    assert.deepEqual(changed, ["check", "read 0123456789abcdef", "refresh 0123456789abcdef", "read 0123456789abcdef"], "another branch is fetched at once");
});

test("at open, a copy whose status names another branch than the list's is refreshed, though it isn't a day old", async () => {
    const calls: string[] = [];
    const copy = fakeCopy(await temporary(), "0123456789abcdef", { exists: true }, calls, "next");
    await writeStatus(copy.statusPath, copyStatus(now, "dev", { extensions: 2 }));
    await openOne(copy, false, steps(calls).run);
    assert.deepEqual(calls, ["check", "read 0123456789abcdef", "refresh 0123456789abcdef", "read 0123456789abcdef"]);
    const same: string[] = [];
    const kept = fakeCopy(path.dirname(path.dirname(copy.statusPath)), "0123456789abcdef", { exists: true }, same, "next");
    await openOne(kept, false, steps(same).run);
    assert.deepEqual(same, ["check", "read 0123456789abcdef"], "the same branch waits for its day");
});

// MARK: - Every copy

/** A gate: `wait` resolves once `open` is called. */
function gate() {
    let open = () => {};
    const wait = new Promise<void>((resolve) => (open = resolve));
    return { wait, open };
}

test("copies open in the list's order, each in its own turn: an install pressed meanwhile waits for one copy, not all", async () => {
    const calls: string[] = [];
    const support = await temporary();
    const first = gate();
    const raycast = fakeCopy(support, "raycast", { clone: () => first.wait }, calls);
    const added = fakeCopy(support, "0123456789abcdef", {}, calls);
    const opening = openCopies([raycast, added], false, steps(calls).run);
    // Raycast's clone has started, for at most 10 s; then an install is pressed while it runs.
    for (let waited = 0; !calls.includes("clone raycast") && waited < 10_000; waited += 5) {
        await new Promise((resolve) => setTimeout(resolve, 5));
    }
    const install = oneAtATime(async () => void calls.push("install"));
    first.open();
    await Promise.all([opening, install]);
    assert.deepEqual(calls, [
        "check",
        "clone raycast",
        "read raycast",
        "install",
        "check",
        "clone 0123456789abcdef",
        "read 0123456789abcdef",
    ]);
});

test("one copy failing never stops another; ⌘R fetches every copy once, one waiting for ⌘R included", async () => {
    const calls: string[] = [];
    const support = await temporary();
    const raycast = fakeCopy(support, "raycast", { exists: true, refresh: () => Promise.reject(new GitError("fatal: Repository not found")) }, calls);
    const waiting = fakeCopy(support, "0123456789abcdef", { exists: true }, calls);
    await writeStatus(waiting.statusPath, copyStatus(now, undefined, { problem: "noPartialClone" }));
    const run = steps(calls);
    await refreshCopies([raycast, waiting], run.run);
    assert.deepEqual(calls, ["refresh raycast", "refresh 0123456789abcdef", "read 0123456789abcdef"]);
    assert.deepEqual(run.problems.map((problem) => [problem.copyId, problem.kind]), [["raycast", "unreachable"]]);
    assert.deepEqual(await readStatus(waiting.statusPath), { checkedAt: now.toISOString(), extensions: 1 }, "tried again, and it worked");

    // An open where the first copy throws past its own handling still opens the next.
    const thrown: string[] = [];
    const broken = fakeCopy(support, "raycast", { exists: true }, thrown);
    const throwing = steps(thrown);
    const failingOpen: CopySteps = {
        ...throwing.run,
        others: {
            check: async () => void thrown.push("check"),
            hold: async (key, step) => {
                if (key.startsWith("reload:")) throw new Error("couldn't remove the copy");
                return step();
            },
        },
        read: async (copy) => {
            thrown.push(`read ${copy.entry.copyId}`);
            if (copy.entry.copyId === "raycast") throw new GitError("fatal: bad object HEAD");
            return 2;
        },
    };
    await openCopies([broken, fakeCopy(support, "fedcba9876543210", { exists: true }, thrown)], false, failingOpen);
    assert.deepEqual(thrown, ["check", "read raycast", "check", "read fedcba9876543210"]);
    assert.deepEqual(throwing.problems.map((problem) => [problem.copyId, problem.kind]), [["raycast", "failed"]]);
});

// MARK: - What the list shows

test("the list shows the rows of the copies read so far, by title, with each copy's trees and commit", () => {
    const support = "/support";
    const raycast = fakeCopy(support, "raycast", {}, []);
    const added = fakeCopy(support, "0123456789abcdef", {}, []);
    const off = fakeCopy(support, "fedcba9876543210", {}, []);
    const zeta = parseManifest("zeta", { name: "zeta", title: "Zeta", commands: [{ name: "a", title: "A" }] })!;
    const alpha = parseManifest("alpha", { name: "alpha", title: "Alpha", commands: [{ name: "a", title: "A" }] }, added.copy)!;
    const states = new Map<string, CopyState>([
        ["raycast", { rows: { entries: [zeta], trees: new Map([["zeta", "t1"]]), commit: "c1" } }],
        ["0123456789abcdef", { rows: { entries: [alpha], trees: new Map([["alpha", "t2"]]), commit: "c2" }, problem: { kind: "unreachable" } }],
        ["fedcba9876543210", { rows: { entries: [alpha], trees: new Map(), commit: "c3" } }],
    ]);
    const shown = shownRows([raycast, added], states);
    assert.deepEqual(shown.entries.map((entry) => [entry.name, entry.copyId]), [["alpha", "0123456789abcdef"], ["zeta", "raycast"]]);
    assert.deepEqual([...shown.commits], [["raycast", "c1"], ["0123456789abcdef", "c2"]], "a copy no longer on shows nothing");
    assert.equal(shown.trees.get("0123456789abcdef")?.get("alpha"), "t2");
    assert.deepEqual(shownRows([raycast, added, off], new Map()).entries, [], "nothing read yet");
    void off;
});

test("rows with the same title: Raycast's official repository's first, then the added ones in their Settings order (SPEC-166)", () => {
    const support = "/support";
    const raycast = fakeCopy(support, "raycast", {}, []);
    // Settings order: A, then B, though B's copy id sorts first.
    const a = fakeCopy(support, "ffffffffffffffff", {}, []);
    const b = fakeCopy(support, "0000000000000000", {}, []);
    const github = (name: string, copy?: RepositoryCopy) =>
        parseManifest(name, { name, title: "GitHub", commands: [{ name: "a", title: "A" }] }, copy)!;
    const ofRaycast = github("zz");
    const ofA = github("aa", a.copy);
    const ofB = github("github", b.copy);
    const rows = (entries: StoreEntry[]) => ({ rows: { entries, trees: new Map<string, string>(), commit: "c" } });
    const states = new Map<string, CopyState>([
        ["0000000000000000", rows([ofB])],
        ["raycast", rows([ofRaycast])],
        ["ffffffffffffffff", rows([ofA])],
    ]);
    const order = ["raycast", "ffffffffffffffff", "0000000000000000"];
    const copyIds = (entries: StoreEntry[]) => entries.map((entry) => entry.copyId);
    assert.deepEqual(copyIds(shownRows([raycast, a, b], states).entries), order);
    // Both halves of the list: Raycast's and B's installed, A's not.
    const record = (dir: string, repository?: string) => ({
        tree: "t",
        commit: "c",
        installedAt: "2026-11-23T00:00:00.000Z",
        dir,
        ...(repository === undefined ? {} : { repository }),
    });
    const installed = { zz: record("zz"), "owner+0000000000000000+github": record("github", "owner/0000000000000000") };
    const split = sections([ofB, ofA, ofRaycast], installed, order);
    assert.deepEqual(copyIds(split.installed), ["raycast", "0000000000000000"]);
    assert.deepEqual(copyIds(split.other), ["ffffffffffffffff"]);
    assert.deepEqual(copyIds(sections([ofB, ofA, ofRaycast], {}, order).other), order, "all three in one half");
    // With no order, today's: by name, then copy id.
    assert.deepEqual(copyIds(sections([ofB, ofA, ofRaycast], {}, []).other), ["ffffffffffffffff", "0000000000000000", "raycast"]);
});

test("Raycast's load-error view shows only when no copy could be read and Raycast's failed", () => {
    const raycast = fakeCopy("/support", "raycast", {}, []);
    const added = fakeCopy("/support", "0123456789abcdef", {}, []);
    const error = new GitError("fatal: unable to access 'https://github.com/raycast/extensions.git/': Could not resolve host: github.com");
    const failed: CopyState = { problem: { kind: "unreachable", error } };
    const rows: CopyState = { rows: { entries: [], trees: new Map(), commit: "c" } };
    assert.deepEqual(raycastLoadFailure([raycast, added], new Map([["raycast", failed], ["0123456789abcdef", failed]])), { error });
    assert.equal(raycastLoadFailure([raycast, added], new Map([["raycast", failed], ["0123456789abcdef", rows]])), undefined, "another copy was read");
    assert.equal(raycastLoadFailure([raycast], new Map([["raycast", { ...rows, problem: failed.problem }]])), undefined, "its own rows from before");
    assert.equal(raycastLoadFailure([added], new Map([["0123456789abcdef", failed]])), undefined, "Raycast's is off: problems are rows");
    assert.equal(raycastLoadFailure([raycast], new Map([["raycast", { problem: { kind: "noPartialClone" } }]])), undefined, "no failure to show");
    assert.equal(raycastLoadFailure([], new Map()), undefined);
});

test("the status file a copy's turn writes is the shape Settings reads", async () => {
    const support = await temporary();
    const copy = fakeCopy(support, "0123456789abcdef", {}, [], "dev");
    await fetchCopy(copy, steps([]).run);
    const written = JSON.parse(await readFile(copy.statusPath, "utf8")) as Record<string, unknown>;
    assert.deepEqual(Object.keys(written).sort(), ["branch", "checkedAt", "extensions"]);
    assert.equal(new Date(written.checkedAt as string).toISOString(), written.checkedAt);
});
