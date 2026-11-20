// What the app told the worker about this launch. Set once by worker.ts
// before the command runs; read by the API functions that need it.

export type LaunchContext = {
    /** Resolved preference values: extension-wide ones merged with the command's own. */
    preferences: Record<string, unknown>;
};

let context: LaunchContext = { preferences: {} };

export function setLaunchContext(next: LaunchContext): void {
    context = next;
}

export function launchContext(): LaunchContext {
    return context;
}
