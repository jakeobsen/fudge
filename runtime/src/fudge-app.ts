// `fudge:app`: what Fudge's bundled extensions ask of the app beyond Raycast's API. The worker hands this module to
// `require("fudge:app")` (see worker.ts), and `fudge build` keeps it external, as it does `@raycast/api`.

import { callApp } from "./bridge.ts";
import { revive } from "./protocol.ts";

/** A file or folder Spotlight found. `kind` is Spotlight's localized kind ("PDF document"). */
export type FoundFile = {
    path: string;
    name: string;
    kind: string;
    isFolder: boolean;
    size?: number;
    modified: Date;
    lastUsed?: Date;
};

/**
 * Files and folders whose names hold every word of `query`, best match first, or with an empty query the files used
 * lately. Where the app looks and what it leaves out are the Search Files extension's preferences, and only that
 * extension may call it.
 */
export async function searchFiles(query: string, limit?: number): Promise<FoundFile[]> {
    const answer = await callApp("files.search", limit === undefined ? { query } : { query, limit });
    return revive(answer) as FoundFile[];
}

export function createFudgeAppModule() {
    return Object.freeze({ searchFiles });
}
