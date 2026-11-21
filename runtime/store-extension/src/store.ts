// Installing, updating and uninstalling. Everything that touches the system comes in through `StoreContext`, so the
// tests fake git, the fudge CLI, the confirmation and the Trash.
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { isValidName, type Installed, type InstallRecord, type StoreEntry } from "./catalog.ts";
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

/** What the install confirmation needs from `fudge scan <folder> --json`. */
export type ScanReport = { supported: boolean; gaps: { api: string }[]; unreadable: string[] };

/** The install confirmation's line about what works: from the scan, or saying the scan couldn't run. */
export function compatibilityLine(report: ScanReport | undefined): string {
    if (!report) return "Fudge couldn't check what this extension uses.";
    if (report.supported) return "Fudge supports everything this extension uses.";
    const names = [...new Set(report.gaps.map((gap) => gap.api))];
    if (names.length === 0) return "Fudge couldn't read all of this extension's source, so some of it may not work.";
    const more = names.length > 5 ? `, and ${names.length - 5} more` : "";
    return `This extension uses things Fudge doesn't have yet: ${names.slice(0, 5).join(", ")}${more}. Some of its commands may not work.`;
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

/** `installed.json`, without entries whose name or record isn't valid. Missing or broken reads as empty. */
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
        const { tree, commit, installedAt } = record as Record<string, unknown>;
        if (typeof tree === "string" && typeof commit === "string" && typeof installedAt === "string") {
            installed[name] = { tree, commit, installedAt };
        }
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

const exists = (target: string) =>
    stat(target).then(
        () => true,
        () => false,
    );

/**
 * Installs (or updates) `entry`: fetches its source, checks where its packages come from, scans what it uses
 * (`fudge scan`), asks, builds it with the CLI into `extensionsDir`, and records it. Resolves false when the user cancels; throws `StoreError` when a step
 * refuses or fails. A folder of that name that the store didn't install is never replaced.
 */
export async function install(entry: StoreEntry, context: StoreContext): Promise<boolean> {
    const name = checkedName(entry.name);
    const installed = await readInstalled(context.supportPath);
    if (!installed[name] && (await exists(path.join(context.extensionsDir, name)))) {
        throw new StoreError(`An extension named ${name} is already installed (not from the store)`);
    }
    await context.repo.add(`/extensions/${name}/`);
    const source = path.join(context.repo.path, "extensions", name);
    const problem = await sourceProblem(source);
    if (problem) throw new StoreError(`${entry.title} can't be installed. ${problem}.`);

    const compatibility = compatibilityLine(await scanExtension(source, context));
    const commit = await context.repo.commit();
    const confirmed = await context.confirm(
        `${installed[name] ? "Update" : "Install"} ${entry.title}?`,
        `From github.com/raycast/extensions at ${commit.slice(0, 7)}. It runs its own code on your Mac, like any app you install.\n\n${compatibility}`,
        installed[name] ? "Update" : "Install",
    );
    if (!confirmed) return false;

    const run = context.run ?? spawnProgram;
    const result = await run(context.cli, buildArguments(source, context.extensionsDir), { timeout: buildTimeout });
    if (result.code !== 0) {
        throw new StoreError((result.stderr.trim() || result.stdout.trim() || "fudge build failed").slice(-500));
    }
    const tree = (await context.repo.trees()).get(name);
    if (!tree) throw new StoreError(`Couldn't read ${name}'s version in the store's copy`);
    const record: InstallRecord = { tree, commit, installedAt: (context.now?.() ?? new Date()).toISOString() };
    await writeInstalled(context.supportPath, { ...(await readInstalled(context.supportPath)), [name]: record });
    return true;
}

/**
 * Moves an extension the store installed to the Trash, after asking, and forgets it. Names not in `installed.json`
 * are refused: the store never touches extensions installed another way.
 */
export async function uninstall(entry: StoreEntry, context: StoreContext): Promise<boolean> {
    const name = checkedName(entry.name);
    const installed = await readInstalled(context.supportPath);
    if (!installed[name]) throw new StoreError(`${entry.title} wasn't installed by the store`);
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
