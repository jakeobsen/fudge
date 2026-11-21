// Two exports Raycast keeps for old extensions: the `preferences` record and `randomId`.

import { getRandomValues } from "node:crypto";
import { readFileSync } from "node:fs";
import { launchContext, type LaunchContext } from "./launch.ts";
import { plainRecords } from "./stubs.ts";

/** One preference, as Raycast's deprecated `Preference` describes it. */
export type Preference = {
    name: string;
    type: string;
    required: boolean;
    title: string;
    description: string;
    value?: unknown;
    default?: unknown;
    placeholder?: string;
    label?: string;
    data?: unknown[];
};

type Declaration = Record<string, unknown>;

let built: { context: LaunchContext; record: Record<string, Preference> } | null = null;

/**
 * The running command's preferences by name: the manifest's declarations, the extension's and then the command's
 * own (which win), each with the value `getPreferenceValues()` gives it. Built when first read, from the launch.
 */
function record(): Record<string, Preference> {
    const context = launchContext();
    if (built?.context === context) return built.record;
    const result: Record<string, Preference> = {};
    for (const declaration of declarations(context)) {
        const name = declaration.name;
        if (typeof name !== "string" || name === "") continue;
        const text = (key: string) => (typeof declaration[key] === "string" ? (declaration[key] as string) : "");
        const preference: Preference = {
            name,
            type: text("type"),
            required: declaration.required === true,
            title: text("title"),
            description: text("description"),
        };
        if (name in context.preferences) preference.value = context.preferences[name];
        if ("default" in declaration) preference.default = declaration.default;
        if (typeof declaration.placeholder === "string") preference.placeholder = declaration.placeholder;
        if (typeof declaration.label === "string") preference.label = declaration.label;
        if (Array.isArray(declaration.data)) preference.data = declaration.data;
        result[name] = preference;
    }
    built = { context, record: result };
    return result;
}

/** The extension's preference declarations, then the running command's. None when the manifest can't be read. */
function declarations(context: LaunchContext): Declaration[] {
    if (!context.manifestFile) return [];
    let manifest: { preferences?: unknown; commands?: unknown };
    try {
        manifest = JSON.parse(readFileSync(context.manifestFile, "utf8")) as typeof manifest;
    } catch {
        return [];
    }
    const list = (value: unknown) => (Array.isArray(value) ? value.filter(isObject) : []);
    const command = list(manifest.commands).find((entry) => entry.name === context.environment.commandName);
    return [...list(manifest.preferences), ...list(command?.preferences)];
}

function isObject(value: unknown): value is Declaration {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** @deprecated in Raycast, which recommends `getPreferenceValues()`. Read-only. */
export const preferences: Record<string, Preference> = new Proxy({} as Record<string, Preference>, {
    get: (_target, key) => (typeof key === "string" ? record()[key] : undefined),
    has: (_target, key) => typeof key === "string" && key in record(),
    ownKeys: () => Object.keys(record()),
    getOwnPropertyDescriptor: (_target, key) => {
        if (typeof key !== "string" || !(key in record())) return undefined;
        return { value: record()[key], writable: false, enumerable: true, configurable: true };
    },
    set: () => false,
    defineProperty: () => false,
    deleteProperty: () => false,
});
plainRecords.add(preferences);

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

/** @deprecated in Raycast, which recommends `nanoid`. A random, URL-safe id: 21 characters by default. */
export function randomId(size = 21): string {
    const bytes = getRandomValues(new Uint8Array(size));
    let id = "";
    for (const byte of bytes) id += alphabet[byte & 63];
    return id;
}
