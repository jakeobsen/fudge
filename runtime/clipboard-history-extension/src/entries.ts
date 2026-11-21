// What Clipboard History shows for an entry: its section, title, search keywords, and the detail's markdown and
// metadata. Pure, so tests can check it without the app.

import path from "node:path";
import { pathToFileURL } from "node:url";
import type { ClipboardEntry } from "fudge:app";

export type Section = { title: string; entries: ClipboardEntry[] };

const newestFirst = (a: ClipboardEntry, b: ClipboardEntry) => b.copiedAt.getTime() - a.copiedAt.getTime();

/** Pinned, then Recent, each newest first. A section with nothing in it is left out. */
export function sections(entries: readonly ClipboardEntry[]): Section[] {
    const pinned = entries.filter((entry) => entry.pinned).sort(newestFirst);
    const recent = entries.filter((entry) => !entry.pinned).sort(newestFirst);
    return [
        { title: "Pinned", entries: pinned },
        { title: "Recent", entries: recent },
    ].filter((section) => section.entries.length > 0);
}

/** A title's longest length, and how much of a text is searched beyond its title. */
const titleLength = 200;
const searchLength = 500;
/** How many files the detail lists. */
export const filesShown = 100;

/** `text` cut to `length` with an ellipsis, never between a surrogate pair. */
function cut(text: string, length: number): string {
    if (text.length <= length) return text;
    const end = /[\uD800-\uDBFF]/.test(text[length - 1]!) ? length - 1 : length;
    return `${text.slice(0, end)}…`;
}

/** The first line with something on it, trimmed. */
function firstLine(text: string): string {
    // A title never needs more than the start of a long text.
    for (const line of text.slice(0, 10_000).split(/\r\n|\r|\n/)) {
        const trimmed = line.trim();
        if (trimmed !== "") return trimmed;
    }
    return "";
}

function fileNames(entry: ClipboardEntry): string[] {
    return (entry.files ?? []).map((file) => path.basename(file));
}

/** The entry's type, as the detail shows it. */
export function kindName(entry: ClipboardEntry): string {
    switch (entry.kind) {
        case "text":
            return "Text";
        case "link":
            return "Link";
        case "image":
            return "Image";
        case "files":
            return entry.files?.length === 1 ? "File" : "Files";
    }
}

/** The list item's title: a text's first line, an image's or the first file's name, or else its type. */
export function title(entry: ClipboardEntry): string {
    switch (entry.kind) {
        case "text":
        case "link":
            return cut(firstLine(entry.text ?? ""), titleLength) || kindName(entry);
        case "image":
            return entry.name || kindName(entry);
        case "files": {
            const names = fileNames(entry);
            const first = entry.name || names[0];
            if (!first) return kindName(entry);
            return names.length > 1 ? `${first} and ${names.length - 1} more` : first;
        }
    }
}

/** What Fudge searches besides the title: the start of a text, or every file's name. */
export function keywords(entry: ClipboardEntry): string[] {
    switch (entry.kind) {
        case "text":
        case "link": {
            const text = cut((entry.text ?? "").slice(0, searchLength * 2).replace(/\s+/g, " ").trim(), searchLength);
            return text === "" || text === title(entry) ? [] : [text];
        }
        case "image":
            return [];
        case "files": {
            const names = fileNames(entry);
            return names.length > 1 ? names.slice(0, filesShown) : [];
        }
    }
}

/** A text as a fenced code block, shown as it is: the fence is longer than any run of backticks in it. */
export function textMarkdown(text: string): string {
    let longest = 0;
    for (const run of text.matchAll(/`+/g)) longest = Math.max(longest, run[0].length);
    const fence = "`".repeat(Math.max(3, longest + 1));
    return `${fence}\n${text}\n${fence}`;
}

/** An image file, by its `file://` URL, with the parentheses markdown would end the link at encoded. */
export function imageMarkdown(file: string): string {
    const url = pathToFileURL(file).href.replaceAll("(", "%28").replaceAll(")", "%29");
    return `![](${url})`;
}

/** Every ASCII punctuation character backslash-escaped, so markdown shows a name as it is. */
function escapeMarkdown(text: string): string {
    return text.replace(/[!-/:-@[-`{-~]/g, "\\$&");
}

/** Each file's name in bold, its path under it. */
export function filesMarkdown(files: readonly string[]): string {
    const shown = files.slice(0, filesShown).map((file) => `**${escapeMarkdown(path.basename(file))}**  \n${escapeMarkdown(file)}`);
    if (files.length > filesShown) shown.push(`And ${files.length - filesShown} more.`);
    return shown.join("\n\n");
}

/** The detail's markdown; an image's needs its file (`clipboardHistory.image`), and has none until it's read. */
export function detailMarkdown(entry: ClipboardEntry, imageFile?: string): string | undefined {
    switch (entry.kind) {
        case "text":
        case "link":
            return textMarkdown(entry.text ?? "");
        case "image":
            return imageFile === undefined ? undefined : imageMarkdown(imageFile);
        case "files":
            return filesMarkdown(entry.files ?? []);
    }
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

function count(n: number, one: string, many: string, locale?: string): string {
    return `${new Intl.NumberFormat(locale).format(n)} ${n === 1 ? one : many}`;
}

/** Characters as people count them: an emoji is one, not two UTF-16 units. */
function characters(text: string): number {
    let n = 0;
    for (const _ of text) n++;
    return n;
}

/** A text's characters (marked when only its start was kept), an image's pixels and bytes, or how many files. */
export function sizeText(entry: ClipboardEntry, locale?: string): string {
    switch (entry.kind) {
        case "text":
        case "link": {
            const size = count(characters(entry.text ?? ""), "character", "characters", locale);
            return entry.truncated ? `${size} (truncated)` : size;
        }
        case "image": {
            const bytes = formatSize(entry.size, locale);
            return entry.width && entry.height ? `${entry.width} × ${entry.height}, ${bytes}` : bytes;
        }
        case "files":
            return count(entry.files?.length ?? 0, "file", "files", locale);
    }
}

export type DetailField = { title: string; text: string };

/** The detail's metadata: Type, App (when it's known), Copied and Size. */
export function detailFields(entry: ClipboardEntry, locale?: string): DetailField[] {
    const fields: DetailField[] = [{ title: "Type", text: kindName(entry) }];
    if (entry.app) fields.push({ title: "App", text: entry.app.name || entry.app.bundleId });
    fields.push({ title: "Copied", text: formatDate(entry.copiedAt, locale) });
    fields.push({ title: "Size", text: sizeText(entry, locale) });
    return fields;
}
