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

// Clipboard History's calls. Only the Clipboard History extension may make them; the app refuses any other.

/** One copy in the clipboard history. */
export type ClipboardEntry = {
    /** Stable for as long as the entry is kept. */
    id: string;
    kind: "text" | "link" | "image" | "files";
    /** A text's or a link's text: only its first 1 MB when `truncated`. */
    text?: string;
    truncated?: boolean;
    /** Absolute paths, for files. */
    files?: string[];
    /** An image's or the first file's display name, when it has one. */
    name?: string;
    /** The app it was copied from, when that's known. */
    app?: { bundleId: string; name?: string };
    copiedAt: Date;
    /** Bytes: a text's UTF-8 length, an image's PNG size. For files, use `files.length`. */
    size: number;
    pinned: boolean;
    /** An image's size in pixels. */
    width?: number;
    height?: number;
};

/** The history, newest first, or `on: false` and no entries while it's turned off. */
export type ClipboardHistory = { on: boolean; entries: ClipboardEntry[] };

export async function listClipboardHistory(): Promise<ClipboardHistory> {
    return revive(await callApp("clipboardHistory.list")) as ClipboardHistory;
}

/** A PNG copy of an image entry, which the app deletes when the command ends or Fudge quits. */
export async function clipboardImage(id: string): Promise<{ path: string }> {
    return revive(await callApp("clipboardHistory.image", { id })) as { path: string };
}

/** Pastes the entry into the app the user is in, as it was copied. The app hides Fudge's window. */
export async function pasteClipboardEntry(id: string): Promise<void> {
    await callApp("clipboardHistory.paste", { id });
}

/** Puts the entry on the clipboard, as it was copied. */
export async function copyClipboardEntry(id: string): Promise<void> {
    await callApp("clipboardHistory.copy", { id });
}

export async function pinClipboardEntry(id: string, pinned: boolean): Promise<void> {
    await callApp("clipboardHistory.pin", { id, pinned });
}

export async function deleteClipboardEntry(id: string): Promise<void> {
    await callApp("clipboardHistory.delete", { id });
}

/** Deletes every entry, pinned ones too. */
export async function clearClipboardHistory(): Promise<void> {
    await callApp("clipboardHistory.clear", {});
}

/**
 * Writes a line into `Fudge.log` (SPEC-124), for what the Extension Store does on Fudge's behalf: a failed install,
 * update or uninstall with the build's output, and a list that couldn't be downloaded. Only the store may call it.
 */
export async function logToFudge(level: "error" | "warning" | "info", message: string): Promise<void> {
    await callApp("fudge.log", { level, message });
}

export function createFudgeAppModule() {
    return Object.freeze({
        logToFudge,
        searchFiles,
        listClipboardHistory,
        clipboardImage,
        pasteClipboardEntry,
        copyClipboardEntry,
        pinClipboardEntry,
        deleteClipboardEntry,
        clearClipboardHistory,
    });
}
