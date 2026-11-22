// Install notifications, the store's side (SPEC-156 D, E): the report to the app and its answer, failures saved for a
// click, the launch context a click opens the store with, and the marks on failed rows.

import { randomBytes } from "node:crypto";
import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { isValidFolder, isValidName } from "./catalog.ts";
import type { FailureDetails } from "./failure.ts";

/** An install or update the store ended, as `installEnded` in `fudge:app` takes it. */
export type InstallEndReport = {
    build?: { pid: number; startedAt: string };
    name: string;
    dir: string;
    title: string;
    updating: boolean;
    outcome: "installed" | "failed";
};

/** The app's answer: whether the store is on screen, and whether a notification went out. */
export type InstallAnswer = { onScreen: boolean; notified: boolean };

/** What a click or the launch context opens: the row of `dir`, and its failure view when it `failed`. */
export type NoticeTarget = { name: string; dir: string; failed: boolean; repository?: string };

/** A failure the store keeps for a click and marks on its row (D.3, D.4). */
export type FailureMark = {
    name: string;
    dir: string;
    title: string;
    updating: boolean;
    failedAt: string;
    details: FailureDetails;
    repository?: string;
};

/** How long the store waits for the app's answer (D.1). */
export const reportLimit = 5000;

/** The answer when there's none: a report that failed or took too long counts as on screen and not notified. */
export const unanswered: InstallAnswer = Object.freeze({ onScreen: true, notified: false });

/**
 * Reports an end to the app and waits at most `limit` ms for its answer; one that throws, takes longer or isn't one
 * gives `unanswered`, today's behaviour.
 */
export async function reportEnd(
    report: ((report: InstallEndReport) => Promise<InstallAnswer>) | undefined,
    end: InstallEndReport,
    limit = reportLimit,
): Promise<InstallAnswer> {
    if (!report) return unanswered;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<InstallAnswer>((resolve) => {
        timer = setTimeout(() => resolve(unanswered), limit);
    });
    try {
        const answer = await Promise.race([report(end).catch(() => unanswered), late]);
        return typeof answer?.onScreen === "boolean" && typeof answer.notified === "boolean" ? answer : unanswered;
    } finally {
        clearTimeout(timer);
    }
}

/** `failures/` in the store's support folder, where failures that got a notification wait for a click (D.4). */
export function failuresFolder(supportPath: string): string {
    return path.join(supportPath, "failures");
}

function failureFile(supportPath: string, name: string): string {
    return path.join(failuresFolder(supportPath), `${name}.json`);
}

/** How long a saved failure is kept, unopened. */
export const failureKeep = 7 * 24 * 60 * 60 * 1000;

/** Saves a failure that got a notification, atomically; an error is logged and changes nothing else. */
export async function saveFailure(supportPath: string, mark: FailureMark, log?: (line: string) => void): Promise<void> {
    if (!isValidName(mark.name)) return;
    const folder = failuresFolder(supportPath);
    const file = failureFile(supportPath, mark.name);
    const temporary = path.join(folder, `.${randomBytes(8).toString("hex")}.tmp`);
    try {
        await mkdir(folder, { recursive: true });
        const saved = {
            title: mark.title,
            dir: mark.dir,
            updating: mark.updating,
            failedAt: mark.failedAt,
            details: mark.details,
            ...(mark.repository === undefined ? {} : { repository: mark.repository }),
        };
        await writeFile(temporary, `${JSON.stringify(saved)}\n`, { mode: 0o600 });
        await rename(temporary, file);
    } catch (error) {
        await rm(temporary, { force: true }).catch(() => {});
        log?.(`Couldn't keep ${mark.title}'s failure for its notification: ${error instanceof Error ? error.message : String(error)}`);
    }
}

/** The failure saved for `name`, or undefined when there's none or it isn't one. */
export async function readSavedFailure(supportPath: string, name: string): Promise<FailureMark | undefined> {
    if (!isValidName(name)) return undefined;
    const text = await readFile(failureFile(supportPath, name), "utf8").catch(() => undefined);
    if (text === undefined) return undefined;
    try {
        const value = JSON.parse(text) as Record<string, unknown>;
        const details = value.details as Record<string, unknown> | undefined;
        if (
            typeof value.title !== "string" ||
            !isValidFolder(value.dir) ||
            typeof value.updating !== "boolean" ||
            typeof value.failedAt !== "string" ||
            typeof details !== "object" ||
            details === null ||
            typeof details.output !== "string" ||
            (details.command !== undefined && typeof details.command !== "string") ||
            (details.code !== undefined && typeof details.code !== "number") ||
            (details.refused !== undefined && typeof details.refused !== "boolean") ||
            (value.repository !== undefined && typeof value.repository !== "string")
        ) {
            return undefined;
        }
        return {
            name,
            dir: value.dir,
            title: value.title,
            updating: value.updating,
            failedAt: value.failedAt,
            details: {
                output: details.output,
                ...(typeof details.command === "string" ? { command: details.command } : {}),
                ...(typeof details.code === "number" ? { code: details.code } : {}),
                ...(details.refused === true ? { refused: true } : {}),
            },
            ...(typeof value.repository === "string" ? { repository: value.repository } : {}),
        };
    } catch {
        return undefined;
    }
}

/** Deletes the failure saved for `name`: it was opened, or the name was pressed again. */
export async function removeSavedFailure(supportPath: string, name: string): Promise<void> {
    if (!isValidName(name)) return;
    await rm(failureFile(supportPath, name), { force: true }).catch(() => {});
}

/** At the store's open: saved failures older than 7 days go. */
export async function pruneSavedFailures(supportPath: string, now: Date = new Date()): Promise<void> {
    const folder = failuresFolder(supportPath);
    const names = await readdir(folder).catch(() => [] as string[]);
    for (const name of names) {
        const file = path.join(folder, name);
        const info = await stat(file).catch(() => undefined);
        if (info?.isFile() && now.getTime() - info.mtimeMs > failureKeep) await rm(file, { force: true }).catch(() => {});
    }
}

/** A click's target, or the launch context's `storeNotification`, checked; undefined when anything is off. */
export function noticeTarget(value: unknown): NoticeTarget | undefined {
    if (typeof value !== "object" || value === null) return undefined;
    const { name, dir, failed, repository } = value as Record<string, unknown>;
    if (!isValidName(name) || !isValidFolder(dir) || typeof failed !== "boolean") return undefined;
    if (repository !== undefined && typeof repository !== "string") return undefined;
    return typeof repository === "string" ? { name, dir, failed, repository } : { name, dir, failed };
}

/** The launch context's target (D.5): `launchContext.storeNotification`, checked. */
export function launchTarget(launchContext: unknown): NoticeTarget | undefined {
    if (typeof launchContext !== "object" || launchContext === null) return undefined;
    return noticeTarget((launchContext as Record<string, unknown>).storeNotification);
}

/**
 * The failed rows of this store session (D.3), by folder, in memory only, so the next session doesn't show them again.
 * A mark goes when that name installs or updates, or with the session.
 */
export class RowMarks {
    private readonly marks = new Map<string, FailureMark>();
    private readonly changed: () => void;

    constructor(changed: () => void = () => {}) {
        this.changed = changed;
    }

    get(dir: string): FailureMark | undefined {
        return this.marks.get(dir);
    }

    mark(failure: FailureMark): void {
        this.marks.set(failure.dir, failure);
        this.changed();
    }

    /** That name installed or updated: its mark goes. */
    clear(name: string): void {
        let removed = false;
        for (const [dir, mark] of this.marks) {
            if (mark.name === name) {
                this.marks.delete(dir);
                removed = true;
            }
        }
        if (removed) this.changed();
    }
}

/**
 * The row to select once (D.1, D.5, E.1): the list's `selectedItemId`, until the app reports that row selected. The app
 * follows `selectedItemId` only when it changes, and reports a selection only when it moved, so the row already selected
 * is never asked for: that ask would never be reported and so never cleared, and the next ask for that row, the same id
 * again, would change nothing.
 */
export class RowSelection {
    private selected: string | null = null;
    private asked: string | undefined;
    private readonly changed: (asked: string | undefined) => void;

    /** `changed` gets the new `selectedItemId` whenever it changes. */
    constructor(changed: (asked: string | undefined) => void) {
        this.changed = changed;
    }

    /** The row asked for, for `selectedItemId`. */
    get current(): string | undefined {
        return this.asked;
    }

    /** Selects the row of `dir`, once; a row already selected stays, and an earlier ask goes. */
    select(dir: string): void {
        this.ask(dir === this.selected ? undefined : dir);
    }

    /** The app's `onSelectionChange`: once the row asked for is selected, from here the user moves it. */
    reported(id: string | null): void {
        this.selected = id;
        if (id !== null && id === this.asked) this.ask(undefined);
    }

    private ask(dir: string | undefined): void {
        if (dir === this.asked) return;
        this.asked = dir;
        this.changed(dir);
    }
}

/** What opening a click's or the launch context's target needs from the store's view. */
export type TargetSteps = {
    supportPath: string;
    /** Selects the row of that folder, once. */
    select: (dir: string) => void;
    /** This session's marks: a failure it has in memory. */
    marks: Pick<RowMarks, "get">;
    /** Pushes the failure view. */
    show: (mark: FailureMark) => void;
};

/**
 * A click or the launch context (D.5, E.1): the row selected, and with `failed` its failure view, from this session's
 * memory or else the file saved for it; the saved file goes once it's opened. With neither, only the selection.
 */
export async function openNoticeTarget(target: NoticeTarget, steps: TargetSteps): Promise<void> {
    steps.select(target.dir);
    if (!target.failed) return;
    // The target's own row's failure: by its folder, since two folders can hold one name.
    const held = steps.marks.get(target.dir);
    const saved = held?.name === target.name ? undefined : await readSavedFailure(steps.supportPath, target.name);
    const mark = held?.name === target.name ? held : saved?.dir === target.dir ? saved : undefined;
    if (!mark) return;
    await removeSavedFailure(steps.supportPath, target.name);
    steps.show(mark);
}

/**
 * The launch context a click opens the store with (D.5): opened once, after the first load, and once the records found
 * at open have settled, waiting for them outside the queue as a held refresh does.
 */
export class LaunchTarget {
    private done = false;
    private readonly launchContext: unknown;
    private readonly others: { hold<T>(key: string, step: () => Promise<T>): Promise<T> };
    private readonly open: (target: NoticeTarget) => Promise<void>;

    constructor(
        launchContext: unknown,
        others: { hold<T>(key: string, step: () => Promise<T>): Promise<T> },
        open: (target: NoticeTarget) => Promise<void>,
    ) {
        this.launchContext = launchContext;
        this.others = others;
        this.open = open;
    }

    /** Called whenever the view renders; acts once the first load is in, and only then. */
    loaded(isLoaded: boolean): Promise<void> | undefined {
        if (!isLoaded || this.done) return undefined;
        this.done = true;
        const target = launchTarget(this.launchContext);
        return target ? this.others.hold("notification", () => this.open(target)) : undefined;
    }
}

/**
 * A click while this store session is loaded (E.1): one `nextNotificationClick` call waits at a time, made again after
 * each answer. It stops when the session goes (`stopped`), when the call fails (an app that doesn't answer it), and on
 * null, which means a newer call from this session replaced it.
 */
export async function followClicks(
    next: () => Promise<unknown>,
    open: (target: NoticeTarget) => Promise<void>,
    stopped: () => boolean,
): Promise<void> {
    while (!stopped()) {
        let click: unknown;
        try {
            click = await next();
        } catch {
            return;
        }
        if (stopped() || click === null) return;
        const target = noticeTarget(click);
        // A target that can't be opened doesn't stop the clicks after it.
        if (target) await open(target).catch(() => {});
    }
}
