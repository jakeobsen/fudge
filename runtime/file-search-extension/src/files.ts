// What Search Files shows for a found file: its folder, its size, its dates and the detail pane's fields, and the
// empty views. Pure, so tests can check it without the app.

import path from "node:path";
import type { FoundFile } from "fudge:app";

/** How many files one search asks for. */
export const searchLimit = 200;

/** `folder` with the home folder written as `~`. */
export function tildePath(folder: string, home: string): string {
    const base = home.length > 1 && home.endsWith("/") ? home.slice(0, -1) : home;
    if (base === "" || base === "/") return folder;
    if (folder === base) return "~";
    if (folder.startsWith(`${base}/`)) return `~${folder.slice(base.length)}`;
    return folder;
}

/** The folder a file is in, with the home folder written as `~`: the item's subtitle and the detail's Where. */
export function whereText(file: Pick<FoundFile, "path">, home: string): string {
    return tildePath(path.dirname(file.path), home);
}

const sizeUnits = ["KB", "MB", "GB", "TB", "PB"];

/** A size as Finder writes it, in units of 1,000 bytes: "512 bytes", "13 KB", "1.2 MB". */
export function formatSize(bytes: number, locale?: string): string {
    if (bytes < 1000) return bytes === 1 ? "1 byte" : `${bytes} bytes`;
    let value = bytes;
    for (const [index, unit] of sizeUnits.entries()) {
        value /= 1000;
        // Whole kilobytes; a decimal from megabytes up.
        const digits = index === 0 ? 0 : 1;
        const rounded = Number(value.toFixed(digits));
        if (rounded < 1000 || index === sizeUnits.length - 1) {
            return `${new Intl.NumberFormat(locale, { maximumFractionDigits: digits }).format(rounded)} ${unit}`;
        }
    }
    return `${bytes} bytes`;
}

export function formatDate(date: Date, locale?: string): string {
    return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(date);
}

export type DetailField = { title: string; text: string };

/** The detail pane's metadata: Kind, Size (files only), Where, Modified, and Last Opened when it's known. */
export function detailFields(file: FoundFile, home: string, locale?: string): DetailField[] {
    const fields: DetailField[] = [{ title: "Kind", text: file.kind }];
    if (!file.isFolder && file.size !== undefined) fields.push({ title: "Size", text: formatSize(file.size, locale) });
    fields.push({ title: "Where", text: whereText(file, home) });
    fields.push({ title: "Modified", text: formatDate(file.modified, locale) });
    if (file.lastUsed) fields.push({ title: "Last Opened", text: formatDate(file.lastUsed, locale) });
    return fields;
}

/** The empty view, for a search that found nothing: `searchIn` is the extension's Search In preference. */
export function emptyView(query: string, searchIn: string | undefined): { title: string; description?: string } {
    if (query.trim() === "") return { title: "Type to Search Files" };
    return { title: "No Files Found", description: `Search In: ${searchIn === "mac" ? "This Mac" : "Home Folder"}` };
}
