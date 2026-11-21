// What the app told the worker about this launch. Set once by worker.ts
// before the command runs; read by the API functions that need it.

import type { LaunchProps } from "../protocol.ts";

/** Facts about the extension and command, from the app (see protocol.ts `LaunchEnvironment`). */
export type LaunchEnvironment = {
    extensionName: string;
    commandName: string;
    commandMode: "view" | "no-view" | "menu-bar";
    assetsPath: string;
    supportPath: string;
    /** Folder for `Cache`. */
    cachePath: string;
    /** File for `LocalStorage`. */
    localStoragePath: string;
    ownerOrAuthorName: string;
    appearance: "light" | "dark";
    isDevelopment: boolean;
};

export type LaunchContext = {
    /** Resolved preference values: extension-wide ones merged with the command's own. */
    preferences: Record<string, unknown>;
    /** The installed extension's `package.json`, beside its `dist/` folder; for the deprecated `preferences`. */
    manifestFile?: string;
    environment: LaunchEnvironment;
    launchProps: LaunchProps;
};

export const placeholderEnvironment: LaunchEnvironment = {
    extensionName: "",
    commandName: "",
    commandMode: "view",
    assetsPath: "",
    supportPath: "",
    cachePath: "",
    localStoragePath: "",
    ownerOrAuthorName: "",
    appearance: "dark",
    isDevelopment: false,
};

let context: LaunchContext = { preferences: {}, environment: placeholderEnvironment, launchProps: {} };

export function setLaunchContext(next: LaunchContext): void {
    context = next;
}

export function launchContext(): LaunchContext {
    return context;
}
