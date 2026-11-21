// Notices (SPEC-095): a call the app refused on purpose, such as signing in while sign-in is off, isn't a crash. The
// app names the reason in its answer (`rpcResult`'s `notice`), the bridge marks the rejection with it, and the worker's
// error report carries it back (`error`'s `notice`), so the app shows a notice in place of a failure and its trace.
// The reason is always read from the mark, never from a message's text.

import type { WorkerMessage } from "./protocol.ts";

/** The mark: a symbol, not enumerable, so it doesn't show when an extension logs or serializes the error. */
const noticeMark = Symbol.for("fudge.notice");

/** Marks `error` as refused on purpose, for `notice` (e.g. `signInOff`). */
export function markNotice<T extends Error>(error: T, notice: string): T {
    Object.defineProperty(error, noticeMark, { value: notice, enumerable: false, configurable: true, writable: true });
    return error;
}

/** How many errors `noticeOf` looks at, at most: a chain or an aggregate is never that long by accident. */
const searchLimit = 64;

/**
 * The notice an error carries, with the message of the error that carries it: its own, or one anywhere in its
 * `cause` chain or an `AggregateError`'s `errors`, nested in any order, since a library may wrap or rethrow the
 * refusal before it reaches the report (`@raycast/utils`, or an extension's own `new Error(…, { cause })`). Cycles
 * are followed once, and a getter that throws counts as nothing there.
 */
export function noticeOf(error: unknown): { notice: string; message: string } | undefined {
    const seen = new Set<object>();
    const queue: unknown[] = [error];
    while (queue.length > 0 && seen.size < searchLimit) {
        const next = queue.shift();
        if (next === null || (typeof next !== "object" && typeof next !== "function") || seen.has(next)) continue;
        seen.add(next);
        const record = next as Record<PropertyKey, unknown>;
        try {
            const notice = record[noticeMark];
            if (typeof notice === "string") {
                const message = record.message;
                return { notice, message: typeof message === "string" ? message : "" };
            }
            queue.push(record.cause);
            const errors = record.errors;
            if (Array.isArray(errors)) queue.push(...errors.slice(0, searchLimit));
        } catch {
            // A proxy or getter that throws: nothing to read there.
        }
    }
    return undefined;
}

export type ErrorReport = Extract<WorkerMessage, { type: "error" }>;

/**
 * What the worker reports for an error. One refused on purpose carries its `notice`, and the message is the refusal's
 * own, not a wrapper's; the stack still goes along, for the app's log only.
 */
export function errorReport(error: unknown, fatal: boolean): ErrorReport {
    const failure = error instanceof Error ? error : new Error(String(error));
    const found = noticeOf(error);
    if (!found) return { type: "error", message: failure.message, stack: failure.stack, fatal };
    return { type: "error", message: found.message, stack: failure.stack, fatal, notice: found.notice };
}
