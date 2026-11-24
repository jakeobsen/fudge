// When a row of the Extension Store names its repository (SPEC-175, D-177): only when another row of its list has the
// same name, or when its extension is installed and the app labels that install because another installed extension
// has the same name. Pure, so tests reach every step; a file of its own, since `not-updated.ts` and
// `development-builds.ts` import `catalog.ts`, which importing them back would make a cycle.

import { developmentFolder, extensionId, isValidExtensionId } from "../../src/extension-id.ts";
import { rowId, type StoreEntry } from "./catalog.ts";
import { developmentRowId, type DevelopmentBuild } from "./development-builds.ts";
import { notUpdatedLabel, notUpdatedRowId, type NotUpdatedInstall } from "./not-updated.ts";
import type { RepositoryEntry } from "./repository-address.ts";
import { checkShownLabel, developmentLabel, nameKey } from "./repository-name.ts";

/**
 * The app's answer to `sharedLabels()`, checked again: each id that passes the id rule with a label `checkShownLabel`
 * gives back. Any other key or value is left out, and an answer that isn't a plain object is the empty map.
 */
export function checkSharedLabelsAnswer(value: unknown): ReadonlyMap<string, string> {
    const labels = new Map<string, string>();
    if (typeof value !== "object" || value === null || Array.isArray(value)) return labels;
    for (const [id, answered] of Object.entries(value)) {
        const label = checkShownLabel(answered);
        if (isValidExtensionId(id) && label !== undefined) labels.set(id, label);
    }
    return labels;
}

/** What `rowLabels` reads: every row under All, the list of repositories, and the app's checked answer
 * (`checkSharedLabelsAnswer`). */
export type RowLabelSources = {
    entries: readonly StoreEntry[];
    development: readonly DevelopmentBuild[];
    notUpdated: readonly NotUpdatedInstall[];
    listed: readonly RepositoryEntry[];
    shared: ReadonlyMap<string, string>;
};

type LabelRow = { rowId: string; title: string; label: string; id: string | undefined };

/**
 * Each labeled row's label, by its row id, whatever the filter and the search show. A row whose extension's id is in
 * `shared` gets the app's label, so it reads as its install does in search (the installed half); else a row whose name
 * another row has gets its own label (the list half); else none. A row's own label is its listed repository's `label`,
 * `development` for a development build, and a Not updated row's `notUpdatedLabel`.
 */
export function rowLabels(sources: RowLabelSources): Map<string, string> {
    const rows: LabelRow[] = [
        ...sources.entries.map((entry) => ({
            rowId: rowId(entry.repositoryFolder, entry.dir),
            title: entry.title,
            label: sources.listed.find((listed) => listed.copyId === entry.copyId)?.label ?? entry.repositoryFolder,
            id: extensionId(entry.name, entry.repositoryFolder),
        })),
        ...sources.development.map((build) => ({
            rowId: developmentRowId(build.name),
            title: build.title,
            label: developmentLabel,
            id: extensionId(build.name, developmentFolder),
        })),
        ...sources.notUpdated.map((install) => ({
            rowId: notUpdatedRowId(install.id),
            title: install.title,
            label: notUpdatedLabel(install.repository, sources.listed),
            id: install.id,
        })),
    ];
    const groups = new Map<string, number>();
    const keys = rows.map((row) => nameKey(row.title));
    for (const key of keys) groups.set(key, (groups.get(key) ?? 0) + 1);
    const labels = new Map<string, string>();
    rows.forEach((row, index) => {
        const shared = row.id === undefined ? undefined : sources.shared.get(row.id);
        if (shared !== undefined) labels.set(row.rowId, shared);
        else if (groups.get(keys[index]!)! > 1) labels.set(row.rowId, row.label);
    });
    return labels;
}
