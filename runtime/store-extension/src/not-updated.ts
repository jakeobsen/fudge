// Installs from a repository that isn't on (SPEC-157 E.8): Raycast's switched off, or an added one switched off or
// removed. Their extensions stay installed and get no updates, and since the app has no Uninstall of its own, each
// still gets a row in the Extension Store, built from the install's own `package.json`, with only Uninstall and Copy
// Name.

import { lstat } from "node:fs/promises";
import { extensionId, raycastFolder } from "../../src/extension-id.ts";
import { allFilter, installedFilter, type Installed } from "./catalog.ts";
import { installedManifest } from "./development-builds.ts";
import { installFolder, readInstalled, StoreError, writeInstalled, type StoreContext } from "./store.ts";

/** An install whose repository isn't on, as its row shows it. */
export type NotUpdatedInstall = {
    /** Its `installed.json` key, the extension's id: the row's id and what Uninstall forgets. */
    id: string;
    /** The extension's name, which Copy Name copies. */
    name: string;
    /** The folder of the repository it's from (`raycast/extensions` for Raycast's). */
    repository: string;
    /** From its own `package.json`, else its name. */
    title: string;
    description: string;
};

/** The row's accessory text. */
export const notUpdatedAccessory = "Not updated";

/** Such a row's list id, which no catalog row's (`<folder>:<dir>`, and a folder holds a `/`) or development build's can be. */
export function notUpdatedRowId(id: string): string {
    return `installed:${id}`;
}

/** These rows show under All and Installed: their repository isn't on, so it has no item in the filter. */
export function notUpdatedRowsShown(filter: string): boolean {
    return filter === allFilter || filter === installedFilter;
}

/** The detail pane of such a row: what it is, since its repository isn't read. */
export function notUpdatedDetailMarkdown(install: NotUpdatedInstall): string {
    return [`# ${install.title}`, install.description, "Its repository is off or was removed, so it isn't updated."]
        .filter(Boolean)
        .join("\n\n");
}

/**
 * Every `installed.json` record whose repository isn't among `on`, the folders of the repositories that are on, by
 * title: its title and description from the install's own `package.json` (read with the list's size limit, never
 * through a link), or its name as the title when that can't be read or names another extension.
 */
export async function readNotUpdated(
    installed: Installed,
    on: ReadonlySet<string>,
    extensionsDir: string,
): Promise<NotUpdatedInstall[]> {
    const off = Object.entries(installed).filter(([, record]) => !on.has(record.repository ?? raycastFolder));
    const rows = await Promise.all(
        off.map(async ([id, record]): Promise<NotUpdatedInstall> => {
            const name = id.split("+").at(-1)!;
            const repository = record.repository ?? raycastFolder;
            const manifest = await installedManifest(installFolder(extensionsDir, repository, name), name);
            return { id, name, repository, title: manifest?.title ?? name, description: manifest?.description ?? "" };
        }),
    );
    return rows.sort(
        (a, b) => a.title.localeCompare(b.title, "en", { sensitivity: "base" }) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
    );
}

/** What Uninstall on such a row needs from the store. */
export type NotUpdatedUninstallContext = Pick<StoreContext, "supportPath" | "extensionsDir" | "confirm" | "trash">;

/**
 * Uninstall on such a row: asks as any Uninstall does, moves `<extensionsDir>/<repository>/<name>` to the Trash and
 * forgets that record alone, leaving every other install of that name as it is. Refused when `installed.json` no longer
 * holds that id from that repository; false when the user cancels.
 */
export async function uninstallNotUpdated(install: NotUpdatedInstall, context: NotUpdatedUninstallContext): Promise<boolean> {
    const refused = new StoreError(`${install.title} wasn't installed by the Extension Store`);
    // The id names the repository's folder and the name, as its record's key does, so the record is this install's.
    if (extensionId(install.name, install.repository) !== install.id) throw refused;
    if (!(await readInstalled(context.supportPath))[install.id]) throw refused;
    const confirmed = await context.confirm(
        `Uninstall ${install.title}?`,
        "It's moved to the Trash. Its settings and data stay.",
        "Uninstall",
    );
    if (!confirmed) return false;
    const folder = installFolder(context.extensionsDir, install.repository, install.name);
    if (await lstat(folder).then(() => true, () => false)) await context.trash(folder);
    const remaining = await readInstalled(context.supportPath);
    delete remaining[install.id];
    await writeInstalled(context.supportPath, remaining);
    return true;
}
