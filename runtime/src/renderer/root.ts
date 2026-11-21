// A React root whose output is sent to the app.
//
// Commits are coalesced: however many happen in one turn of the event loop,
// the app gets one snapshot. A command's views sit side by side as `$view`
// instances (see api/navigation.ts); only the top one is sent, with the
// stack depth so the app knows whether Esc pops or closes.

import type { ReactNode } from "react";
import { ConcurrentRoot } from "react-reconciler/constants.js";
import { createContainer, reconciler, type HostInstance } from "./host.ts";
import { firstVisible, type UINode } from "./serialize.ts";

export const VIEW = "$view";

export type Snapshot = {
    /** The top view, or null when the command renders nothing. */
    view: UINode | null;
    /** How many views are on the navigation stack (1 = the command's root view). */
    depth: number;
};

export type RootOptions = {
    onRender(snapshot: Snapshot): void;
    onError(error: unknown): void;
};

export type Root = {
    render(element: ReactNode): void;
    /** Calls the function at `path` in the props of node `id`, as a discrete user event. */
    dispatch(id: number, path: readonly string[], args: readonly unknown[]): unknown;
    snapshot(): Snapshot;
    /** Calls back once the snapshot of work already committed has been sent, or now when none is waiting. */
    whenRendered(callback: () => void): void;
    unmount(): void;
};

export class StaleCallbackError extends Error {}

export function createRoot(options: RootOptions): Root {
    let scheduled = false;
    const afterRender: (() => void)[] = [];
    const container = createContainer(() => {
        if (scheduled) return;
        scheduled = true;
        setImmediate(() => {
            scheduled = false;
            options.onRender(snapshot());
            for (const callback of afterRender.splice(0)) callback();
        });
    });

    const report = (error: unknown) => options.onError(error);
    const fiberRoot = reconciler.createContainer(
        container,
        ConcurrentRoot,
        null,
        false,
        null,
        "",
        report,
        report,
        report,
        () => {},
        null,
    );

    function snapshot(): Snapshot {
        const views = container.children.filter(
            (node): node is HostInstance => node.kind === "instance" && node.type === VIEW && !node.hidden,
        );
        if (views.length === 0) return { view: firstVisible(container.children), depth: 1 };
        return { view: firstVisible(views[views.length - 1]!.children), depth: views.length };
    }

    return {
        render(element) {
            reconciler.updateContainer(element, fiberRoot, null, null);
        },
        dispatch(id, path, args) {
            const instance = container.instances.get(id);
            let target: unknown = instance?.props;
            for (const key of path) target = (target as Record<string, unknown> | undefined)?.[key];
            if (typeof target !== "function") {
                throw new StaleCallbackError(`node ${id} has no function at ${path.join(".") || "(empty path)"}`);
            }
            const callback = target as (...args: unknown[]) => unknown;
            let result: unknown;
            reconciler.discreteUpdates(
                () => {
                    result = callback(...args);
                },
                undefined,
                undefined,
                undefined,
                undefined,
            );
            return result;
        },
        snapshot,
        whenRendered(callback) {
            if (scheduled) afterRender.push(callback);
            else callback();
        },
        unmount() {
            // Synchronously, so effect cleanups have run when this returns.
            reconciler.updateContainerSync(null, fiberRoot, null, null);
            reconciler.flushSyncWork();
        },
    };
}
