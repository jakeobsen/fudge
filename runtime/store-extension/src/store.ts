// Installing, updating and uninstalling. Everything that touches the system comes in through `StoreContext`, so the
// tests fake git, the fudge CLI, the confirmation and the Trash.
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import {
    commandTitles,
    isValidFolder,
    isValidName,
    sameFolder,
    type Installed,
    type InstallRecord,
    type StoreEntry,
} from "./catalog.ts";
import {
    builtCompatibility,
    compatibilityLine,
    fromReport,
    installNote,
    readCompatibility,
    rememberCompatibility,
    scanExtension,
    scannerIdentity,
    type Compatibility,
} from "./compatibility.ts";
import type { FailureDetails } from "./failure.ts";
import { maxManifestBytes, readRegularFile } from "./files.ts";
import { GitError, spawnProgram, type Run, type StoreRepository } from "./git.ts";
import { sourceProblem } from "./sources.ts";
import { buildTimeout } from "./timeouts.ts";

/** A step that refused or failed; its message is shown in a failure toast. */
export class StoreError extends Error {}

/** `fudge build` failed: its whole output, stdout then stderr, the command and the exit code, for the failure view. */
export class BuildFailed extends StoreError {
    readonly output: string;
    readonly command: string;
    readonly code: number;
    constructor(output: string, command: string, code: number) {
        super((output.trim() || "fudge build failed").slice(-500));
        this.output = output;
        this.command = command;
        this.code = code;
    }
}

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
 * What this version of the folder uses: the cached result when this scanner has one (`compatibility.json`), else a
 * scan of `source`, which is cached for the list and the detail. Undefined when the scan couldn't run.
 */
async function compatibilityOf(
    source: string,
    tree: string | undefined,
    context: StoreContext,
): Promise<Compatibility | undefined> {
    const scanner = await scannerIdentity(context.cli);
    const cached = tree ? (await readCompatibility(context.supportPath, scanner)).get(tree) : undefined;
    if (cached && !cached.notChecked) return cached;
    const report = await scanExtension(source, context);
    if (!report) return undefined;
    const result = fromReport(report);
    // The cache only saves a later scan, so failing to write it doesn't stop the install.
    if (tree) await rememberCompatibility(context.supportPath, scanner, tree, result).catch(() => undefined);
    return result;
}

/**
 * Installs (or updates) `entry`: fetches its source from its folder, checks where its packages come from, finds what
 * it uses (`fudge scan`, or the cached result for this version), asks, builds it with the CLI into `extensionsDir` (as
 * `<extensionsDir>/<name>`), and records it under its name with its folder. Resolves false when the user cancels, else
 * with what the done message adds (`installNote`); throws `StoreError` when a step refuses or fails. An extension of that name that the store didn't install from this
 * folder is never replaced: one installed another way, one from another folder whose manifest has the same name, or one
 * Fudge bundles.
 */
export async function install(entry: StoreEntry, context: StoreContext): Promise<InstallDone | false> {
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

    const tree = (await context.repo.trees()).get(dir);
    const checked = await compatibilityOf(source, tree, context);
    const compatibility = compatibilityLine(checked, commandTitles(entry));
    const commit = await context.repo.commit();
    const confirmed = await context.confirm(
        `${record ? "Update" : "Install"} ${entry.title}?`,
        `From github.com/raycast/extensions at ${commit.slice(0, 7)}. It runs its own code on your Mac, like any app you install.\n\n${compatibility}`,
        record ? "Update" : "Install",
    );
    if (!confirmed) return false;

    const run = context.run ?? spawnProgram;
    const args = buildArguments(source, context.extensionsDir);
    const result = await run(context.cli, args, { timeout: buildTimeout });
    if (result.code !== 0) {
        const output = [result.stdout, result.stderr].filter((part) => part.trim().length > 0).join("\n");
        throw new BuildFailed(output, ["fudge", ...args].join(" "), result.code);
    }
    if (!tree) throw new StoreError(`Couldn't read ${name}'s version in the store's copy`);
    const recorded: InstallRecord = { tree, commit, installedAt: (context.now?.() ?? new Date()).toISOString(), dir };
    await writeInstalled(context.supportPath, { ...(await readInstalled(context.supportPath)), [name]: recorded });
    // The build scanned the source again: what it turned off is what's true, so say so where it differs.
    const built = await builtCompatibility(
        path.join(context.extensionsDir, name),
        entry.commands.map((command) => command.name),
    );
    const note = installNote(checked, built, commandTitles(entry));
    return note ? { note } : {};
}

/** A finished install. `note` says which commands are on and off when that isn't what the confirmation said. */
export interface InstallDone {
    note?: string;
}

/**
 * The Success toast a finished install or update leaves, with the install's note as its message when there is one
 * (SPEC-130). It's a toast and never the HUD, so the launcher stays open on the store's list. Always `Success`, which
 * the view sets: this module doesn't import `@raycast/api`.
 */
export function doneToast(title: string, updating: boolean, done: InstallDone): { title: string; message?: string } {
    const shown = `${updating ? "Updated" : "Installed"} ${title}`;
    return done.note ? { title: shown, message: done.note } : { title: shown };
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

/**
 * What the failure view needs from a failed install: `fudge build`'s whole output with its command and exit, git's
 * stderr with its command, or one of the store's own refusals, whose message is the store's own words.
 */
/** `Fudge.log`'s lines for a step that failed: what failed, the command and its exit code, then its output. */
export function failureLog(title: string, details: FailureDetails): string {
    const command = details.command && `${details.command}${details.code === undefined ? "" : ` (exit code ${details.code})`}`;
    return [title, command, details.output.trimEnd()].filter((part) => part).join("\n");
}

export function failureDetails(error: unknown): FailureDetails {
    if (error instanceof BuildFailed) return { output: error.output, command: error.command, code: error.code };
    if (error instanceof GitError) return { output: error.message, command: error.command };
    if (error instanceof StoreError) return { output: error.message, refused: true };
    return { output: error instanceof Error ? error.message : String(error) };
}

/** One install at a time: each call waits for the one before it. */
let queue: Promise<unknown> = Promise.resolve();
export function oneAtATime<T>(work: () => Promise<T>): Promise<T> {
    const next = queue.then(work, work);
    queue = next.catch(() => undefined);
    return next;
}
