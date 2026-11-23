// A build's output files and outcome (SPEC-156 A): how the store runs `fudge build` so a build that outlives its store
// keeps its output and says how it ended.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, open, readdir, readFile, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { Worker } from "node:worker_threads";
import {
    buildRecordFiles,
    companionNames,
    installingFolder,
    parseBuildOutcome,
    parseBuildRecord,
    readBuildOutput,
    readBuildRecords,
    recordBuild,
    removeBuildFiles,
    staleTemporaryAge,
    writeBuildRecord,
    type BuildAbout,
    type BuildRecord,
} from "../store-extension/src/build-records.ts";
import { causeOf } from "../store-extension/src/failure.ts";
import { maxOutputBytes, readOutputTail, spawnProgram } from "../store-extension/src/git.ts";

const folders: string[] = [];
after(async () => {
    for (const folder of folders) await rm(folder, { recursive: true, force: true });
});
async function temporaryFolder(): Promise<string> {
    const folder = await mkdtemp(path.join(tmpdir(), "fudge-outcome-"));
    folders.push(folder);
    return folder;
}
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor<T>(check: () => Promise<T | undefined> | T | undefined, limit = 30_000): Promise<T> {
    const start = Date.now();
    for (;;) {
        const value = await Promise.resolve(check()).catch(() => undefined);
        if (value !== undefined && value !== false) return value as T;
        if (Date.now() - start > limit) throw new Error("timed out waiting");
        await delay(20);
    }
}

const about: BuildAbout = {
    name: "alpha",
    dir: "alpha",
    title: "Alpha",
    tree: "aaa1",
    commit: "c0ffee1234",
    updating: false,
    command: ["/Applications/Fudge.app/Contents/Helpers/fudge", "build", "/repo/extensions/alpha"],
};

const record = (pid: number, more: Partial<BuildRecord> = {}): BuildRecord => ({
    pid,
    ...about,
    startedAt: "2026-11-20T12:00:00.000Z",
    deadline: "2026-11-20T12:10:00.000Z",
    ...more,
});

test("spawnProgram with output files: the program's stdout and stderr land in them and in its result", async () => {
    const folder = await temporaryFolder();
    const output = { stdout: path.join(folder, ".a.out"), stderr: path.join(folder, ".a.err") };
    const result = await spawnProgram("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], { timeout: 10_000, output });
    assert.deepEqual(result, { code: 3, stdout: "out\n", stderr: "err\n" });
    assert.equal(await readFile(output.stdout, "utf8"), "out\n");
    assert.equal(await readFile(output.stderr, "utf8"), "err\n");
    assert.equal((await stat(output.stdout)).mode & 0o777, 0o600);
    assert.equal((await stat(output.stderr)).mode & 0o777, 0o600);
});

test("spawnProgram with output files: a time-out adds its line, as with pipes", async () => {
    const folder = await temporaryFolder();
    const output = { stdout: path.join(folder, ".b.out"), stderr: path.join(folder, ".b.err") };
    const result = await spawnProgram("/bin/sh", ["-c", "echo partial; exec sleep 30"], { timeout: 300, output });
    assert.equal(result.stdout, "partial\n");
    assert.equal(result.stderr, "\nsh stopped after 0.3 s");
});

test("spawnProgram reads each file through its own descriptor, so a rename while it runs changes nothing", async () => {
    const folder = await temporaryFolder();
    const output = { stdout: path.join(folder, ".c.out"), stderr: path.join(folder, ".c.err") };
    const { rename } = await import("node:fs/promises");
    const result = await spawnProgram("/bin/sh", ["-c", "sleep 0.3; echo after"], {
        timeout: 10_000,
        output,
        started: () => {
            void rename(output.stdout, path.join(folder, "1.out"));
        },
    });
    assert.equal(result.stdout, "after\n");
    assert.equal(await readFile(path.join(folder, "1.out"), "utf8"), "after\n");
});

test("spawnProgram keeps the last MiB of a longer output, from a line start", async () => {
    const folder = await temporaryFolder();
    const output = { stdout: path.join(folder, ".d.out"), stderr: path.join(folder, ".d.err") };
    // 40,000 numbered lines of 40 bytes: 1.6 MB.
    const script = "i=0; while [ $i -lt 40000 ]; do printf 'line %033d\\n' $i; i=$((i+1)); done";
    const result = await spawnProgram("/bin/sh", ["-c", script], { timeout: 60_000, output });
    assert.equal(result.code, 0);
    assert.ok(result.stdout.length <= maxOutputBytes, `${result.stdout.length}`);
    assert.ok(result.stdout.length > maxOutputBytes - 40);
    assert.match(result.stdout, /^line \d{33}\n/, "it starts at a line");
    assert.ok(result.stdout.endsWith(`line ${"39999".padStart(33, "0")}\n`), "and ends with the last one");
});

test("spawnProgram falls back to pipes when the files can't be made, and a program that can't start leaves its files", async () => {
    const folder = await temporaryFolder();
    const taken = { stdout: path.join(folder, ".e.out"), stderr: path.join(folder, ".e.err") };
    await writeFile(taken.stderr, "someone else's");
    const piped = await spawnProgram("/bin/sh", ["-c", "echo out; echo err >&2"], { timeout: 10_000, output: taken });
    assert.deepEqual(piped, { code: 0, stdout: "out\n", stderr: "err\n" });
    assert.equal(existsSync(taken.stdout), false, "the half-made pair is gone");
    assert.equal(await readFile(taken.stderr, "utf8"), "someone else's", "and nothing else was touched");

    const missing = { stdout: path.join(folder, ".f.out"), stderr: path.join(folder, ".f.err") };
    let started = false;
    const failed = await spawnProgram("/nonexistent/fudge", ["build"], {
        timeout: 10_000,
        output: missing,
        started: () => void (started = true),
    });
    assert.equal(failed.code, -1);
    assert.equal(started, false);
});

test("a child that outlives its worker keeps writing to its files: no SIGPIPE, all its output kept", async () => {
    const folder = await temporaryFolder();
    const output = { stdout: path.join(folder, ".g.out"), stderr: path.join(folder, ".g.err") };
    const go = path.join(folder, "go");
    const marker = path.join(folder, "marker");
    // It waits until the worker is gone, then writes 2 MiB to stdout and its marker.
    const script = `while [ ! -e "$1" ]; do sleep 0.05; done; head -c 2097152 /dev/zero; echo done > "$2"`;
    const worker = new Worker(new URL("./fixtures/outlive-worker.ts", import.meta.url), {
        workerData: { program: "/bin/sh", args: ["-c", script, "sh", go, marker], output },
    });
    const pid = await new Promise<number>((resolve, reject) => {
        worker.once("message", resolve);
        worker.once("error", reject);
    });
    try {
        await worker.terminate();
        await writeFile(go, "");
        await waitFor(() => existsSync(marker));
        assert.equal((await stat(output.stdout)).size, 2 * 1024 * 1024, "the whole output");
    } finally {
        // Only this test's own child, by its pid, and only while it's still that child.
        const state = spawnSync("/bin/ps", ["-o", "stat=,args=", "-p", String(pid)], { encoding: "utf8" }).stdout;
        if (state.includes("head -c") || state.includes(go)) process.kill(pid, "SIGKILL");
    }
});

test("recordBuild renames the output files before it writes the record, and ended removes all four", async () => {
    const supportPath = await temporaryFolder();
    const folder = installingFolder(supportPath);
    await mkdir(folder, { recursive: true });
    const seen: string[][] = [];
    const run = recordBuild(about, 60_000, {
        supportPath,
        now: () => new Date("2026-11-20T12:00:00.000Z"),
        own: new Set(),
        files: {
            write: async (support, written) => {
                seen.push((await readdir(folder)).sort());
                await writeBuildRecord(support, written);
            },
            remove: buildRecordFiles.remove,
        },
    });
    assert.equal(path.dirname(run.output.stdout), folder);
    assert.match(path.basename(run.output.stdout), /^\.[0-9a-f]{16}\.out$/);
    assert.match(path.basename(run.output.stderr), /^\.[0-9a-f]{16}\.err$/);
    const result = await spawnProgram("/bin/sh", ["-c", `echo built; sleep 0.2; echo '{}' > "${folder}/$$.ended.json"`], {
        timeout: 10_000,
        output: run.output,
        started: run.started,
    });
    assert.equal(result.stdout, "built\n");
    const build = run.build()!;
    assert.deepEqual(build, { pid: build.pid, startedAt: "2026-11-20T12:00:00.000Z" });
    const names = companionNames(build.pid);
    assert.deepEqual(seen, [[names.stderr, names.stdout].sort()], "the files had their names before the record");
    assert.deepEqual((await readdir(folder)).sort(), [`${build.pid}.json`, names.outcome, names.stderr, names.stdout].sort());
    await run.ended();
    assert.deepEqual(await readdir(folder), []);
});

test("recordBuild: a run that never started removes its temporary files; a rename that fails is logged and the record still written", async () => {
    const supportPath = await temporaryFolder();
    const folder = installingFolder(supportPath);
    await mkdir(folder, { recursive: true });
    const never = recordBuild(about, 60_000, { supportPath, own: new Set() });
    await writeFile(never.output.stdout, "");
    await writeFile(never.output.stderr, "");
    await never.ended();
    assert.deepEqual(await readdir(folder), []);

    const lines: string[] = [];
    const blocked = recordBuild(about, 60_000, { supportPath, own: new Set(), log: (line) => lines.push(line) });
    await writeFile(blocked.output.stdout, "out");
    await writeFile(blocked.output.stderr, "err");
    // A folder in the way, holding a file, can't be renamed over.
    await mkdir(path.join(folder, "4242.out"));
    await writeFile(path.join(folder, "4242.out", "x"), "");
    blocked.started(4242);
    await waitFor(() => existsSync(path.join(folder, "4242.json")));
    assert.equal(lines.length, 1);
    assert.match(lines[0]!, /^Couldn't keep the output of Alpha's build: /);
    assert.equal(await readFile(path.join(folder, "4242.err"), "utf8"), "err", "the other one has its name");
    await blocked.ended();
    assert.ok(!existsSync(blocked.output.stdout), "the temporary file that couldn't be renamed goes at the end");
});

test("the output's cut keeps a line that starts right at it", async () => {
    const file = path.join(await temporaryFolder(), "out");
    await writeFile(file, "ab\ncd\nef");
    const handle = await open(file, "r");
    try {
        assert.equal(await readOutputTail(handle, 5), "cd\nef", "a cut at a line's start keeps that line");
        assert.equal(await readOutputTail(handle, 4), "ef", "a cut inside a line drops the rest of it");
        assert.equal(await readOutputTail(handle, 2), "ef");
        assert.equal(await readOutputTail(handle, 1), "");
        assert.equal(await readOutputTail(handle, 8), "ab\ncd\nef", "no cut");
    } finally {
        await handle.close();
    }
});

test("the reader keeps a record's companions, deletes old ones without a record, and reads a valid outcome", async () => {
    const supportPath = await temporaryFolder();
    const folder = installingFolder(supportPath);
    await mkdir(folder, { recursive: true });
    const now = new Date();
    const old = new Date(now.getTime() - staleTemporaryAge - 60_000);
    await writeBuildRecord(supportPath, record(11));
    await writeBuildRecord(supportPath, record(12));
    const outcome = { pid: 11, status: 1, endedAt: "2026-11-20T12:05:00.000Z" };
    await writeFile(path.join(folder, "11.ended.json"), JSON.stringify(outcome));
    await writeFile(path.join(folder, "12.ended.json"), JSON.stringify({ ...outcome, pid: 13 }));
    for (const name of ["11.out", "11.err", "12.out", "20.out", "20.err", "20.ended.json", "21.out"]) {
        await writeFile(path.join(folder, name), name);
    }
    // Every file is old, but only those of pid 20 have no record; 21's is young, a run between its rename and its record.
    for (const name of ["11.out", "11.err", "11.ended.json", "12.out", "20.out", "20.err", "20.ended.json"]) {
        await utimes(path.join(folder, name), old, old);
    }
    const found = await readBuildRecords(supportPath, now);
    assert.deepEqual(found, [{ ...record(11), outcome }, record(12)], "12's outcome names another pid, so it has none");
    assert.deepEqual(
        (await readdir(folder)).sort(),
        ["11.ended.json", "11.err", "11.json", "11.out", "12.ended.json", "12.json", "12.out", "21.out"].sort(),
    );
    await removeBuildFiles(supportPath, 11);
    assert.deepEqual((await readdir(folder)).sort(), ["12.ended.json", "12.json", "12.out", "21.out"].sort());
});

test("readBuildOutput: stdout then stderr from the files beside the record, each its last MiB", async () => {
    const supportPath = await temporaryFolder();
    const folder = installingFolder(supportPath);
    await mkdir(folder, { recursive: true });
    assert.equal(await readBuildOutput(supportPath, 31), "", "none");
    await writeFile(path.join(folder, "31.out"), "› npm ci\n");
    await writeFile(path.join(folder, "31.err"), "error: esbuild failed\n");
    assert.equal(await readBuildOutput(supportPath, 31), "› npm ci\n\nerror: esbuild failed\n");
    await writeFile(path.join(folder, "31.out"), `${"x".repeat(100)}\n`.repeat(20_000));
    const long = await readBuildOutput(supportPath, 31);
    assert.ok(long.endsWith("\nerror: esbuild failed\n"));
    assert.ok(long.length <= maxOutputBytes + "\nerror: esbuild failed\n".length);
    assert.match(long, /^x{100}\n/);
});

test("the outcome and record readers read the shared fixtures as the app does", async () => {
    type Case = { file: string; text: string; why?: string } & Record<string, unknown>;
    const read = async (name: string) =>
        JSON.parse(await readFile(new URL(`./fixtures/${name}`, import.meta.url), "utf8")) as { valid: Case[]; invalid: Case[] };
    const outcomes = await read("build-outcome.json");
    for (const item of outcomes.valid) {
        const outcome = parseBuildOutcome(item.file, item.text);
        assert.ok(outcome, item.file);
        assert.equal(outcome.status, item.status, item.file);
        assert.equal(outcome.endedAt, item.endedAt, item.file);
    }
    for (const item of outcomes.invalid) assert.equal(parseBuildOutcome(item.file, item.text), undefined, item.why);
    const records = await read("build-records.json");
    for (const item of records.valid) {
        const parsed = parseBuildRecord(item.file, item.text);
        assert.ok(parsed, item.file);
        for (const key of ["name", "dir", "id", "repository", "title", "updating", "startedAt"] as const) {
            assert.equal(parsed[key], item[key], `${key} in ${item.text}`);
        }
    }
    for (const item of records.invalid) assert.equal(parseBuildRecord(item.file, item.text), undefined, item.why);
});

test("the line for an outcome that can't be saved changes no failure's cause", () => {
    const line = "fudge: couldn't save the build's outcome in /x/installing: Permission denied";
    const cases = [
        { output: "✘ [ERROR] Could not resolve \"left-pad\"", command: "fudge build /x", code: 1 },
        { output: "npm error code ECONNREFUSED\nnpm error network Failed to connect to registry.npmjs.org", command: "fudge build /x", code: 1 },
        { output: "something else went wrong", command: "fudge build /x", code: 1 },
        { output: "Its build stopped before it finished.", command: "fudge build /x" },
    ];
    for (const failure of cases) {
        const without = causeOf(failure);
        const withLine = causeOf({ ...failure, output: `${failure.output}\n${line}` });
        assert.equal(withLine.kind, without.kind, failure.output);
        assert.equal(withLine.text, without.text, failure.output);
    }
});
