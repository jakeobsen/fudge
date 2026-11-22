// The builds an earlier store session left running (SPEC-153 C.3 to C.7). Unloading the store doesn't stop its
// `fudge build`, so a store opened later reads their records (`build-records.ts`): their rows say Installing… while
// they run, one that ended is settled, one past its deadline is stopped, and nothing rewrites `repo/` under them.
import { lstat } from "node:fs/promises";
import path from "node:path";
import {
    ownBuilds,
    readBuildRecords,
    removeBuildRecord,
    stillRunning,
    type BuildRecord,
    type ProcessProbe,
} from "./build-records.ts";
import { doneToast, oneAtATime, readInstalled, writeInstalled, type Busy } from "./store.ts";

/** How often the open store checks a running record's pid. */
export const pollInterval = 2000;

/** A record settled: whether its build was adopted into `installed.json`, and whether it ended while this store was
 * open (`seen`), which is when the store says how it ended. */
export type Settled = { record: BuildRecord; adopted: boolean; seen: boolean };

type Known = {
    record: BuildRecord;
    /** This store saw the build running. */
    seenRunning: boolean;
    /** When this store first saw it ended. */
    endedAt?: Date;
    signalled: boolean;
    settling: boolean;
};

export type OtherBuildsOptions = {
    supportPath: string;
    extensionsDir: string;
    probe: ProcessProbe;
    /** After a record is settled, in the store's queue: loads the list again, and says how a build it saw end ended. */
    settled: (outcome: Settled) => Promise<void> | void;
    /** The busy names changed: draw again. */
    changed?: () => void;
    /** This session's builds, which end through their own run (`ownBuilds`). */
    own?: ReadonlySet<number>;
    now?: () => Date;
    /** The store's queue (`oneAtATime`). */
    queue?: <T>(work: () => Promise<T>) => Promise<T>;
    log?: (line: string) => void;
    timers?: { setInterval: typeof setInterval; clearInterval: typeof clearInterval };
};

/** Whether `folder` is a folder made between `start` and `end`, in whole milliseconds, as the record's times are. The
 * build makes its staging folder during its run and renames it into place, which keeps its creation time. */
async function createdBetween(folder: string, start: number, end: number): Promise<boolean> {
    const info = await lstat(folder).catch(() => undefined);
    if (info === undefined || !info.isDirectory()) return false;
    const created = Math.floor(info.birthtimeMs);
    return created >= start && created <= end;
}

export class OtherBuilds {
    private readonly known = new Map<number, Known>();
    /** Records whose settling failed: left alone for the rest of this session. */
    private readonly givenUp = new Set<number>();
    private checking: Promise<void> | undefined;
    private waiters: (() => void)[] = [];
    private readonly held = new Map<string, Promise<unknown>>();
    private timer: ReturnType<typeof setInterval> | undefined;
    private readonly options: OtherBuildsOptions;

    constructor(options: OtherBuildsOptions) {
        this.options = options;
    }

    /**
     * Reads `installing/` and checks every record of another session's build (C.3). One past its deadline is stopped
     * (C.5); one that has ended is settled in the queue (C.4), which this never waits for, so it may run inside the queue.
     * A call while a check runs gets that check.
     */
    check(): Promise<void> {
        this.checking ??= this.checkNow().finally(() => {
            this.checking = undefined;
        });
        return this.checking;
    }

    private async checkNow(): Promise<void> {
        const { supportPath, probe, own = ownBuilds, now = () => new Date() } = this.options;
        const records = await readBuildRecords(supportPath, now()).catch(() => []);
        const present = new Set<number>();
        for (const record of records) {
            if (own.has(record.pid) || this.givenUp.has(record.pid)) continue;
            present.add(record.pid);
            if (!this.known.has(record.pid)) {
                this.known.set(record.pid, { record, seenRunning: false, signalled: false, settling: false });
            }
        }
        // A record whose file went another way.
        for (const [pid, known] of this.known) if (!known.settling && !present.has(pid)) this.known.delete(pid);
        for (const known of this.known.values()) {
            if (known.settling) continue;
            const running = await stillRunning(known.record, probe);
            if (running === undefined) continue;
            const at = now();
            if (running) {
                known.seenRunning = true;
                // Only a pid that passed every check of `stillRunning` is ever signalled, and once.
                if (!known.signalled && at.getTime() > Date.parse(known.record.deadline)) {
                    known.signalled = true;
                    probe.terminate(known.record.pid);
                }
                continue;
            }
            known.endedAt ??= at;
            this.settle(known);
        }
        this.options.changed?.();
        this.wake();
    }

    /**
     * Settles an ended record in the queue. The end bound is when this store first saw it ended or, when it had ended
     * before the store opened, its deadline, by which the session that started it would have stopped it.
     */
    private settle(known: Known): void {
        const { queue = oneAtATime, log } = this.options;
        known.settling = true;
        const bound = known.seenRunning && known.endedAt ? known.endedAt : new Date(known.record.deadline);
        void queue(() => this.settleNow(known.record, bound, known.seenRunning))
            .catch((error) => {
                this.givenUp.add(known.record.pid);
                log?.(`Couldn't settle the build of ${known.record.title}: ${error instanceof Error ? error.message : String(error)}`);
            })
            .finally(() => {
                this.known.delete(known.record.pid);
                this.options.changed?.();
                this.wake();
            });
    }

    /**
     * Adopts the build when `<extensions>/<name>` was made between the record's start and the end bound and the record has
     * a tree, writing the `installed.json` entry the dead session would have written; drops it otherwise (it failed or was
     * stopped, or the folder came from somewhere else). Then the record goes, and the list loads again.
     */
    private async settleNow(record: BuildRecord, bound: Date, seen: boolean): Promise<void> {
        const { supportPath, extensionsDir, now = () => new Date() } = this.options;
        const folder = path.join(extensionsDir, record.name);
        const adopted =
            record.tree !== undefined && (await createdBetween(folder, Date.parse(record.startedAt), bound.getTime()));
        if (adopted) {
            const entry = { tree: record.tree!, commit: record.commit, installedAt: now().toISOString(), dir: record.dir };
            await writeInstalled(supportPath, { ...(await readInstalled(supportPath)), [record.name]: entry });
        }
        await removeBuildRecord(supportPath, record.pid);
        await this.options.settled({ record, adopted, seen });
    }

    /** Whether a build from another session is still running, or has ended and isn't settled yet. */
    get pending(): boolean {
        return this.known.size > 0;
    }

    /** Those builds' records, by pid. */
    records(): BuildRecord[] {
        return [...this.known.values()].map((known) => known.record);
    }

    /** Whether another session's build of `name` is running or not settled yet, as B shows it on every row of that name. */
    busy(name: string): Busy | undefined {
        for (const known of this.known.values()) {
            if (known.record.name === name) return known.record.updating ? "updating" : "installing";
        }
        return undefined;
    }

    private whenClear(): Promise<void> {
        if (!this.pending) return Promise.resolve();
        return new Promise((resolve) => this.waiters.push(resolve));
    }

    private wake(): void {
        if (this.pending) return;
        const waiters = this.waiters;
        this.waiters = [];
        for (const resolve of waiters) resolve();
    }

    /**
     * Runs `step` once no build from another session is pending (C.7): at once when none is, else after the last has
     * settled. It waits here, before `step` enters the queue, so a settling, which runs in the queue, never waits on it.
     * Calls with one `key` while it waits run it once.
     */
    hold<T>(key: string, step: () => Promise<T>): Promise<T> {
        if (!this.pending) return step();
        const waiting = this.held.get(key);
        if (waiting) return waiting as Promise<T>;
        const next = this.whenClear().then(() => {
            this.held.delete(key);
            return step();
        });
        this.held.set(key, next);
        return next;
    }

    /** Checks every `pollInterval` while a build from another session is pending, until `stop`. */
    start(): void {
        const timers = this.options.timers ?? { setInterval, clearInterval };
        this.timer ??= timers.setInterval(() => {
            if (this.pending) void this.check();
        }, pollInterval);
    }

    stop(): void {
        const timers = this.options.timers ?? { setInterval, clearInterval };
        if (this.timer !== undefined) timers.clearInterval(this.timer);
        this.timer = undefined;
    }
}

/**
 * The store's refresh (⌘R, the day-old refresh on open, the clone again after a copy that can't be read): held by
 * `others` before it enters the queue, never inside it, so a record settling in the queue can't wait behind it (C.7).
 */
export function heldRefresh(others: Pick<OtherBuilds, "hold">, work: () => Promise<void>): Promise<void> {
    return others.hold("refresh", () => oneAtATime(work));
}

/** ⌘R's toast while a build from another session holds the refresh back. */
export function heldRefreshMessage(records: BuildRecord[]): string {
    if (records.length === 1) {
        const [record] = records as [BuildRecord];
        return `The list updates when ${record.title} has ${record.updating ? "updated" : "installed"}`;
    }
    return "The list updates when the installs have finished";
}

/** The toast for a build from another session that ended while this store was open: the usual done toast when it was
 * adopted, else a Failure toast with no failure view, since its output went with the old session. */
export function settledToast(outcome: Settled): { failed: boolean; title: string; message?: string } {
    const { record, adopted } = outcome;
    if (adopted) return { failed: false, title: doneToast(record.title, record.updating, {}).title };
    return {
        failed: true,
        title: `Couldn't ${record.updating ? "update" : "install"} ${record.title}`,
        message: "Its build stopped before it finished. Try again to see the error.",
    };
}

/** What `openCopy` works with: the store's copy and these builds. */
export type OpenSteps = {
    others: Pick<OtherBuilds, "check" | "hold">;
    exists: () => Promise<boolean>;
    load: () => Promise<void>;
    remove: () => Promise<void>;
    refresh: () => Promise<void>;
    needsRefresh: () => Promise<boolean>;
};

/**
 * The store's `open()` once git is found: the records of builds from another session first (C.2), so a `load()` that
 * throws on the copy still knows them, then the copy. A copy that can't be read is removed and cloned again, after those
 * builds have settled (C.7), as is the day-old refresh (`refresh` holds itself).
 */
export async function openCopy(retry: boolean, steps: OpenSteps): Promise<void> {
    await steps.others.check();
    if (!(await steps.exists())) {
        await steps.refresh();
        return;
    }
    try {
        await steps.load();
    } catch {
        await steps.others.hold("reload", async () => {
            await steps.remove();
            await steps.refresh();
        });
        return;
    }
    if (retry || (await steps.needsRefresh())) await steps.refresh();
}
