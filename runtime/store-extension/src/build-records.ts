// The store's record of each `fudge build` it runs (SPEC-153 C): `<supportPath>/installing/<pid>.json`, written once the
// build has a pid and removed when its run ends. Unloading the store doesn't stop its build, so a store opened later reads
// these to know a build that an earlier one left running. Turning the store off keeps the folder, as it keeps
// `installed.json`.
import { randomBytes } from "node:crypto";
import { lstat, mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { isValidFolder, isValidName } from "./catalog.ts";
import { readRegularFile } from "./files.ts";
import { spawnProgram, type Run } from "./git.ts";
import { shortTimeout } from "./timeouts.ts";

/** One running `fudge build`: what the store would have recorded in `installed.json` when it finished, and how to know the
 * process. `tree` is missing when the store couldn't read the folder's version. */
export type BuildRecord = {
    pid: number;
    name: string;
    dir: string;
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
    const { pid, name, dir, title, tree, commit, updating, startedAt, deadline, command } = object as Record<string, unknown>;
    if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid <= 0 || pid !== Number(match[1])) return undefined;
    if (!isValidName(name) || !isValidFolder(dir)) return undefined;
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
        title,
        ...(tree === undefined ? {} : { tree }),
        commit,
        updating,
        startedAt,
        deadline,
        command: command as string[],
    };
}

/**
 * Every valid record in `installing/`, by pid, read apart from the store's copy. A name that starts with a dot is a write's
 * temporary file: it's skipped, and deleted only once it's older than an hour. Anything else that isn't a valid record (a
 * bad name, a broken file, a link, a folder) is deleted.
 */
export async function readBuildRecords(supportPath: string, now: Date = new Date()): Promise<BuildRecord[]> {
    const folder = installingFolder(supportPath);
    const names = await readdir(folder).catch(() => [] as string[]);
    const records: BuildRecord[] = [];
    for (const name of names) {
        const file = path.join(folder, name);
        if (name.startsWith(".")) {
            const info = await lstat(file).catch(() => undefined);
            if (info && now.getTime() - info.mtimeMs > staleTemporaryAge) {
                await rm(file, { force: true, recursive: true }).catch(() => undefined);
            }
            continue;
        }
        const text = await readRegularFile(file, maxRecordBytes).catch(() => undefined);
        const record = text === undefined ? undefined : parseBuildRecord(name, text);
        if (record) records.push(record);
        else await rm(file, { force: true, recursive: true }).catch(() => undefined);
    }
    return records.sort((a, b) => a.pid - b.pid);
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

/**
 * The record of one run of `fudge build`: `started` writes it once the build has a pid, and `ended`, called when the run
 * has resolved, whatever its result, waits for that write to settle and then removes it, so a run that ends at once can't
 * leave a record behind. Neither throws: a record that can't be written or removed is logged, and the install goes on
 * with the result it would have had.
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
): { started: (pid: number) => void; ended: () => Promise<void> } {
    const { supportPath, now = () => new Date(), log = () => {}, files = buildRecordFiles, own = ownBuilds } = options;
    const reason = (error: unknown) => (error instanceof Error ? error.message : String(error));
    let pid: number | undefined;
    let write: Promise<void> = Promise.resolve();
    return {
        started: (started) => {
            try {
                pid = started;
                own.add(started);
                const start = now();
                const record: BuildRecord = {
                    pid: started,
                    ...about,
                    startedAt: start.toISOString(),
                    deadline: new Date(start.getTime() + timeout).toISOString(),
                };
                write = files
                    .write(supportPath, record)
                    .catch((error) => log(`Couldn't record the build of ${about.title}: ${reason(error)}`));
            } catch (error) {
                log(`Couldn't record the build of ${about.title}: ${reason(error)}`);
            }
        },
        ended: async () => {
            if (pid === undefined) return;
            await write;
            await files
                .remove(supportPath, pid)
                .catch((error) => log(`Couldn't remove the record of ${about.title}'s build: ${reason(error)}`));
        },
    };
}
