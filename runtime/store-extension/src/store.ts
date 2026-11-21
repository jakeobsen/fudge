// Installing, updating and uninstalling. Everything that touches the system comes in through `StoreContext`, so the
// tests fake git, the fudge CLI, the confirmation and the Trash.
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { isValidFolder, isValidName, sameFolder, type Installed, type InstallRecord, type StoreEntry } from "./catalog.ts";
import { maxManifestBytes, readRegularFile } from "./files.ts";
import { spawnProgram, type Run, type StoreRepository } from "./git.ts";
import { sourceProblem } from "./sources.ts";
import { buildTimeout, scanTimeout } from "./timeouts.ts";

/** A step that refused or failed; its message is shown in a failure toast. */
export class StoreError extends Error {}

export type StoreContext = {
    repo: StoreRepository;
    supportPath: string;
    /** `FUDGE_CLI`: the app's `fudge` tool. */
    cli: string;
    /** `FUDGE_EXTENSIONS_DIR`: where fudge's extensions are installed. */
    extensionsDir: string;
    /** Asks the user; `confirmAlert` in the store. */
    confirm: (title: string, message: string, primary: string) => Promise<boolean>;
    /** Moves a path to the Trash; `trash` in the store. */
    trash: (target: string) => Promise<void>;
    run?: Run;
    now?: () => Date;
};

/** What the install confirmation needs from `fudge scan <folder> --json`. `byDesign` names the category of an API
 * Fudge leaves out on purpose (AI, Browser Extension, OAuth). */
export type ScanReport = { supported: boolean; gaps: { api: string; byDesign?: string }[]; unreadable: string[] };

/** "AI", "AI and OAuth", "AI, Browser Extension and OAuth". */
function listed(names: string[]): string {
    return names.length <= 1 ? (names[0] ?? "") : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

/**
 * The install confirmation's line about what works: from the scan, or saying the scan couldn't run. APIs Fudge
 * leaves out on purpose are named apart, by category, so one never reads as something Fudge doesn't have yet.
 */
export function compatibilityLine(report: ScanReport | undefined): string {
    if (!report) return "Fudge couldn't check what this extension uses.";
    if (report.supported) return "Fudge supports everything this extension uses.";
    const designed = (gap: { byDesign?: unknown }) => typeof gap.byDesign === "string" && gap.byDesign !== "";
    const missing = [...new Set(report.gaps.filter((gap) => !designed(gap)).map((gap) => gap.api))];
    const leftOut = [...new Set(report.gaps.filter(designed).map((gap) => gap.byDesign!))];
    const sentences: string[] = [];
    if (missing.length > 0) {
        const more = missing.length > 5 ? `, and ${missing.length - 5} more` : "";
        sentences.push(`This extension uses things Fudge doesn't have yet: ${missing.slice(0, 5).join(", ")}${more}.`);
    }
    if (leftOut.length > 0) {
        const subject = missing.length > 0 ? "It also uses" : "This extension uses";
        sentences.push(`${subject} ${listed(leftOut)}, which Fudge leaves out.`);
    }
    if (sentences.length === 0) return "Fudge couldn't read all of this extension's source, so some of it may not work.";
    return `${sentences.join(" ")} Some of its commands may not work.`;
}

/** Runs `$FUDGE_CLI scan <source> --json`. Undefined when it fails or says something unexpected. */
export async function scanExtension(source: string, context: StoreContext): Promise<ScanReport | undefined> {
    const run = context.run ?? spawnProgram;
    try {
        const result = await run(context.cli, ["scan", source, "--json"], { timeout: scanTimeout });
        if (result.code !== 0) return undefined;
        const report = JSON.parse(result.stdout) as Partial<ScanReport>;
        if (typeof report.supported !== "boolean" || !Array.isArray(report.gaps) || !Array.isArray(report.unreadable)) {
            return undefined;
        }
        return report as ScanReport;
    } catch {
        return undefined;
    }
}

/** Where the store keeps what it installed. It survives turning the store off, unlike `repo/`. */
export function installedFile(supportPath: string): string {
    return path.join(supportPath, "installed.json");
}

/**
 * `installed.json`, without entries whose name or record isn't valid. Missing or broken reads as empty. An entry
 * without a folder, written before the store knew folders from names, came from the folder of its name.
 */
export async function readInstalled(supportPath: string): Promise<Installed> {
    const text = await readFile(installedFile(supportPath), "utf8").catch(() => "{}");
    let object: unknown;
    try {
        object = JSON.parse(text);
    } catch {
        return {};
    }
    if (typeof object !== "object" || object === null) return {};
    const installed: Installed = {};
    for (const [name, record] of Object.entries(object)) {
        if (!isValidName(name) || typeof record !== "object" || record === null) continue;
        const { tree, commit, installedAt, dir } = record as Record<string, unknown>;
        if (typeof tree !== "string" || typeof commit !== "string" || typeof installedAt !== "string") continue;
        if (dir !== undefined && !isValidFolder(dir)) continue;
        installed[name] = { tree, commit, installedAt, dir: dir ?? name };
    }
    return installed;
}

/** Writes `installed.json` atomically. */
export async function writeInstalled(supportPath: string, installed: Installed): Promise<void> {
    await mkdir(supportPath, { recursive: true });
    const file = installedFile(supportPath);
    const temporary = `${file}.${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify(installed, null, 2)}\n`);
    await rename(temporary, file);
}

/** The CLI's arguments for installing the extension in `source` into `extensionsDir`, and nowhere else. */
export function buildArguments(source: string, extensionsDir: string): string[] {
    return ["build", source, "--into", extensionsDir];
}

function checkedName(name: string): string {
    if (!isValidName(name)) throw new StoreError(`"${name}" isn't a valid extension name`);
    return name;
}

function checkedFolder(dir: string): string {
    if (!isValidFolder(dir)) throw new StoreError(`"${dir}" isn't a valid folder in the store`);
    return dir;
}

/** The extensions Fudge bundles (`BundledExtensions` in the app, `BUNDLED_EXTENSIONS` in the Makefile, which a test
 * pins this to). One installed under the same name would stay hidden behind it, so the store never installs one. */
export const bundledNames = ["fudge-extension-store", "fudge-file-search", "fudge-emoji", "fudge-clipboard-history"];

/** Refused: an install under a name another extension has, from another folder of the store or not from the store. */
export function nameTakenMessage(name: string): string {
    return `Another extension called ${name} is installed. Uninstall it first.`;
}

const exists = (target: string) =>
    stat(target).then(
        () => true,
        () => false,
    );

/**
 * Installs (or updates) `entry`: fetches its source from its folder, checks where its packages come from, scans what
 * it uses (`fudge scan`), asks, builds it with the CLI into `extensionsDir` (as `<extensionsDir>/<name>`), and records
 * it under its name with its folder. Resolves false when the user cancels; throws `StoreError` when a step refuses or
 * fails. An extension of that name that the store didn't install from this folder is never replaced: one installed
 * another way, one from another folder whose manifest has the same name, or one Fudge bundles.
 */
export async function install(entry: StoreEntry, context: StoreContext): Promise<boolean> {
    const name = checkedName(entry.name);
    const dir = checkedFolder(entry.dir);
    if (bundledNames.includes(name)) throw new StoreError(`${entry.title} can't be installed: ${name} is part of Fudge.`);
    const installed = await readInstalled(context.supportPath);
    const record = installed[name];
    if (record ? !sameFolder(record.dir, dir) : await exists(path.join(context.extensionsDir, name))) {
        throw new StoreError(nameTakenMessage(name));
    }
    await context.repo.add(`/extensions/${dir}/`);
    const source = path.join(context.repo.path, "extensions", dir);
    // The build installs under the name in this manifest, so it must still be the one the list showed.
    const current = await readRegularFile(path.join(source, "package.json"), maxManifestBytes)
        .then((text) => (JSON.parse(text) as { name?: unknown }).name)
        .catch(() => undefined);
    if (current !== name) throw new StoreError(`${entry.title} has changed in the store's copy. Refresh the list and try again.`);
    const problem = await sourceProblem(source);
    if (problem) throw new StoreError(`${entry.title} can't be installed. ${problem}.`);

    const compatibility = compatibilityLine(await scanExtension(source, context));
    const commit = await context.repo.commit();
    const confirmed = await context.confirm(
        `${record ? "Update" : "Install"} ${entry.title}?`,
        `From github.com/raycast/extensions at ${commit.slice(0, 7)}. It runs its own code on your Mac, like any app you install.\n\n${compatibility}`,
        record ? "Update" : "Install",
    );
    if (!confirmed) return false;

    const run = context.run ?? spawnProgram;
    const result = await run(context.cli, buildArguments(source, context.extensionsDir), { timeout: buildTimeout });
    if (result.code !== 0) {
        throw new StoreError((result.stderr.trim() || result.stdout.trim() || "fudge build failed").slice(-500));
    }
    const tree = (await context.repo.trees()).get(dir);
    if (!tree) throw new StoreError(`Couldn't read ${name}'s version in the store's copy`);
    const recorded: InstallRecord = { tree, commit, installedAt: (context.now?.() ?? new Date()).toISOString(), dir };
    await writeInstalled(context.supportPath, { ...(await readInstalled(context.supportPath)), [name]: recorded });
    return true;
}

/**
 * Moves an extension the store installed to the Trash, after asking, and forgets it. Anything not in `installed.json`
 * from this row's folder is refused: the store never touches extensions installed another way, nor one another
 * folder with the same name installed.
 */
export async function uninstall(entry: StoreEntry, context: StoreContext): Promise<boolean> {
    const name = checkedName(entry.name);
    const installed = await readInstalled(context.supportPath);
    const record = installed[name];
    if (!record || !sameFolder(record.dir, entry.dir)) throw new StoreError(`${entry.title} wasn't installed by the store`);
    const confirmed = await context.confirm(
        `Uninstall ${entry.title}?`,
        "It's moved to the Trash. Its settings and data stay.",
        "Uninstall",
    );
    if (!confirmed) return false;
    const folder = path.join(context.extensionsDir, name);
    if (await exists(folder)) await context.trash(folder);
    const remaining = await readInstalled(context.supportPath);
    delete remaining[name];
    await writeInstalled(context.supportPath, remaining);
    return true;
}

/** One install at a time: each call waits for the one before it. */
let queue: Promise<unknown> = Promise.resolve();
export function oneAtATime<T>(work: () => Promise<T>): Promise<T> {
    const next = queue.then(work, work);
    queue = next.catch(() => undefined);
    return next;
}
