// Opening and refreshing the copies (SPEC-157 C.1, C.3, C.6, C.7): each copy that's on gets turns of its own, in the
// list's order. A copy's clone or refresh, with its checkout and the reading of its rows, is one step
// in the queue, and the next copy's step enters the queue only after it, so an install pressed meanwhile waits for at
// most the copy being fetched, never for all of them.
import { heldRefresh, openCopy, type OtherBuilds } from "./other-builds.ts";
import {
    CopyProblem,
    copyStatus,
    problemOf,
    readStatus,
    waitsForRetry,
    writeStatus,
    type ProblemKind,
    type StoreCopy,
} from "./repositories.ts";

/** A copy's fetch that failed: its problem, and what failed. */
export type FetchFailure = { kind: ProblemKind; error: unknown };

/** What the copies' turns need from the store's view. */
export type CopySteps = {
    others: Pick<OtherBuilds, "check" | "hold">;
    now: () => Date;
    /** Reads a copy's rows and shows them, saying how many; throws when it can't (`readCopy`'s problems, or git's). */
    read: (copy: StoreCopy) => Promise<number>;
    /** Shows a copy's problem; rows it showed before stay. `error` is what failed; none for one its status file gave. */
    problem: (copy: StoreCopy, kind: ProblemKind, error?: unknown) => void;
    /** A copy's clone (`first`) or refresh starts; what it returns is called when it ends, with its failure if any. */
    fetching?: (copy: StoreCopy, first: boolean) => (failure?: FetchFailure) => void;
};

/**
 * One copy's clone (the first time) or refresh, with its checkout, then its rows read (C.3). Its status file is written
 * either way (C.6): how many extensions it lists, or its problem. A failed refresh leaves the copy as it was, so the
 * rows it showed stay under the problem.
 */
export async function fetchCopy(copy: StoreCopy, steps: CopySteps): Promise<void> {
    const first = !(await copy.repo.exists());
    const ended = steps.fetching?.(copy, first);
    let result: { extensions: number } | { problem: ProblemKind };
    try {
        if (first) await copy.repo.clone();
        else await copy.repo.refresh();
        result = { extensions: await steps.read(copy) };
        ended?.();
    } catch (error) {
        const kind = problemOf(error);
        result = { problem: kind };
        steps.problem(copy, kind, error);
        ended?.({ kind, error });
    }
    await writeStatus(copy.statusPath, copyStatus(steps.now(), copy.entry.branch, result)).catch(() => undefined);
}

/** A copy's turn: held while a build from another session runs, under `refresh:<copyId>`, then one step in the queue. */
export function copyTurn(copy: StoreCopy, steps: CopySteps): Promise<void> {
    return heldRefresh(steps.others, copy.entry.copyId, () => fetchCopy(copy, steps));
}

/**
 * Opens one copy (C.3, C.7). One waiting for ⌘R (its server can't do partial clones, for the branch the list gives now)
 * isn't fetched, not even a day old: it shows its rows, if it has a copy, and its problem. Any other is cloned the
 * first time, else read; cloned again when it can't be read (a clone stopped halfway); and refreshed when it's a day
 * old, when its status names another branch than the list now gives, or always with `retry`. A copy that's read but
 * whose content has a problem (no extensions folder, none listed, too many) shows it and isn't cloned again. Without a
 * fetch, its status is written only when it has none yet.
 */
export async function openOne(copy: StoreCopy, retry: boolean, steps: CopySteps): Promise<void> {
    const status = await readStatus(copy.statusPath);
    if (!retry && waitsForRetry(status, copy.entry.branch)) {
        if (await copy.repo.exists()) await steps.read(copy).catch(() => undefined);
        steps.problem(copy, "noPartialClone");
        return;
    }
    await openCopy(retry, {
        others: steps.others,
        copyId: copy.entry.copyId,
        exists: () => copy.repo.exists(),
        load: async () => {
            let result: { extensions: number } | { problem: ProblemKind };
            try {
                result = { extensions: await steps.read(copy) };
            } catch (error) {
                // git couldn't read the copy: `openCopy` clones it again.
                if (!(error instanceof CopyProblem)) throw error;
                steps.problem(copy, error.kind, error);
                result = { problem: error.kind };
            }
            if (status === undefined) {
                await writeStatus(copy.statusPath, copyStatus(steps.now(), copy.entry.branch, result)).catch(
                    () => undefined,
                );
            }
        },
        remove: () => copy.repo.remove(),
        refresh: () => copyTurn(copy, steps),
        // A branch changed in Settings since the last attempt is followed at this open (A.8), not a day later.
        needsRefresh: async () =>
            (status !== undefined && status.branch !== copy.entry.branch) ||
            (await copy.repo.needsRefresh(steps.now())),
    });
}

/**
 * Opens every copy that's on, in the list's order (C.3): each copy's steps one after another, so its turns enter the
 * queue only after the copy before it is done. One copy failing never stops another (C.6).
 */
export async function openCopies(copies: readonly StoreCopy[], retry: boolean, steps: CopySteps): Promise<void> {
    for (const copy of copies) {
        try {
            await openOne(copy, retry, steps);
        } catch (error) {
            steps.problem(copy, problemOf(error), error);
        }
    }
}

/** ⌘R (C.3, C.7): every copy that's on fetched once, in the list's order, one waiting for ⌘R included. */
export async function refreshCopies(copies: readonly StoreCopy[], steps: CopySteps): Promise<void> {
    for (const copy of copies) {
        try {
            await copyTurn(copy, steps);
        } catch (error) {
            steps.problem(copy, problemOf(error), error);
        }
    }
}
