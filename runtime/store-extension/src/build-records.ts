// The store's record of each `fudge build` it runs (SPEC-153 C): `<supportPath>/installing/<pid>.json`, written once the
// build has a pid and removed when its run ends. Unloading the store doesn't stop its build, so a store opened later reads
// these to know a build that an earlier one left running. Turning the store off keeps the folder, as it keeps
// `installed.json`.
import { randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, readdir, rename, rm, writeFile, type FileHandle } from "node:fs/promises";
import path from "node:path";
import { extensionId, isValidRepositoryFolder, raycastFolder } from "../../src/extension-id.ts";
import { isValidFolder, isValidName } from "./catalog.ts";
import { readRegularFile } from "./files.ts";
import { readOutputTail, spawnProgram, type Run } from "./git.ts";
import { shortTimeout } from "./timeouts.ts";

/** One running `fudge build`: what the store would have recorded in `installed.json` when it finished, and how to know the
 * process. `tree` is missing when the store couldn't read the folder's version. */
export type BuildRecord = {
    pid: number;
    name: string;
    dir: string;
    /** For an added repository's build (SPEC-157 E.3): the id the extension gets there, so an adopted build is recorded
     * under it. Raycast's builds have neither this nor `repository`. */
    id?: string;
    /** The folder of the repository the build is from, as its `--repository` names it; only an added repository's. */
    repository?: string;
    title: string;
    tree?: string;
    commit: string;
    updating: boolean;
    startedAt: string;
    /** The start plus the timeout the run was given: when the session that started it would have stopped it. */
    deadline: string;
    /** The program and its arguments, as `ps` shows them joined with spaces. */
    command: string[];
};

/** The pids of the builds this session started: the worker's module, so one store session. Its poll never settles them,
 * since they end through their own run. */
export const ownBuilds = new Set<number>();

export function installingFolder(supportPath: string): string {
    return path.join(supportPath, "installing");
}

/** The most a record may hold: a few hundred bytes, and a long path in its command. */
const maxRecordBytes = 64 * 1024;

/** A temporary file older than this is a write that never finished, since no write takes that long. */
export const staleTemporaryAge = 60 * 60 * 1000;

/**
 * Writes `record` atomically: a temporary file whose name starts with a dot, which the reader skips, renamed to
 * `<pid>.json`. A write that fails deletes its temporary file.
 */
export async function writeBuildRecord(supportPath: string, record: BuildRecord): Promise<void> {
    const folder = installingFolder(supportPath);
    await mkdir(folder, { recursive: true });
    const temporary = path.join(folder, `.${record.pid}.${randomBytes(8).toString("hex")}.tmp`);
    try {
        await writeFile(temporary, `${JSON.stringify(record, null, 2)}\n`, { flag: "wx" });
        await rename(temporary, path.join(folder, `${record.pid}.json`));
    } catch (error) {
        await rm(temporary, { force: true }).catch(() => undefined);
        throw error;
    }
}

export async function removeBuildRecord(supportPath: string, pid: number): Promise<void> {
    await rm(path.join(installingFolder(supportPath), `${pid}.json`), { force: true });
}

/** How the store writes and removes its records; tests slow them down or make them fail. */
export type BuildRecordFiles = {
    write: (supportPath: string, record: BuildRecord) => Promise<void>;
    remove: (supportPath: string, pid: number) => Promise<void>;
};
export const buildRecordFiles: BuildRecordFiles = { write: writeBuildRecord, remove: removeBuildRecord };

const isTime = (value: unknown): value is string => {
    if (typeof value !== "string") return false;
    const time = new Date(value);
    return !Number.isNaN(time.getTime()) && time.toISOString() === value;
};

/** The record in `text`, read from the file `fileName`, or undefined when the name isn't `<pid>.json` or a field isn't
 * valid. Nothing in it is used to build a path until it has passed. */
export function parseBuildRecord(fileName: string, text: string): BuildRecord | undefined {
    const match = /^([1-9][0-9]{0,9})\.json$/.exec(fileName);
    if (!match) return undefined;
    let object: unknown;
    try {
        object = JSON.parse(text);
    } catch {
        return undefined;
    }
    if (typeof object !== "object" || object === null || Array.isArray(object)) return undefined;
    const { pid, name, dir, id, repository, title, tree, commit, updating, startedAt, deadline, command } = object as Record<
        string,
        unknown
    >;
    if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid <= 0 || pid !== Number(match[1])) return undefined;
    if (!isValidName(name) || !isValidFolder(dir)) return undefined;
    // An added repository's build names its folder and the id it gets there, the folder's segments and the name;
    // Raycast's names neither (SPEC-157 E.3).
    if ((id === undefined) !== (repository === undefined)) return undefined;
    if (repository !== undefined) {
        if (!isValidRepositoryFolder(repository) || repository === raycastFolder) return undefined;
        if (typeof id !== "string" || id !== extensionId(name, repository)) return undefined;
    }
    if (typeof title !== "string" || typeof commit !== "string" || typeof updating !== "boolean") return undefined;
    if (tree !== undefined && typeof tree !== "string") return undefined;
    if (!isTime(startedAt) || !isTime(deadline)) return undefined;
    if (!Array.isArray(command) || command.length === 0 || !command.every((part) => typeof part === "string")) {
        return undefined;
    }
    return {
        pid,
        name,
        dir,
        ...(typeof id === "string" && typeof repository === "string" ? { id, repository } : {}),
        title,
        ...(tree === undefined ? {} : { tree }),
        commit,
        updating,
        startedAt,
        deadline,
        command: command as string[],
    };
}

/** What `fudge build --outcome` wrote when it ended (SPEC-156 A.3): its exit status and its own end time. */
export type BuildOutcome = { pid: number; status: number; endedAt: string };

/** The most an outcome may hold: a few dozen bytes. */
const maxOutcomeBytes = 4 * 1024;

/** The outcome in `text`, read from `<pid>.ended.json`: only when it parses, its `pid` is the file's, `status` is an integer
 * from 0 to 255 and `endedAt` is a time. */
export function parseBuildOutcome(fileName: string, text: string): BuildOutcome | undefined {
    const match = /^([1-9][0-9]{0,9})\.ended\.json$/.exec(fileName);
    if (!match) return undefined;
    let object: unknown;
    try {
        object = JSON.parse(text);
    } catch {
        return undefined;
    }
    if (typeof object !== "object" || object === null || Array.isArray(object)) return undefined;
    const { pid, status, endedAt } = object as Record<string, unknown>;
    if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid !== Number(match[1])) return undefined;
    if (typeof status !== "number" || !Number.isInteger(status) || status < 0 || status > 255) return undefined;
    if (!isTime(endedAt)) return undefined;
    return { pid, status, endedAt };
}

/** A record as the reader finds it, with its build's outcome when one was written and is valid. */
export type FoundBuildRecord = BuildRecord & { outcome?: BuildOutcome };

/** A record's companion: `<pid>.out`, `<pid>.err` or `<pid>.ended.json`, by its pid. */
const companion = /^([1-9][0-9]{0,9})\.(?:out|err|ended\.json)$/;

/**
 * Every valid record in `installing/`, by pid, read apart from the store's copy, with its outcome. A name that starts with
 * a dot is a write's temporary file: it's skipped, and deleted only once it's older than an hour. A record's companions
 * (its output files and outcome) are kept while the record is there, and one without its record is deleted once it's
 * older than an hour, since a run renames its output files just before it writes its record (SPEC-156 A.4). Anything
 * else that isn't a valid record (a bad name, a broken file, a link, a folder) is deleted.
 */
export async function readBuildRecords(supportPath: string, now: Date = new Date()): Promise<FoundBuildRecord[]> {
    const folder = installingFolder(supportPath);
    const names = await readdir(folder).catch(() => [] as string[]);
    const records: FoundBuildRecord[] = [];
    const companions: string[] = [];
    const removeWhenOld = async (file: string) => {
        const info = await lstat(file).catch(() => undefined);
        if (info && now.getTime() - info.mtimeMs > staleTemporaryAge) {
            await rm(file, { force: true, recursive: true }).catch(() => undefined);
        }
    };
    for (const name of names) {
        const file = path.join(folder, name);
        if (name.startsWith(".")) {
            await removeWhenOld(file);
            continue;
        }
        if (companion.test(name)) {
            companions.push(name);
            continue;
        }
        const text = await readRegularFile(file, maxRecordBytes).catch(() => undefined);
        const record = text === undefined ? undefined : parseBuildRecord(name, text);
        if (record) records.push(record);
        else await rm(file, { force: true, recursive: true }).catch(() => undefined);
    }
    const pids = new Set(records.map((record) => record.pid));
    for (const name of companions) {
        if (!pids.has(Number(companion.exec(name)![1]))) await removeWhenOld(path.join(folder, name));
    }
    for (const record of records) {
        const name = companionNames(record.pid).outcome;
        if (!companions.includes(name)) continue;
        const text = await readRegularFile(path.join(folder, name), maxOutcomeBytes).catch(() => undefined);
        const outcome = text === undefined ? undefined : parseBuildOutcome(name, text);
        if (outcome) record.outcome = outcome;
    }
    return records.sort((a, b) => a.pid - b.pid);
}

/**
 * A recorded build's output, from the files beside its record: stdout then stderr, each its last `maxOutputBytes`, the
 * empty ones left out. A missing file reads as empty.
 */
export async function readBuildOutput(supportPath: string, pid: number): Promise<string> {
    const names = companionNames(pid);
    const parts: string[] = [];
    for (const name of [names.stdout, names.stderr]) {
        const text = await readOutputFile(path.join(installingFolder(supportPath), name));
        if (text.trim().length > 0) parts.push(text);
    }
    return parts.join("\n");
}

async function readOutputFile(file: string): Promise<string> {
    let handle: FileHandle | undefined;
    try {
        handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
        if (!(await handle.stat()).isFile()) return "";
        return await readOutputTail(handle);
    } catch {
        return "";
    } finally {
        await handle?.close().catch(() => undefined);
    }
}

/** Deletes a settled record and everything beside it. */
export async function removeBuildFiles(supportPath: string, pid: number): Promise<void> {
    const folder = installingFolder(supportPath);
    const names = companionNames(pid);
    for (const name of [names.stdout, names.stderr, names.outcome, `${pid}.json`]) {
        await rm(path.join(folder, name), { force: true }).catch(() => undefined);
    }
}

/** What `ps` says of a process: its state and its arguments. */
export type ProcessState = { stat: string; args: string };

/**
 * How the store looks at a recorded build's process. `state` is undefined when there's no such process, and throws when
 * `ps` couldn't say.
 */
export type ProcessProbe = {
    alive: (pid: number) => boolean;
    state: (pid: number) => Promise<ProcessState | undefined>;
    terminate: (pid: number) => void;
};

/** `ps -o stat=,args=`'s line: the state, then the arguments. */
export function parseProcessLine(output: string): ProcessState | undefined {
    const line = output.split("\n").find((text) => text.trim().length > 0);
    const match = line === undefined ? null : /^\s*(\S+)(?:\s+(.*?))?\s*$/.exec(line);
    return match ? { stat: match[1]!, args: match[2] ?? "" } : undefined;
}

/** The real checks: `kill(pid, 0)`, where `ESRCH` and `EPERM` alike mean it isn't the store's, and `/bin/ps`. */
export function systemProbe(run: Run = spawnProgram): ProcessProbe {
    return {
        alive: (pid) => {
            try {
                process.kill(pid, 0);
                return true;
            } catch {
                return false;
            }
        },
        state: async (pid) => {
            const result = await run("/bin/ps", ["-ww", "-o", "stat=,args=", "-p", String(pid)], { timeout: shortTimeout });
            // No such process: `ps` lists nothing and exits 1.
            if (result.code === 1 && result.stdout.trim() === "") return undefined;
            const state = result.code === 0 ? parseProcessLine(result.stdout) : undefined;
            if (!state) throw new Error(`ps couldn't say what ${pid} is: ${result.stderr.trim()}`);
            return state;
        },
        terminate: (pid) => {
            try {
                process.kill(pid, "SIGTERM");
            } catch {
                // It has ended since.
            }
        },
    };
}

/**
 * Whether the recorded build is still running: its pid is alive, `ps` shows a state that doesn't start with `Z` (macOS
 * adds modifier letters, such as `ZN`) and no `<defunct>`, and the process is the record's command, so a reused pid isn't
 * taken for the build. An orphaned build that has ended is a zombie of the host, which `kill(pid, 0)` still finds.
 * Undefined when `ps` couldn't say: the record is checked again later, and nothing is settled or signalled meanwhile.
 */
export async function stillRunning(record: BuildRecord, probe: ProcessProbe): Promise<boolean | undefined> {
    if (!probe.alive(record.pid)) return false;
    let state: ProcessState | undefined;
    try {
        state = await probe.state(record.pid);
    } catch {
        return undefined;
    }
    if (!state || state.stat.startsWith("Z") || state.args.includes("<defunct>")) return false;
    return state.args === record.command.join(" ");
}

/** What `recordBuild` records besides the pid and the times. */
export type BuildAbout = Omit<BuildRecord, "pid" | "startedAt" | "deadline">;

/** The files beside a record (SPEC-156 A): the build's stdout and stderr, and the outcome `fudge build --outcome` writes. */
export function companionNames(pid: number): { stdout: string; stderr: string; outcome: string } {
    return { stdout: `${pid}.out`, stderr: `${pid}.err`, outcome: `${pid}.ended.json` };
}

/** One build, as the app tells it apart: its pid and its record's start, since a pid can come back (SPEC-156 C.1). */
export type BuildId = { pid: number; startedAt: string };

/** `recordBuild`'s handle on one run. `build` is undefined until `started` has run. */
export type RecordedRun = {
    output: { stdout: string; stderr: string };
    started: (pid: number) => void;
    ended: () => Promise<void>;
    build: () => BuildId | undefined;
};

/**
 * The record of one run of `fudge build`, and its output files (SPEC-156 A.2). `output` names two temporary files in
 * `installing/` (dot names, which the reader skips) for the run to make. `started` renames them to `<pid>.out` and
 * `<pid>.err` and then writes the record, in that one promise, so a record never exists before its output files have
 * their names. `ended`, called when the run has resolved, whatever its result, waits for that to settle and then removes
 * the output files, the outcome and then the record (or only the temporary files, when the build never started), so a
 * run that ends at once can't leave a record behind. Neither throws: a file that can't be renamed, written or removed is
 * logged, and the install goes on with the result it would have had.
 */
export function recordBuild(
    about: BuildAbout,
    timeout: number,
    options: {
        supportPath: string;
        now?: () => Date;
        log?: (line: string) => void;
        files?: BuildRecordFiles;
        own?: Set<number>;
    },
): RecordedRun {
    const { supportPath, now = () => new Date(), log = () => {}, files = buildRecordFiles, own = ownBuilds } = options;
    const reason = (error: unknown) => (error instanceof Error ? error.message : String(error));
    const folder = installingFolder(supportPath);
    const random = randomBytes(8).toString("hex");
    const output = { stdout: path.join(folder, `.${random}.out`), stderr: path.join(folder, `.${random}.err`) };
    let pid: number | undefined;
    let startedAt: string | undefined;
    let write: Promise<void> = Promise.resolve();
    // A missing temporary file is a run that writes to pipes (its files couldn't be made) or a test's fake: nothing to say.
    const renamed = async (from: string, to: string) => {
        try {
            await rename(from, to);
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
                log(`Couldn't keep the output of ${about.title}'s build: ${reason(error)}`);
            }
        }
    };
    return {
        output,
        build: () => (pid === undefined || startedAt === undefined ? undefined : { pid, startedAt }),
        started: (started) => {
            try {
                pid = started;
                own.add(started);
                const start = now();
                startedAt = start.toISOString();
                const record: BuildRecord = {
                    pid: started,
                    ...about,
                    startedAt,
                    deadline: new Date(start.getTime() + timeout).toISOString(),
                };
                const names = companionNames(started);
                write = (async () => {
                    await renamed(output.stdout, path.join(folder, names.stdout));
                    await renamed(output.stderr, path.join(folder, names.stderr));
                    await files.write(supportPath, record);
                })().catch((error) => log(`Couldn't record the build of ${about.title}: ${reason(error)}`));
            } catch (error) {
                log(`Couldn't record the build of ${about.title}: ${reason(error)}`);
            }
        },
        ended: async () => {
            await write;
            // Left only when the build never started, or a rename failed.
            await rm(output.stdout, { force: true }).catch(() => undefined);
            await rm(output.stderr, { force: true }).catch(() => undefined);
            if (pid === undefined) return;
            const names = companionNames(pid);
            for (const name of [names.stdout, names.stderr, names.outcome]) {
                await rm(path.join(folder, name), { force: true }).catch((error) =>
                    log(`Couldn't remove ${name} of ${about.title}'s build: ${reason(error)}`),
                );
            }
            await files
                .remove(supportPath, pid)
                .catch((error) => log(`Couldn't remove the record of ${about.title}'s build: ${reason(error)}`));
        },
    };
}
