// launchCommand: starts another command of this extension, or of another
// installed one. The app finds the command and launches it (`command.launch`,
// see LauncherModel); the promise settles once the launch has started, not
// when the command finishes.

import { callApp } from "../bridge.ts";
import { encode } from "../protocol.ts";
import { LaunchType } from "./constants.ts";

export type LaunchOptions = {
    name: string;
    type: string;
    extensionName?: string | null;
    ownerOrAuthorName?: string | null;
    arguments?: Record<string, unknown> | null;
    context?: Record<string, unknown> | null;
    fallbackText?: string | null;
};

/** What `command.launch` carries to the app. */
export type LaunchParams = {
    name: string;
    type: string;
    extensionName?: string;
    ownerOrAuthorName?: string;
    arguments: Record<string, string>;
    /** With Dates and Buffers as `$date` and `$buffer` markers, which the launched command's worker revives. */
    context?: unknown;
    fallbackText?: string;
};

export async function launchCommand(options: LaunchOptions): Promise<void> {
    await callApp("command.launch", launchParams(options));
}

/** Checks the options and turns them into the call's params. `null` means absent. Throws a TypeError. */
export function launchParams(options: LaunchOptions): LaunchParams {
    const { name, type } = options ?? ({} as Partial<LaunchOptions>);
    if (typeof name !== "string" || name === "") throw new TypeError("launchCommand: name is required");
    if (type !== LaunchType.UserInitiated && type !== LaunchType.Background) {
        throw new TypeError("launchCommand: type must be LaunchType.UserInitiated or LaunchType.Background");
    }
    const extensionName = optionalString(options, "extensionName");
    const ownerOrAuthorName = optionalString(options, "ownerOrAuthorName");
    if (extensionName !== undefined && ownerOrAuthorName === undefined) {
        throw new TypeError("launchCommand: ownerOrAuthorName is required with extensionName");
    }
    if (ownerOrAuthorName !== undefined && extensionName === undefined) {
        throw new TypeError("launchCommand: extensionName is required with ownerOrAuthorName");
    }
    const params: LaunchParams = { name, type, arguments: stringArguments(options.arguments) };
    if (extensionName !== undefined) {
        params.extensionName = extensionName;
        params.ownerOrAuthorName = ownerOrAuthorName;
    }
    if (options.context !== undefined && options.context !== null) {
        if (typeof options.context !== "object" || Array.isArray(options.context)) {
            throw new TypeError("launchCommand: context must be an object");
        }
        try {
            params.context = encode(options.context);
        } catch (error) {
            throw new TypeError(`launchCommand: context must be JSON serializable: ${(error as Error).message}`);
        }
    }
    const fallbackText = optionalString(options, "fallbackText");
    if (fallbackText !== undefined) params.fallbackText = fallbackText;
    return params;
}

function optionalString(options: LaunchOptions, key: "extensionName" | "ownerOrAuthorName" | "fallbackText") {
    const value = options[key];
    if (value === undefined || value === null) return undefined;
    if (typeof value !== "string") throw new TypeError(`launchCommand: ${key} must be a string`);
    return value;
}

/** Strings pass, numbers and booleans become strings, null and undefined count as not given. */
function stringArguments(given: Record<string, unknown> | null | undefined): Record<string, string> {
    if (given === undefined || given === null) return {};
    if (typeof given !== "object" || Array.isArray(given)) throw new TypeError("launchCommand: arguments must be an object");
    const result: Record<string, string> = {};
    for (const [key, value] of Object.entries(given)) {
        if (value === undefined || value === null) continue;
        if (typeof value === "string") result[key] = value;
        else if (typeof value === "number" || typeof value === "boolean") result[key] = String(value);
        else throw new TypeError(`launchCommand: argument "${key}" must be a string`);
    }
    return result;
}
