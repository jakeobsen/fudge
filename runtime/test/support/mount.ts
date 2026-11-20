// Test helper: mounts an element the way the host mounts a command and
// collects what would be sent to the app.

import { createElement, type ReactNode } from "react";
import { NavigationRoot, type NavigationHandle } from "../../src/api/navigation.ts";
import { createRoot, type Root, type Snapshot } from "../../src/renderer/root.ts";
import type { UINode } from "../../src/renderer/serialize.ts";

export type Mounted = {
    root: Root;
    navigation: NavigationHandle;
    snapshots: Snapshot[];
    errors: unknown[];
    /** Resolves with the next snapshot sent to the app. */
    next(): Promise<Snapshot>;
    /** Lets every scheduled render and snapshot happen. */
    settle(): Promise<void>;
};

export async function mount(element: ReactNode): Promise<Mounted & { first: Snapshot }> {
    const snapshots: Snapshot[] = [];
    const errors: unknown[] = [];
    const waiting: ((snapshot: Snapshot) => void)[] = [];
    const navigation: NavigationHandle = { current: null };

    const root = createRoot({
        onRender(snapshot) {
            snapshots.push(snapshot);
            waiting.shift()?.(snapshot);
        },
        onError(error) {
            errors.push(error);
        },
    });

    const mounted: Mounted = {
        root,
        navigation,
        snapshots,
        errors,
        next: () => new Promise((resolve) => waiting.push(resolve)),
        async settle() {
            for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
        },
    };
    const first = mounted.next();
    root.render(createElement(NavigationRoot, { root: element, handle: navigation }));
    return { ...mounted, first: await first };
}

/** Depth-first search for the first node of `type`, including nodes held in props. */
export function find(node: UINode | null, type: string): UINode | undefined {
    if (!node) return undefined;
    if (node.type === type) return node;
    for (const value of Object.values(node.props)) {
        if (isNode(value)) {
            const found = find(value, type);
            if (found) return found;
        }
    }
    for (const child of node.children) {
        const found = find(child, type);
        if (found) return found;
    }
    return undefined;
}

function isNode(value: unknown): value is UINode {
    return typeof value === "object" && value !== null && "type" in value && "children" in value;
}
