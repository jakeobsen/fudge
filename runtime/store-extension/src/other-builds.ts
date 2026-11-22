// The builds an earlier store session left running (SPEC-153 C.3 to C.7). Unloading the store doesn't stop its
// `fudge build`, so a store opened later reads their records (`build-records.ts`): their rows say Installing… while
// they run, one that ended is settled, one past its deadline is stopped, and nothing rewrites `repo/` under them.
import { lstat } from "node:fs/promises";
import path from "node:path";
import {
    ownBuilds,
    readBuildOutput,
    readBuildRecords,
    removeBuildFiles,
    stillRunning,
    type BuildRecord,
    type FoundBuildRecord,
    type ProcessProbe,
} from "./build-records.ts";
import type { FailureDetails } from "./failure.ts";
import type { FailureMark, InstallAnswer, InstallEndReport, RowMarks } from "./notices.ts";
import { alreadyBuildingStatus, doneToast, oneAtATime, readInstalled, writeInstalled, type Busy } from "./store.ts";

/** How often the open store checks a running record's pid. */
export const pollInterval = 2000;

/** A record settled: whether its build was adopted into `installed.json`, and whether it ended while this store was
 * open (`seen`), which is when the store says how it ended. A drop as failed has the build's `failure` (SPEC-156 D.2);
 * a quiet drop (a 75, or a 0 whose folder changed since) has none. */
export type Settled = { record: BuildRecord; adopted: boolean; seen: boolean; failure?: FailureDetails };

/** The line a failed drop's output ends with when the build wrote no outcome (it was killed, or crashed). */
export const stoppedLine = "Its build stopped before it finished.";

type Known = {
    record: FoundBuildRecord;
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
            const known = this.known.get(record.pid);
            if (!known) {
                this.known.set(record.pid, { record, seenRunning: false, signalled: false, settling: false });
            } else if (!known.settling) {
                // The same build, now perhaps with its outcome.
                known.record = record;
            }
        }
        // A record whose file went another way.
        for (const [pid, known] of this.known) if (!known.settling && !present.has(pid)) this.known.delete(pid);
        for (const known of this.known.values()) {
            if (known.settling) continue;
            // A build that wrote its outcome has ended (SPEC-156 A.3), whatever its process looks like yet.
            if (known.record.outcome) {
                known.endedAt ??= now();
                this.settle(known);
                continue;
            }
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
     * With the build's outcome (SPEC-156 D.2): 0 is adopted when `<extensions>/<name>` was made between the record's start
     * and the build's own end and the record has a tree, else dropped quietly with a line in the log; 75 is dropped
     * quietly; anything else is dropped as failed. Without one (it was killed, or crashed), C.4 decides: adopted when the
     * folder was made between the start and the end bound, else dropped as failed. Adopting writes the `installed.json`
     * entry the dead session would have written. A failed drop carries the build's output, its command and status. Then
     * all of the pid's files go, and the list loads again.
     */
    private async settleNow(record: FoundBuildRecord, bound: Date, seen: boolean): Promise<void> {
        const { supportPath, extensionsDir, now = () => new Date(), log } = this.options;
        const folder = path.join(extensionsDir, record.name);
        const made = async (end: number) =>
            record.tree !== undefined && (await createdBetween(folder, Date.parse(record.startedAt), end));
        const { outcome } = record;
        let adopted = false;
        let failed = false;
        if (outcome === undefined) {
            adopted = await made(bound.getTime());
            failed = !adopted;
        } else if (outcome.status === 0) {
            adopted = await made(Date.parse(outcome.endedAt));
            if (!adopted) log?.(`The build of ${record.title} finished, but its folder changed since, so the store left it out`);
        } else if (outcome.status !== alreadyBuildingStatus) {
            failed = true;
        }
        if (adopted) {
            const entry = { tree: record.tree!, commit: record.commit, installedAt: now().toISOString(), dir: record.dir };
            await writeInstalled(supportPath, { ...(await readInstalled(supportPath)), [record.name]: entry });
        }
        let failure: FailureDetails | undefined;
        if (failed) {
            const output = await readBuildOutput(supportPath, record.pid).catch(() => "");
            failure = {
                output: outcome === undefined ? [output, stoppedLine].filter((part) => part.length > 0).join("\n") : output,
                command: ["fudge", ...record.command.slice(1)].join(" "),
                ...(outcome === undefined ? {} : { code: outcome.status }),
            };
        }
        await removeBuildFiles(supportPath, record.pid);
        await this.options.settled({ record, adopted, seen, ...(failure ? { failure } : {}) });
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
 * adopted, a Failure toast pointing to the failure view when it failed, and none for a quiet drop. */
export function settledToast(outcome: Settled): { failed: boolean; title: string; message?: string } | undefined {
    const { record, adopted, failure } = outcome;
    if (adopted) return { failed: false, title: doneToast(record.title, record.updating, {}).title };
    if (!failure) return undefined;
    return { failed: true, title: settledFailureTitle(record), message: "See the details." };
}

/** A failed drop's title, as the store's own failure says it. */
export function settledFailureTitle(record: BuildRecord): string {
    return `Couldn't ${record.updating ? "update" : "install"} ${record.title}`;
}

/** What a settled record's notice needs from the store's view (SPEC-156 D.1, D.2, D.3). */
export type SettledSteps = {
    /** Writes a failure to Fudge.log. */
    logFailure: (title: string, failure: FailureDetails) => void;
    marks: Pick<RowMarks, "mark">;
    /** Reports the end to the app, within the report's time limit. */
    report: (end: InstallEndReport) => Promise<InstallAnswer>;
    /** Selects the row of that folder, once. */
    select: (dir: string) => void;
    /** Saves a failure that got a notification for a click. */
    save: (mark: FailureMark) => Promise<void>;
    toast: (shown: { failed: boolean; title: string; message?: string }) => Promise<void>;
    /** Pushes the failure view. */
    show: (mark: FailureMark) => void;
    now?: () => Date;
};

/**
 * A record from another session, settled: a failed drop is logged and marked on its row whenever it ended (D.2, D.3).
 * One this store saw end is reported (D.1), and the app's answer decides as for the store's own: notified, its row is
 * selected and a failure saved for a click, with no toast; not notified, the toast, and a failure's view.
 * One found already ended at open gets no report, no toast and no view.
 */
export async function settledNotice(outcome: Settled, steps: SettledSteps): Promise<void> {
    const { record, failure } = outcome;
    let mark: FailureMark | undefined;
    if (failure) {
        steps.logFailure(settledFailureTitle(record), failure);
        mark = {
            name: record.name,
            dir: record.dir,
            title: record.title,
            updating: record.updating,
            failedAt: (steps.now?.() ?? new Date()).toISOString(),
            details: failure,
        };
        steps.marks.mark(mark);
    }
    if (!outcome.seen) return;
    const shown = settledToast(outcome);
    if (!shown) return;
    const answer = await steps.report({
        build: { pid: record.pid, startedAt: record.startedAt },
        name: record.name,
        dir: record.dir,
        title: record.title,
        updating: record.updating,
        outcome: mark ? "failed" : "installed",
    });
    if (mark && answer.notified) {
        steps.select(record.dir);
        await steps.save(mark);
        return;
    }
    if (!mark && !answer.onScreen) steps.select(record.dir);
    if (answer.notified) return;
    await steps.toast(shown);
    if (mark) steps.show(mark);
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
