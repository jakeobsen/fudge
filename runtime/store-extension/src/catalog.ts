// The store's list: one entry per extension in the repository copy, with what's installed and what can be updated.
import { readdir } from "node:fs/promises";
import path from "node:path";
import { maxManifestBytes, readRegularFile } from "./files.ts";

/** `ExtensionManifest.isValidName`. It also rules out every character no-cone sparse patterns treat specially. */
const namePattern = /^[a-z0-9][a-z0-9-]*$/;

export function isValidName(name: unknown): name is string {
    return typeof name === "string" && namePattern.test(name);
}

export type StoreCommand = { name: string; title: string; description?: string; mode?: string };

export type StoreEntry = {
    /** The manifest's `name`, equal to its folder's: the row's identity. */
    name: string;
    title: string;
    description: string;
    author: string;
    /** The icon's file name in `assets/`, when it's a plain file name. */
    icon?: string;
    keywords: string[];
    categories: string[];
    license?: string;
    commands: StoreCommand[];
};

/** What `installed.json` records for an extension the store installed. */
export type InstallRecord = { tree: string; commit: string; installedAt: string };
export type Installed = Record<string, InstallRecord>;

export type Status = "available" | "installed" | "update";

const strings = (value: unknown): string[] =>
    Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];

/** A manifest as an entry, or undefined when its name is invalid, differs from `folder`, or it has no commands. */
export function parseManifest(folder: string, manifest: unknown): StoreEntry | undefined {
    if (!isValidName(folder) || typeof manifest !== "object" || manifest === null) return undefined;
    const object = manifest as Record<string, unknown>;
    if (!isValidName(object.name) || object.name !== folder || typeof object.title !== "string") return undefined;
    const commands = (Array.isArray(object.commands) ? object.commands : []).flatMap((command): StoreCommand[] => {
        if (typeof command !== "object" || command === null) return [];
        const { name, title, description, mode } = command as Record<string, unknown>;
        if (typeof name !== "string" || typeof title !== "string") return [];
        return [
            {
                name,
                title,
                ...(typeof description === "string" ? { description } : {}),
                ...(typeof mode === "string" ? { mode } : {}),
            },
        ];
    });
    if (commands.length === 0) return undefined;
    const icon = typeof object.icon === "string" && /^[\w@.-]+$/.test(object.icon) && !object.icon.startsWith(".");
    return {
        name: object.name,
        title: object.title,
        description: typeof object.description === "string" ? object.description : "",
        author: typeof object.author === "string" ? object.author : "",
        ...(icon ? { icon: object.icon as string } : {}),
        keywords: strings(object.keywords),
        categories: strings(object.categories),
        ...(typeof object.license === "string" ? { license: object.license } : {}),
        commands,
    };
}

/** Every valid entry under `<repo>/extensions/`. A folder's name is checked before it's joined into a path. */
export async function readCatalog(repo: string): Promise<StoreEntry[]> {
    const root = path.join(repo, "extensions");
    const folders = await readdir(root, { withFileTypes: true }).catch(() => []);
    const entries = await Promise.all(
        folders
            .filter((folder) => folder.isDirectory() && isValidName(folder.name))
            .map(async (folder) => {
                const text = await readRegularFile(path.join(root, folder.name, "package.json"), maxManifestBytes).catch(
                    () => undefined,
                );
                if (text === undefined) return undefined;
                try {
                    return parseManifest(folder.name, JSON.parse(text));
                } catch {
                    return undefined;
                }
            }),
    );
    return entries.filter((entry): entry is StoreEntry => entry !== undefined).sort(byTitle);
}

export function byTitle(a: StoreEntry, b: StoreEntry): number {
    return a.title.localeCompare(b.title, "en", { sensitivity: "base" }) || a.name.localeCompare(b.name);
}

/** Installed when `installed.json` has it; an update when its folder's tree id has changed since. */
export function status(entry: StoreEntry, installed: Installed, trees: Map<string, string>): Status {
    const record = installed[entry.name];
    if (!record) return "available";
    const tree = trees.get(entry.name);
    return tree !== undefined && tree !== record.tree ? "update" : "installed";
}

/** The search bar's dropdown values: "All", "Installed", then every category by name. */
export const allFilter = "all";
export const installedFilter = "installed";

export function categories(entries: StoreEntry[]): string[] {
    return [...new Set(entries.flatMap((entry) => entry.categories))].sort((a, b) => a.localeCompare(b, "en"));
}

/** The entries `filter` shows: all, the installed ones, or one category's (a category value is `category:<name>`). */
export function filterEntries(entries: StoreEntry[], filter: string, installed: Installed): StoreEntry[] {
    if (filter === installedFilter) return entries.filter((entry) => installed[entry.name] !== undefined);
    if (filter.startsWith("category:")) {
        const category = filter.slice("category:".length);
        return entries.filter((entry) => entry.categories.includes(category));
    }
    return entries;
}

/** The installed ones first, then the rest; each by title. */
export function sections(entries: StoreEntry[], installed: Installed): { installed: StoreEntry[]; other: StoreEntry[] } {
    const sorted = [...entries].sort(byTitle);
    return {
        installed: sorted.filter((entry) => installed[entry.name] !== undefined),
        other: sorted.filter((entry) => installed[entry.name] === undefined),
    };
}

/** What List filtering searches besides the title: the keywords, the author and the name. */
export function searchKeywords(entry: StoreEntry): string[] {
    return [...entry.keywords, entry.author, entry.name].filter((word) => word.length > 0);
}

export type AccessoryText = { text: string } | { tag: string };

/** The author, the number of commands, and Installed or Update available. */
export function accessoryTexts(entry: StoreEntry, state: Status): AccessoryText[] {
    const accessories: AccessoryText[] = [];
    if (entry.author) accessories.push({ text: entry.author });
    accessories.push({ text: entry.commands.length === 1 ? "1 command" : `${entry.commands.length} commands` });
    if (state === "installed") accessories.push({ tag: "Installed" });
    if (state === "update") accessories.push({ tag: "Update available" });
    return accessories;
}

/** The extension's folder at `commit`, on github.com and as raw files. */
export function folderURL(name: string, commit: string): string {
    return `https://github.com/raycast/extensions/tree/${commit}/extensions/${name}`;
}

export function rawURL(name: string, commit: string, file: string): string {
    return `https://raw.githubusercontent.com/raycast/extensions/${commit}/extensions/${name}/${file}`;
}

export function iconURL(entry: StoreEntry, commit: string): string | undefined {
    return entry.icon ? rawURL(entry.name, commit, `assets/${entry.icon}`) : undefined;
}
