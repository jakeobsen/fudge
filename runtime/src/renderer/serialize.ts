// Turns the host tree into JSON for the app.
//
// Functions become `{ "$fn": [...path] }` markers; the app calls one back by
// sending the node id and that path. Dates become `{ "$date": iso }`. React
// elements passed as props (`actions={<ActionPanel/>}`) arrive here as
// `$slot` children (see api/components.ts) and are put back as props.
//
// A List or Grid item's `actions` and `detail` are sent only for the items
// the app needs them for (see `Deferral`); the others carry
// `{ "$deferred": true }` instead, and the app asks for them with `slots`.
// A deferred `actions` also names the shortcuts its panel uses
// (`"shortcuts": <index>` into the view's `$shortcutSets`), so the app can
// hold those keys until the panel comes.

import { isValidElement } from "react";
import type { HostNode } from "./host.ts";

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export type UINode = {
    id: number;
    type: string;
    props: { [key: string]: JsonValue };
    children: UINode[];
};

export const SLOT = "$slot";

/** What a deferred slot is sent as. */
export const DEFERRED = "$deferred";

/** The item types whose `actions` and `detail` are deferred, and those slots' names. */
const DEFERRING_TYPES: ReadonlySet<string> = new Set(["List.Item", "Grid.Item"]);
const DEFERRED_SLOTS: ReadonlySet<string> = new Set(["actions", "detail"]);

/**
 * Which items' `actions` and `detail` a snapshot carries: the first item, which the app selects when a list
 * arrives, and the ones the app last asked for (`wanted`: the selected item and its neighbours). An action panel on
 * every row made a 1,000-row list a 2 MB message, five times what the rows themselves take.
 *
 * The deferred panels' shortcuts are collected as it goes, each distinct set once (`shortcutSets`): rows usually
 * share one, so a row only names its set's index.
 */
export type Deferral = {
    wanted: ReadonlySet<number>;
    firstSeen: boolean;
    shortcutSets: JsonValue[][];
    setIndex: Map<string, number>;
};

export function deferral(wanted: ReadonlySet<number>): Deferral {
    return { wanted, firstSeen: false, shortcutSets: [], setIndex: new Map() };
}

/** The view prop that carries a snapshot's `shortcutSets`. */
export const SHORTCUT_SETS = "$shortcutSets";

export function serializeNode(node: HostNode, deferral?: Deferral): UINode | null {
    if (node.hidden) return null;
    if (node.kind === "text") return { id: node.id, type: "#text", props: { text: node.text }, children: [] };

    let defers = false;
    if (deferral && DEFERRING_TYPES.has(node.type)) {
        defers = deferral.firstSeen && !deferral.wanted.has(node.id);
        deferral.firstSeen = true;
    }

    const props: UINode["props"] = {};
    for (const [key, value] of Object.entries(node.props)) {
        const serialized = serializeValue(value, [key], new Set());
        if (serialized !== undefined) props[key] = serialized;
    }

    const children: UINode[] = [];
    for (const child of node.children) {
        if (child.kind === "instance" && child.type === SLOT) {
            const name = String(child.props.name);
            if (defers && deferral && DEFERRED_SLOTS.has(name)) {
                // Whether there's something to ask for: what `firstVisible` would find.
                const content = child.children.find((node) => !node.hidden);
                if (!content) {
                    props[name] = null;
                    continue;
                }
                const marker: { [key: string]: JsonValue } = { [DEFERRED]: true };
                if (name === "actions") {
                    const index = shortcutSet(content, deferral);
                    if (index !== undefined) marker.shortcuts = index;
                }
                props[name] = marker;
                continue;
            }
            const content = firstVisible(child.children, deferral);
            props[name] = content as unknown as JsonValue;
            continue;
        }
        const serialized = serializeNode(child, deferral);
        if (serialized) children.push(serialized);
    }
    return { id: node.id, type: node.type, props, children };
}

/** The index in `deferral.shortcutSets` of the shortcuts `panel`'s actions use, adding the set if it's new. */
function shortcutSet(panel: HostNode, deferral: Deferral): number | undefined {
    const found: JsonValue[] = [];
    collectShortcuts(panel, found);
    if (found.length === 0) return undefined;
    const key = JSON.stringify(found);
    let index = deferral.setIndex.get(key);
    if (index === undefined) {
        index = deferral.shortcutSets.length;
        deferral.shortcutSets.push(found);
        deferral.setIndex.set(key, index);
    }
    return index;
}

/** The `shortcut` of every visible `Action` in a panel, its sections and submenus. Element props (`$slot`), such as
 * `Action.Push`'s target, belong to other views and aren't searched. */
function collectShortcuts(node: HostNode, found: JsonValue[]): void {
    if (node.kind !== "instance" || node.hidden || node.type === SLOT) return;
    if (node.type === "Action") {
        const shortcut = serializeValue(node.props.shortcut, ["shortcut"], new Set());
        if (shortcut !== undefined && shortcut !== null) found.push(shortcut);
        return;
    }
    for (const child of node.children) collectShortcuts(child, found);
}

/** The first child that serializes to something, if any. */
export function firstVisible(nodes: readonly HostNode[], deferral?: Deferral): UINode | null {
    for (const node of nodes) {
        const serialized = serializeNode(node, deferral);
        if (serialized) return serialized;
    }
    return null;
}

/** An item's deferred slots, as a snapshot that carries them would hold them; null for a node that defers none. */
export function serializeSlots(node: HostNode): { [name: string]: JsonValue } | null {
    if (node.kind !== "instance" || !DEFERRING_TYPES.has(node.type) || node.hidden) return null;
    const slots: { [name: string]: JsonValue } = {};
    for (const child of node.children) {
        if (child.kind !== "instance" || child.type !== SLOT) continue;
        const name = String(child.props.name);
        if (DEFERRED_SLOTS.has(name)) slots[name] = firstVisible(child.children) as unknown as JsonValue;
    }
    return slots;
}

/** `undefined` means "leave the key out". */
function serializeValue(value: unknown, path: string[], ancestors: Set<object>): JsonValue | undefined {
    switch (typeof value) {
        case "string":
        case "boolean":
            return value;
        case "number":
            return Number.isFinite(value) ? value : null;
        case "bigint":
            return value.toString();
        case "function":
            return { $fn: path };
        case "undefined":
        case "symbol":
            return undefined;
    }
    if (value === null) return null;
    const object = value as object;
    if (object instanceof Date) return Number.isNaN(object.getTime()) ? null : { $date: object.toISOString() };
    if (isValidElement(object)) return undefined;
    if (ancestors.has(object)) return null;

    ancestors.add(object);
    let result: JsonValue;
    if (Array.isArray(object)) {
        result = object.map((item, index) => serializeValue(item, [...path, String(index)], ancestors) ?? null);
    } else {
        const entries: { [key: string]: JsonValue } = {};
        for (const [key, item] of Object.entries(object)) {
            const serialized = serializeValue(item, [...path, key], ancestors);
            if (serialized !== undefined) entries[key] = serialized;
        }
        result = entries;
    }
    ancestors.delete(object);
    return result;
}
