// Turns the host tree into JSON for the app.
//
// Functions become `{ "$fn": [...path] }` markers; the app calls one back by
// sending the node id and that path. Dates become `{ "$date": iso }`. React
// elements passed as props (`actions={<ActionPanel/>}`) arrive here as
// `$slot` children (see api/components.ts) and are put back as props.

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

export function serializeNode(node: HostNode): UINode | null {
    if (node.hidden) return null;
    if (node.kind === "text") return { id: node.id, type: "#text", props: { text: node.text }, children: [] };

    const props: UINode["props"] = {};
    for (const [key, value] of Object.entries(node.props)) {
        const serialized = serializeValue(value, [key], new Set());
        if (serialized !== undefined) props[key] = serialized;
    }

    const children: UINode[] = [];
    for (const child of node.children) {
        if (child.kind === "instance" && child.type === SLOT) {
            const content = firstVisible(child.children);
            props[String(child.props.name)] = content as unknown as JsonValue;
            continue;
        }
        const serialized = serializeNode(child);
        if (serialized) children.push(serialized);
    }
    return { id: node.id, type: node.type, props, children };
}

/** The first child that serializes to something, if any. */
export function firstVisible(nodes: readonly HostNode[]): UINode | null {
    for (const node of nodes) {
        const serialized = serializeNode(node);
        if (serialized) return serialized;
    }
    return null;
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
