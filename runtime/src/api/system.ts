// Clipboard, opening things, the Trash, applications and the selection: done
// by the app, asked for over rpc (see bridge.ts).

import { fileURLToPath } from "node:url";
import { callApp } from "../bridge.ts";

type PathLike = string | Buffer | URL;
type Application = { name: string; path: string; bundleId?: string; localizedName?: string };
type FileSystemItem = { path: string };
type Content = string | number | { text: string } | { file: PathLike } | { html: string; text?: string };

function pathOf(path: PathLike): string {
    if (path instanceof URL) return fileURLToPath(path);
    return typeof path === "string" ? path : path.toString("utf8");
}

function normalize(content: Content): { text?: string; html?: string; file?: string } {
    if (typeof content === "string" || typeof content === "number") return { text: String(content) };
    if ("file" in content) return { file: pathOf(content.file) };
    if ("html" in content) return { html: content.html, text: content.text };
    return { text: content.text };
}

export const Clipboard = {
    async copy(content: Content, options: { concealed?: boolean; transient?: boolean } = {}): Promise<void> {
        await callApp("clipboard.copy", { ...normalize(content), concealed: options.concealed ?? false, transient: options.transient ?? false });
    },
    async clear(): Promise<void> {
        await callApp("clipboard.clear");
    },
    async read(options: { offset?: number } = {}): Promise<{ text: string; file?: string; html?: string }> {
        const content = await callApp<{ text: string; file?: string; html?: string } | null>("clipboard.read", { offset: options.offset ?? 0 });
        return content ?? { text: "" };
    },
    async readText(options: { offset?: number } = {}): Promise<string | undefined> {
        const content = await callApp<{ text?: string } | null>("clipboard.read", { offset: options.offset ?? 0 });
        return content?.text;
    },
    /**
     * Pastes into the app the user is in: the app writes the content, posts ⌘V there (which needs Accessibility
     * permission) and puts the clipboard back a second later. Closes fudge's window first unless told not to.
     */
    async paste(content: Content, options: { closeMainWindow?: boolean } = {}): Promise<void> {
        await callApp("clipboard.paste", { ...normalize(content), closeMainWindow: options.closeMainWindow ?? true });
    },
};

/** @deprecated Use Clipboard.copy. */
export const copyTextToClipboard = (text: string) => Clipboard.copy(text);
/** @deprecated Use Clipboard.clear. */
export const clearClipboard = () => Clipboard.clear();
/** @deprecated Use Clipboard.paste. */
export const pasteText = (text: string) => Clipboard.paste(text);

/** Opens a file, folder or URL, optionally with a given application (name, path, bundle id or Application). */
export async function open(target: string, application?: Application | string): Promise<void> {
    const app = typeof application === "string" ? application : application?.path;
    await callApp("open", { target, application: app ?? null });
}

export async function trash(path: PathLike | PathLike[]): Promise<void> {
    const paths = Array.isArray(path) ? path.map(pathOf) : [pathOf(path)];
    await callApp("trash", { paths });
}

export async function showInFinder(path: PathLike): Promise<void> {
    await callApp("showInFinder", { path: pathOf(path) });
}

/** Every installed application, or those that can open `path`. */
export async function getApplications(path?: PathLike): Promise<Application[]> {
    return callApp<Application[]>("applications.list", { path: path === undefined ? null : pathOf(path) });
}

export async function getDefaultApplication(path: PathLike): Promise<Application> {
    return callApp<Application>("applications.default", { path: pathOf(path) });
}

export async function getFrontmostApplication(): Promise<Application> {
    return callApp<Application>("applications.frontmost");
}

/**
 * The selected text of the frontmost application. The app asks the Accessibility API, and when that gives nothing,
 * copies with ⌘C and restores the clipboard right after. Rejects when nothing is selected.
 */
export async function getSelectedText(): Promise<string> {
    return callApp<string>("selection.text");
}

/** The items selected in Finder, in Finder's order. Rejects when Finder isn't the frontmost application. */
export async function getSelectedFinderItems(): Promise<FileSystemItem[]> {
    return callApp<FileSystemItem[]>("selection.finderItems");
}
