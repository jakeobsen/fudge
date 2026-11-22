// The store's list: one entry per extension in the repository copy, with what's installed and what can be updated.
import { readdir } from "node:fs/promises";
import path from "node:path";
import { isValidName } from "../../src/extension-id.ts";
import { maxManifestBytes, readRegularFile } from "./files.ts";

// `ExtensionManifest.isValidName`, the one extension name rule, kept beside the id rule that builds on it.
export { isValidName };

/**
 * A folder in Raycast's repository, under `extensions/`: one path segment of letters, digits, `.`, `_` and `-`,
 * starting with a letter or digit, so never `.` or `..`, and none of the characters no-cone sparse patterns treat
 * specially. It can differ from the extension's name (`amazon-aws` holds `aws`) and isn't a valid name itself
 * (`http.cat`, `CodeBlocks`).
 */
const folderPattern = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

export function isValidFolder(folder: unknown): folder is string {
    return typeof folder === "string" && folderPattern.test(folder);
}

/** Whether two folders are the same one on APFS, which ignores case. */
export function sameFolder(a: string, b: string): boolean {
    return a.toLowerCase() === b.toLowerCase();
}

export type StoreCommand = { name: string; title: string; description?: string; mode?: string };

export type StoreEntry = {
    /** The manifest's `name`, the extension's identity as in Raycast: its installed folder, and its `installed.json`
     * key, settings and data. */
    name: string;
    /** Its folder in Raycast's repository, which can differ from `name`: for the sparse pattern, the README, the
     * scan, the build's source and the URLs. It also tells apart two folders whose manifests share a name. */
    dir: string;
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

/** What `installed.json` records for an extension the store installed, by name. `dir` is the folder it came from,
 * which its updates follow. */
export type InstallRecord = { tree: string; commit: string; installedAt: string; dir: string };
export type Installed = Record<string, InstallRecord>;

export type Status = "available" | "installed" | "update";

const strings = (value: unknown): string[] =>
    Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];

/** A manifest as an entry, or undefined when the folder or the name isn't valid, or it has no commands. */
export function parseManifest(folder: string, manifest: unknown): StoreEntry | undefined {
    if (!isValidFolder(folder) || typeof manifest !== "object" || manifest === null) return undefined;
    const object = manifest as Record<string, unknown>;
    if (!isValidName(object.name) || typeof object.title !== "string") return undefined;
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
        dir: folder,
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

/** Folders that differ only by case are one folder on APFS, so of those only the first in code-point order stays. */
export function distinctFolders(names: string[]): string[] {
    const seen = new Set<string>();
    return [...names]
        .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
        .filter((name) => {
            const key = name.toLowerCase();
            if (seen.has(key)) return false;
            seen.add(key);
            return true;
        });
}

/** Every valid entry under `<repo>/extensions/`. A folder's name is checked before it's joined into a path. */
export async function readCatalog(repo: string): Promise<StoreEntry[]> {
    const root = path.join(repo, "extensions");
    const listed = await readdir(root, { withFileTypes: true }).catch(() => []);
    const folders = distinctFolders(
        listed.filter((folder) => folder.isDirectory() && isValidFolder(folder.name)).map((folder) => folder.name),
    );
    const entries = await Promise.all(
        folders.map(async (folder) => {
            const text = await readRegularFile(path.join(root, folder, "package.json"), maxManifestBytes).catch(
                () => undefined,
            );
            if (text === undefined) return undefined;
            try {
                return parseManifest(folder, JSON.parse(text));
            } catch {
                return undefined;
            }
        }),
    );
    return entries.filter((entry): entry is StoreEntry => entry !== undefined).sort(byTitle);
}

export function byTitle(a: StoreEntry, b: StoreEntry): number {
    return (
        a.title.localeCompare(b.title, "en", { sensitivity: "base" }) ||
        a.name.localeCompare(b.name) ||
        a.dir.localeCompare(b.dir)
    );
}

/** What `installed.json` has for this row: its name's record, when that came from this row's folder. Another folder
 * whose manifest has the same name isn't installed, though its name is. */
export function installedRecord(entry: StoreEntry, installed: Installed): InstallRecord | undefined {
    const record = installed[entry.name];
    return record && sameFolder(record.dir, entry.dir) ? record : undefined;
}

/** Installed when `installed.json` has it from this folder; an update when that folder's tree id has changed since. */
export function status(entry: StoreEntry, installed: Installed, trees: Map<string, string>): Status {
    const record = installedRecord(entry, installed);
    if (!record) return "available";
    const tree = trees.get(entry.dir);
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
    if (filter === installedFilter) return entries.filter((entry) => installedRecord(entry, installed) !== undefined);
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
        installed: sorted.filter((entry) => installedRecord(entry, installed) !== undefined),
        other: sorted.filter((entry) => installedRecord(entry, installed) === undefined),
    };
}

/** What List filtering searches besides the title: the keywords, the author, the name, and the folder when it differs. */
export function searchKeywords(entry: StoreEntry): string[] {
    const folder = entry.dir === entry.name ? [] : [entry.dir];
    return [...entry.keywords, entry.author, entry.name, ...folder].filter((word) => word.length > 0);
}

export type AccessoryText = { text: string } | { tag: string };

/** The tags of a row whose extension is being installed or updated (SPEC-153 B). */
export const installingTag = "Installing…";
export const updatingTag = "Updating…";

/** The tags of a row whose install or update failed this session (SPEC-156 D.3). */
export const failedInstallTag = "Couldn't install";
export const failedUpdateTag = "Couldn't update";

/** A row's failed install or update this session (SPEC-156 D.3): whether it was an update. */
export type RowFailure = { updating: boolean };

/** The author, the number of commands, Not compatible or Partly compatible when a cached scan says so
 * (`compatibilityTag`), and Installed or Update available, or, while its name is being installed or updated (`busy`),
 * Installing… or Updating… in their place, or else Couldn't install or Couldn't update when it `failed` this session. */
export function accessoryTexts(
    entry: StoreEntry,
    state: Status,
    compatibility?: string,
    busy?: "installing" | "updating",
    failed?: RowFailure,
): AccessoryText[] {
    const accessories: AccessoryText[] = [];
    if (entry.author) accessories.push({ text: entry.author });
    accessories.push({ text: entry.commands.length === 1 ? "1 command" : `${entry.commands.length} commands` });
    if (compatibility) accessories.push({ tag: compatibility });
    if (busy) accessories.push({ tag: busy === "updating" ? updatingTag : installingTag });
    else if (failed) accessories.push({ tag: failed.updating ? failedUpdateTag : failedInstallTag });
    else if (state === "installed") accessories.push({ tag: "Installed" });
    else if (state === "update") accessories.push({ tag: "Update available" });
    return accessories;
}

/** Which of Install, Update and Uninstall a row offers: none while its name is being installed or updated (`busy`);
 * Show Details, Open in Browser, Copy Name and Refresh stay. A row that `failed` this session starts with Try Again and
 * Show Error in place of Install and Update (SPEC-156 D.3). */
export function rowActions(
    state: Status,
    busy?: "installing" | "updating",
    failed?: RowFailure,
): { install: boolean; update: boolean; uninstall: boolean; tryAgain: boolean; showError: boolean } {
    const none = { tryAgain: false, showError: false };
    if (busy) return { install: false, update: false, uninstall: false, ...none };
    if (failed) return { install: false, update: false, uninstall: state !== "available", tryAgain: true, showError: true };
    return { install: state === "available", update: state === "update", uninstall: state !== "available", ...none };
}

/** A command's title by its name, as the store's sentences name commands; the name when the manifest has none. */
export function commandTitles(entry: StoreEntry): (name: string) => string {
    return (name) => entry.commands.find((command) => command.name === name)?.title || name;
}

/** The extension's folder (`dir`) at `commit`, on github.com and as raw files. */
export function folderURL(dir: string, commit: string): string {
    return `https://github.com/raycast/extensions/tree/${commit}/extensions/${dir}`;
}

export function rawURL(dir: string, commit: string, file: string): string {
    return `https://raw.githubusercontent.com/raycast/extensions/${commit}/extensions/${dir}/${file}`;
}

export function iconURL(entry: StoreEntry, commit: string): string | undefined {
    return entry.icon ? rawURL(entry.dir, commit, `assets/${entry.icon}`) : undefined;
}
