// Development builds in the Extension Store's list (SPEC-157 E.9). `fudge build` without `--repository` puts an
// extension in `fudgeapp/development` and writes no `installed.json` record, so these aren't the store's installs, and a
// row of the same name from any repository installs beside them. The app has no Uninstall of its own, so each still gets
// a row, with only Uninstall and Copy Name.

import { lstat, readdir } from "node:fs/promises";
import path from "node:path";
import { developmentFolder, isValidName } from "../../src/extension-id.ts";
import { allFilter, installedFilter, rowId, type StoreEntry } from "./catalog.ts";
import { maxManifestBytes, readRegularFile } from "./files.ts";
import { notUpdatedRowId, type NotUpdatedInstall } from "./not-updated.ts";
import { installFolder } from "./store.ts";

/** A development build as its row shows it. */
export type DevelopmentBuild = {
    /** Its folder's name in `fudgeapp/development`: the row's id, what Uninstall moves and what Copy Name copies. */
    name: string;
    /** From its own `package.json`, else its folder's name. */
    title: string;
    description: string;
};

/** The row's accessory text. */
export const developmentBuildAccessory = "Development build";

/** The row's accessories: its label first while it's labeled (`development`, SPEC-175), then "Development build". */
export function developmentAccessories(label?: string): { text: string }[] {
    return [...(label ? [{ text: label }] : []), { text: developmentBuildAccessory }];
}

/** A development build row's list id, which no catalog row's id can be. */
export function developmentRowId(name: string): string {
    return `development:${name}`;
}

/** Development builds show under All and Installed, and under no category or repository. */
export function developmentRowsShown(filter: string): boolean {
    return filter === allFilter || filter === installedFilter;
}

/**
 * Whether the rows built from an install alone (development builds, and installs whose repository isn't on) show yet:
 * with the first rows read from a copy (`copyRows`), or once no open or ⌘R is reading copies (`reading`). The installs
 * are read before any copy, so shown earlier, one of them would be the list's first row, and selected, until the first
 * copy's rows came.
 */
export function installOnlyRowsReady(copyRows: number, reading: number): boolean {
    return copyRows > 0 || reading === 0;
}

/** A row of the Installed section (SPEC-166): an install of the store's, a development build, or an install whose
 * repository isn't on. */
export type InstalledSectionRow =
    | { kind: "entry"; entry: StoreEntry }
    | { kind: "development"; build: DevelopmentBuild }
    | { kind: "notUpdated"; install: NotUpdatedInstall };

const kindOrder: Readonly<Record<InstalledSectionRow["kind"], number>> = { entry: 0, development: 1, notUpdated: 2 };

const sectionTitle = (row: InstalledSectionRow) =>
    row.kind === "entry" ? row.entry.title : row.kind === "development" ? row.build.title : row.install.title;

/**
 * The Installed section in order (SPEC-166): by title, and on the same title (base sensitivity) the store's installs
 * first, which come in the copies' order (`byTitleIn`), then the development builds, then the installs whose repository
 * isn't on. Each kind keeps the order it's given.
 */
export function installedSection(
    entries: readonly StoreEntry[],
    development: readonly DevelopmentBuild[],
    notUpdated: readonly NotUpdatedInstall[],
): InstalledSectionRow[] {
    const rows: InstalledSectionRow[] = [
        ...entries.map((entry) => ({ kind: "entry" as const, entry })),
        ...development.map((build) => ({ kind: "development" as const, build })),
        ...notUpdated.map((install) => ({ kind: "notUpdated" as const, install })),
    ];
    return rows.sort(
        (a, b) =>
            sectionTitle(a).localeCompare(sectionTitle(b), "en", { sensitivity: "base" }) || kindOrder[a.kind] - kindOrder[b.kind],
    );
}

/** An Installed row's list id (SPEC-166), as its node has it. */
export function installedSectionRowId(row: InstalledSectionRow): string {
    if (row.kind === "entry") return rowId(row.entry.repositoryFolder, row.entry.dir);
    return row.kind === "development" ? developmentRowId(row.build.name) : notUpdatedRowId(row.install.id);
}

/**
 * The actions of a row built from an install alone, in order: Copy Name first, so ↵ never uninstalls, as on every other
 * row; Uninstall after it, on ⌃X, asking first.
 */
export const installOnlyRowActions: readonly ("copyName" | "uninstall")[] = Object.freeze(["copyName", "uninstall"]);

/** The detail pane of a development build's row: what it is and where, since it has no README or commands here. */
export function developmentDetailMarkdown(build: DevelopmentBuild): string {
    // The folder passed the name rule, so it holds nothing markdown reads; the code span keeps `_` literal.
    return [`# ${build.title}`, build.description, `A development build, in the development folder as \`${build.name}\`.`]
        .filter(Boolean)
        .join("\n\n");
}

/** `<extensionsDir>/fudgeapp/development`. */
export function developmentBuildsFolder(extensionsDir: string): string {
    return path.join(extensionsDir, ...developmentFolder.split("/"));
}

/** The folder of the development build `name`, which its Uninstall moves to the Trash: `installFolder` in the
 * development folder (SPEC-157 E.9). */
export function developmentBuildFolder(extensionsDir: string, name: string): string {
    return installFolder(extensionsDir, developmentFolder, name);
}

/**
 * The title and description an install's own `package.json` gives, read with the list's size limit and never through
 * a link; undefined when it can't be read, or it names another extension than `name`.
 */
export async function installedManifest(folder: string, name: string): Promise<{ title: string; description: string } | undefined> {
    const text = await readRegularFile(path.join(folder, "package.json"), maxManifestBytes).catch(() => undefined);
    if (text === undefined) return undefined;
    try {
        const manifest = JSON.parse(text) as unknown;
        if (typeof manifest !== "object" || manifest === null) return undefined;
        const { name: named, title, description } = manifest as Record<string, unknown>;
        if (named !== name || typeof title !== "string") return undefined;
        return { title, description: typeof description === "string" ? description : "" };
    } catch {
        return undefined;
    }
}

/** Whether `target` is a folder itself, not a link to one. */
const isRealFolder = (target: string) =>
    lstat(target).then(
        (info) => info.isDirectory(),
        () => false,
    );

/**
 * Every development build, by its folder in `fudgeapp/development`, as SPEC-158's walk finds them: entries starting
 * with `.` and links are skipped, and nothing is followed. A folder whose name isn't a valid extension name gets no
 * row; one whose `package.json` can't be read, or names another extension, gets its folder's name as the title. A
 * bundled extension's name gets a row too: that build never loads, and this row is how it's removed.
 */
export async function readDevelopmentBuilds(extensionsDir: string): Promise<DevelopmentBuild[]> {
    const parent = path.dirname(developmentBuildsFolder(extensionsDir));
    const folder = developmentBuildsFolder(extensionsDir);
    if (!(await isRealFolder(parent)) || !(await isRealFolder(folder))) return [];
    const listed = await readdir(folder, { withFileTypes: true }).catch(() => []);
    const names = listed
        .filter((entry) => !entry.name.startsWith(".") && entry.isDirectory() && isValidName(entry.name))
        .map((entry) => entry.name);
    const builds = await Promise.all(
        names.map(async (name): Promise<DevelopmentBuild> => {
            const manifest = await installedManifest(path.join(folder, name), name);
            return { name, title: manifest?.title ?? name, description: manifest?.description ?? "" };
        }),
    );
    return builds.sort(
        (a, b) => a.title.localeCompare(b.title, "en", { sensitivity: "base" }) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0),
    );
}

/** What Uninstall on a development build's row needs from the store. */
export type DevelopmentUninstallContext = {
    extensionsDir: string;
    confirm: (title: string, message: string, primary: string) => Promise<boolean>;
    trash: (target: string) => Promise<void>;
};

/**
 * Uninstall on a development build's row: asks as any Uninstall does, then moves `fudgeapp/development/<name>` to the
 * Trash. It reads and writes no `installed.json` record, since the store didn't install it, and it leaves every other
 * install of that name as it is. False when the user cancels.
 */
export async function uninstallDevelopmentBuild(build: DevelopmentBuild, context: DevelopmentUninstallContext): Promise<boolean> {
    if (!isValidName(build.name)) return false;
    const confirmed = await context.confirm(
        `Uninstall ${build.title}?`,
        "It's moved to the Trash. Its settings and data stay.",
        "Uninstall",
    );
    if (!confirmed) return false;
    const folder = developmentBuildFolder(context.extensionsDir, build.name);
    if (await lstat(folder).then(() => true, () => false)) await context.trash(folder);
    return true;
}
