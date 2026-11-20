// Clipboard, opening things, the Trash and applications: done by the app,
// asked for over rpc (see bridge.ts).

import { fileURLToPath } from "node:url";
import { callApp } from "../bridge.ts";
import { notAvailable } from "./stubs.ts";

type PathLike = string | Buffer | URL;
type Application = { name: string; path: string; bundleId?: string; localizedName?: string };
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
    // Pasting into the frontmost app means posting ⌘V, which needs Accessibility permission.
    paste: notAvailable("Clipboard.paste") as (content: Content) => Promise<void>,
};

/** @deprecated Use Clipboard.copy. */
export const copyTextToClipboard = (text: string) => Clipboard.copy(text);
/** @deprecated Use Clipboard.clear. */
export const clearClipboard = () => Clipboard.clear();
/** @deprecated Use Clipboard.paste. */
export const pasteText = notAvailable("pasteText");

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
