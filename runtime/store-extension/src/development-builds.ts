// Development builds in the Extension Store's list (SPEC-157 E.9). `fudge build` without `--repository` puts an
// extension in `fudgeapp/development` and writes no `installed.json` record, so these aren't the store's installs, and a
// row of the same name from any repository installs beside them. The app has no Uninstall of its own, so each still gets
// a row, with only Uninstall and Copy Name.

import { lstat, readdir } from "node:fs/promises";
import path from "node:path";
import { developmentFolder, isValidName } from "../../src/extension-id.ts";
import { maxManifestBytes, readRegularFile } from "./files.ts";

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

/** A development build row's list id, which no catalog row's id can be. */
export function developmentRowId(name: string): string {
    return `development:${name}`;
}

/** `<extensionsDir>/fudgeapp/development`. */
export function developmentBuildsFolder(extensionsDir: string): string {
    return path.join(extensionsDir, ...developmentFolder.split("/"));
}

/** The folder of the development build `name`, which its Uninstall moves to the Trash. */
export function developmentBuildFolder(extensionsDir: string, name: string): string {
    return path.join(developmentBuildsFolder(extensionsDir), name);
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
