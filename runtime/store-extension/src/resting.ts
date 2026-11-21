// Work for the row the selection rests on: the detail's compatibility check and its README (SPEC-106 §1).

export type Timers = { set: (run: () => void, ms: number) => unknown; clear: (handle: unknown) => void };
export const realTimers: Timers = {
    set: (run, ms) => setTimeout(run, ms),
    clear: (handle) => clearTimeout(handle as NodeJS.Timeout),
};

/**
 * Runs `run` for the key the selection rests on, one key at a time. `select` starts it only after the selection has
 * stayed on a key for `delay` ms, and a new `select` cancels the last: its timer, or the work itself, which sees
 * `cancelled()` and whose `signal` aborts. So moving through rows does nothing, and a key that's `done` (cached) is
 * never run. Selecting the key already waiting or running again (a render that changed something else) changes
 * nothing; one that failed is tried again only after the selection has left it.
 */
export class RestingWork<Result> {
    readonly #delay: number;
    readonly #timers: Timers;
    readonly #done: (key: string) => boolean;
    readonly #run: (key: string, cancelled: () => boolean, signal: AbortSignal) => Promise<Result | undefined>;
    readonly #changed: (key: string, result: Result | "failed") => void;
    #timer: unknown;
    #current = { cancelled: true, key: "", controller: new AbortController() };

    constructor(options: {
        delay?: number;
        timers?: Timers;
        done: (key: string) => boolean;
        run: (key: string, cancelled: () => boolean, signal: AbortSignal) => Promise<Result | undefined>;
        changed: (key: string, result: Result | "failed") => void;
    }) {
        this.#delay = options.delay ?? 500;
        this.#timers = options.timers ?? realTimers;
        this.#done = options.done;
        this.#run = options.run;
        this.#changed = options.changed;
    }

    /** The key now selected, or nothing. */
    select(key: string | undefined): void {
        if (key && key === this.#current.key && !this.#current.cancelled) return;
        this.stop();
        if (!key || this.#done(key)) return;
        const token = { cancelled: false, key, controller: new AbortController() };
        this.#current = token;
        this.#timer = this.#timers.set(() => {
            this.#timer = undefined;
            void this.#run(key, () => token.cancelled, token.controller.signal).then(
                // A result that came in after the selection moved on is still right, so it's kept.
                (result) => {
                    if (result !== undefined) this.#changed(key, result);
                },
                () => {
                    if (!token.cancelled) this.#changed(key, "failed");
                },
            );
        }, this.#delay);
    }

    /**
     * Runs the selected key's work again, as a new selection would, unless it's `done`: ⌘R's retry of one that failed,
     * since selecting the same key again doesn't. Nothing when no key is selected.
     */
    again(): void {
        if (this.#current.cancelled) return;
        const key = this.#current.key;
        this.stop();
        this.select(key);
    }

    /** Cancels the waiting or running work. */
    stop(): void {
        this.#current.cancelled = true;
        this.#current.controller.abort();
        if (this.#timer !== undefined) this.#timers.clear(this.#timer);
        this.#timer = undefined;
    }
}
