// The store's list: one entry per extension in the repository copy, with what's installed and what can be updated.
import { readdir } from "node:fs/promises";
import path from "node:path";
import { extensionId, isValidName, raycastFolder } from "../../src/extension-id.ts";
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

/** Raycast's copy's copy id (SPEC-157 A.5): its copy is `<supportPath>/repo`. */
export const raycastCopyId = "raycast";

/** The copy a row was read from (`copyId`) and the folder of the repository it installs into (`repositoryFolder`,
 * SPEC-158's), as `readCatalog` gives them to every row of that copy. */
export type RepositoryCopy = { copyId: string; repositoryFolder: string };

export const raycastCopy: RepositoryCopy = Object.freeze({ copyId: raycastCopyId, repositoryFolder: raycastFolder });

export type StoreEntry = {
    /** The manifest's `name`, the extension's identity as in Raycast: its installed folder, and its `installed.json`
     * key, settings and data. */
    name: string;
    /** Its folder in its repository, which can differ from `name`: for the sparse pattern, the README, the scan, the
     * build's source and the URLs. It also tells apart two folders whose manifests share a name. */
    dir: string;
    /** The copy it was read from: `raycast`, or an added repository's copy id. */
    copyId: string;
    /** The folder of its repository under the extensions folder (`raycast/extensions` for Raycast's), which its install
     * goes into and its id names. */
    repositoryFolder: string;
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

/** What `installed.json` records for an extension the store installed, by its id (SPEC-157 E.1). `dir` is the folder
 * it came from, which its updates follow; `repository` is the folder of the repository it's from, only for an added
 * repository's (Raycast's records keep their bare names and have none). */
export type InstallRecord = { tree: string; commit: string; installedAt: string; dir: string; repository?: string };
export type Installed = Record<string, InstallRecord>;

export type Status = "available" | "installed" | "update";

const strings = (value: unknown): string[] =>
    Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];

/** A manifest in `copy` as an entry, or undefined when the folder or the name isn't valid, or it has no commands. */
export function parseManifest(folder: string, manifest: unknown, copy: RepositoryCopy = raycastCopy): StoreEntry | undefined {
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
        copyId: copy.copyId,
        repositoryFolder: copy.repositoryFolder,
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

/** The folders under `<repo>/extensions/` the list reads, by the folder rule and once each, as on APFS; none when there's
 * no such folder. */
export async function catalogFolders(repo: string): Promise<string[]> {
    const listed = await readdir(path.join(repo, "extensions"), { withFileTypes: true }).catch(() => []);
    return distinctFolders(
        listed.filter((folder) => folder.isDirectory() && isValidFolder(folder.name)).map((folder) => folder.name),
    );
}

/** Every valid entry under `<repo>/extensions/`, the copy `copy` names, from `folders` when they're already listed. A
 * folder's name is checked before it's joined into a path. */
export async function readCatalog(repo: string, copy: RepositoryCopy, folders?: string[]): Promise<StoreEntry[]> {
    const root = path.join(repo, "extensions");
    folders ??= await catalogFolders(repo);
    const entries = await Promise.all(
        folders.map(async (folder) => {
            const text = await readRegularFile(path.join(root, folder, "package.json"), maxManifestBytes).catch(
                () => undefined,
            );
            if (text === undefined) return undefined;
            try {
                return parseManifest(folder, JSON.parse(text), copy);
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
        a.dir.localeCompare(b.dir) ||
        a.copyId.localeCompare(b.copyId)
    );
}

/**
 * Rows from several copies by title (SPEC-177): the same title (base sensitivity) puts the rows by their repository
 * label, A to Z, compared as the titles are, whatever order the repositories have in the list; then `byTitle`'s name,
 * folder and copy id. `labelOf` gives a row's sort label by its row id (`sortLabels`).
 */
export function byTitleAndLabel(labelOf: (rowId: string) => string): (a: StoreEntry, b: StoreEntry) => number {
    return (a, b) =>
        a.title.localeCompare(b.title, "en", { sensitivity: "base" }) ||
        labelOf(rowId(a.repositoryFolder, a.dir)).localeCompare(labelOf(rowId(b.repositoryFolder, b.dir)), "en", {
            sensitivity: "base",
        }) ||
        byTitle(a, b);
}

/**
 * The id of the extension a row installs (SPEC-158 C): its name in Raycast's repository, else its repository's
 * segments and its name joined with `+`. It keys the row's record and its busy state, so the same name from two
 * repositories is two extensions. A name too long for the id rule still gets that joined text, which no record has
 * and whose build is refused.
 */
export function entryId(entry: Pick<StoreEntry, "name" | "repositoryFolder">): string {
    return (
        extensionId(entry.name, entry.repositoryFolder) ?? [...entry.repositoryFolder.split("/"), entry.name].join("+")
    );
}

/** The folder of an added repository a row is from, as records, reports and marks carry it; none for Raycast's. */
export function addedRepository(entry: Pick<StoreEntry, "repositoryFolder">): string | undefined {
    return entry.repositoryFolder === raycastFolder ? undefined : entry.repositoryFolder;
}

/** A row's list id: its repository's folder and its folder there, so the same folder in two repositories is two
 * rows. A folder has no `:`, and a development build's row id (`development:<name>`) has no `/`. */
export function rowId(repositoryFolder: string, dir: string): string {
    return `${repositoryFolder}:${dir}`;
}

/** The list id of the row a record, a report or a mark names: its folder in its added repository, or in Raycast's when
 * it names none. */
export function namedRowId(dir: string, repository: string | undefined): string {
    return rowId(repository ?? raycastFolder, dir);
}

/** What `installed.json` has for this row: its id's record, when that came from this row's folder. Another folder
 * whose manifest has the same name isn't installed, though its name is, and neither is the same name from another
 * repository, whose record is under another id. */
export function installedRecord(entry: StoreEntry, installed: Installed): InstallRecord | undefined {
    const record = installed[entryId(entry)];
    return record && sameFolder(record.dir, entry.dir) && record.repository === addedRepository(entry)
        ? record
        : undefined;
}

/** Installed when `installed.json` has it from this folder; an update when that folder's tree id has changed since.
 * `trees` is the row's own copy's. */
export function status(entry: StoreEntry, installed: Installed, trees: Map<string, string>): Status {
    const record = installedRecord(entry, installed);
    if (!record) return "available";
    const tree = trees.get(entry.dir);
    return tree !== undefined && tree !== record.tree ? "update" : "installed";
}

/** The search bar's dropdown values: "All", "Installed", one per repository that's on, then every category by name. */
export const allFilter = "all";
export const installedFilter = "installed";

/** The dropdown value of a repository's item (SPEC-157 D.3): `repository:<copyId>`. */
export function repositoryFilter(copyId: string): string {
    return `repository:${copyId}`;
}

/** The repositories the dropdown lists (D.3): every one that's on, in the list's order, and only when more than one is
 * on. */
export function filterRepositories<T>(on: readonly T[]): readonly T[] {
    return on.length > 1 ? on : [];
}

export function categories(entries: StoreEntry[]): string[] {
    return [...new Set(entries.flatMap((entry) => entry.categories))].sort((a, b) => a.localeCompare(b, "en"));
}

/** The entries `filter` shows: all, the installed ones, one repository's (`repository:<copyId>`), or one category's (a
 * category value is `category:<name>`). */
export function filterEntries(entries: StoreEntry[], filter: string, installed: Installed): StoreEntry[] {
    if (filter === installedFilter) return entries.filter((entry) => installedRecord(entry, installed) !== undefined);
    if (filter.startsWith("repository:")) {
        const copyId = filter.slice("repository:".length);
        return entries.filter((entry) => entry.copyId === copyId);
    }
    if (filter.startsWith("category:")) {
        const category = filter.slice("category:".length);
        return entries.filter((entry) => entry.categories.includes(category));
    }
    return entries;
}

/** The installed ones first, then the rest; each by title, and by repository label on the same title
 * (`byTitleAndLabel`). */
export function sections(
    entries: StoreEntry[],
    installed: Installed,
    labelOf: (rowId: string) => string,
): { installed: StoreEntry[]; other: StoreEntry[] } {
    const sorted = [...entries].sort(byTitleAndLabel(labelOf));
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

/** The row's repository's label first, only while it's labeled (`label`, SPEC-175's `rowLabels`; Raycast's rows alike),
 * the author, the number of commands, Not compatible or Partly compatible when a cached scan says so
 * (`compatibilityTag`), and Installed or Update available, or, while its name is being installed or updated (`busy`),
 * Installing… or Updating… in their place, or else Couldn't install or Couldn't update when it `failed` this
 * session. */
export function accessoryTexts(
    entry: StoreEntry,
    state: Status,
    compatibility?: string,
    busy?: "installing" | "updating",
    failed?: RowFailure,
    label?: string,
): AccessoryText[] {
    const accessories: AccessoryText[] = [];
    if (label) accessories.push({ text: label });
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

/**
 * A repository's `owner/name` on github.com, from its identity, which its links use (SPEC-157 D.4); none for a
 * repository on any other host, which gets no Open in Browser, no "Source on GitHub" link, no icon and no pictures
 * from its own folder. The identity is the rule's, so a GitHub path is already its two segments in lowercase.
 */
export function gitHubRepository(identity: string): string | undefined {
    return /^https:\/\/github\.com\/([^/]+\/[^/]+)$/.exec(identity)?.[1];
}

/** The server of a repository on another host than github.com, from its identity, which "couldn't reach" names
 * (SPEC-157 C.6); none for GitHub's. */
export function repositoryHost(identity: string): string | undefined {
    const server = identity.replace(/^https:\/\//, "").split("/")[0]!;
    return server === "github.com" ? undefined : server;
}

/** The extension's folder (`dir`) in `repository` (`owner/name` on github.com) at `commit`, on github.com and as raw
 * files. */
export function folderURL(repository: string, dir: string, commit: string): string {
    return `https://github.com/${repository}/tree/${commit}/extensions/${dir}`;
}

export function rawURL(repository: string, dir: string, commit: string, file: string): string {
    return `https://raw.githubusercontent.com/${repository}/${commit}/extensions/${dir}/${file}`;
}

/** The row's icon from its repository on github.com; none for another host, which shows the default one. */
export function iconURL(entry: StoreEntry, repository: string | undefined, commit: string): string | undefined {
    return entry.icon && repository ? rawURL(repository, entry.dir, commit, `assets/${entry.icon}`) : undefined;
}
