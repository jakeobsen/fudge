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

// The Extension Store's calls about extensions with a part written in Swift (SPEC-145 §3). Only the store may make
// them; the app refuses any other extension.

/**
 * Whether Apple's Command Line Tools are set up, found exactly as Settings → Development and `fudge build` find them,
 * so the store and the build never disagree.
 */
export async function commandLineToolsReady(): Promise<boolean> {
    return (await callApp("commandLineTools.ready")) === true;
}

/** Opens Settings → Development. Only from the user's own action in the store: a background call is refused. */
export async function openDevelopmentSettings(): Promise<void> {
    await callApp("commandLineTools.openSettings");
}

// The Extension Store's install notifications (SPEC-156). Only the store may make these calls; the app refuses any
// other extension.

/** An install or update the store ended: the last build it ran (a refusal before any build has none), and how. */
export type InstallEndReport = {
    build?: { pid: number; startedAt: string };
    name: string;
    dir: string;
    title: string;
    updating: boolean;
    outcome: "installed" | "failed";
};

/** The app's answer: whether the store is on screen, and whether a notification went out. */
export type InstallAnswer = { onScreen: boolean; notified: boolean };

/** What a click on a notification opens: the extension's row, and its failure view when it failed. */
export type NotificationClick = { name: string; dir: string; failed: boolean; repository?: string };

/** Tells the app an install or update ended, so it decides whether a notification goes out, once per build. */
export async function installEnded(report: InstallEndReport): Promise<InstallAnswer> {
    const answer = (await callApp("store.installEnded", report)) as Record<string, unknown> | null;
    if (typeof answer?.onScreen !== "boolean" || typeof answer.notified !== "boolean") {
        throw new Error("The app's answer about the notification isn't one");
    }
    return { onScreen: answer.onScreen, notified: answer.notified };
}

/** After the user confirmed an install or update: macOS asks whether Fudge may show notifications, if it hasn't yet. */
export async function askForNotifications(): Promise<void> {
    await callApp("store.askForNotifications");
}

/**
 * Waits for the next click on one of Fudge's install notifications while this store session is loaded; null when the
 * call was replaced by a newer one.
 */
export async function nextNotificationClick(): Promise<NotificationClick | null> {
    const click = (await callApp("store.nextNotificationClick")) as Record<string, unknown> | null;
    if (click === null || typeof click !== "object") return null;
    const { name, dir, failed, repository } = click;
    if (typeof name !== "string" || typeof dir !== "string" || typeof failed !== "boolean") return null;
    return typeof repository === "string" ? { name, dir, failed, repository } : { name, dir, failed };
}

// The Extension Store's repositories (FUD-182). Only the store may ask; the app refuses any other extension.

/**
 * The list of repositories from Settings, as the app answers it: Raycast's official repository first, then each added
 * one, `{ copyId, folder, address, branch?, name, on }`. It comes as it is; the store checks it again with
 * `checkRepositoriesAnswer` (`repository-address.ts`) before using any of it.
 */
export async function extensionRepositories(): Promise<unknown> {
    return await callApp("store.repositories");
}

export function createFudgeAppModule() {
    return Object.freeze({
        logToFudge,
        commandLineToolsReady,
        openDevelopmentSettings,
        installEnded,
        askForNotifications,
        nextNotificationClick,
        extensionRepositories,
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
