// Installing, updating and uninstalling. Everything that touches the system comes in through `StoreContext`, so the
// tests fake git, the fudge CLI, the confirmation and the Trash.
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { isValidExtensionId } from "../../src/extension-id.ts";
import {
    addedRepository,
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
import {
    buildRecordFiles,
    installingFolder,
    ownBuilds,
    recordBuild,
    type BuildAbout,
    type BuildId,
    type BuildRecordFiles,
} from "./build-records.ts";
import { GitError, spawnProgram, type GitResult, type Run, type StoreRepository } from "./git.ts";
import type { RepositoryEntry } from "./repository-address.ts";
import {
    removeSavedFailure,
    reportEnd,
    saveFailure,
    unanswered,
    type FailureMark,
    type InstallAnswer,
    type InstallEndReport,
} from "./notices.ts";
import { raycastFolder } from "./repository-folder.ts";
import { sourceProblem } from "./sources.ts";
import {
    askedForSwiftParts,
    decideSwiftParts,
    installedWithoutSwift,
    type SwiftParts,
    type SwiftPartsChoice,
} from "./swift-parts.ts";
import { buildTimeout, swiftBuildTimeout } from "./timeouts.ts";

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

/** `fudge build`'s exit status when another build of the same extension into the same folder is running
 * (`BuildError.alreadyBuildingStatus`); `runtime/test/fixtures/build-statuses.json` pins both. */
export const alreadyBuildingStatus = 75;

/** `fudge build` stopped at once because another build of this extension is running: started from Terminal, or by a
 * store that couldn't see it. Neither a failure nor an install (SPEC-153 C.6). */
export class AlreadyBuilding extends Error {
    constructor(title: string) {
        super(alreadyBuildingTitle(title));
    }
}

/** The toast for `AlreadyBuilding`. */
export function alreadyBuildingTitle(title: string): string {
    return `${title} is already being installed`;
}

/** A repository that's on and the store's copy of it, as far as a row's work needs them (`StoreCopy`). */
export type RowCopy = { entry: Pick<RepositoryEntry, "copyId" | "identity">; repo: StoreRepository };

/** What a row installs nothing with: its repository was switched off or removed since it was listed (SPEC-157 D.6). */
export const offOrRemovedMessage = "This repository is off or was removed.";

export type StoreContext = {
    /** The copy of each repository that's on, by its copy id, as the list was last read; none for one that isn't. */
    copyOf: (copyId: string) => RowCopy | undefined;
    supportPath: string;
    /** `FUDGE_CLI`: the app's `fudge` tool. */
    cli: string;
    /** `FUDGE_EXTENSIONS_DIR`: where fudge's extensions are installed. */
    extensionsDir: string;
    /** Asks the user; `confirmAlert` in the store. */
    confirm: (title: string, message: string, primary: string) => Promise<boolean>;
    /** Moves a path to the Trash; `trash` in the store. */
    trash: (target: string) => Promise<void>;
    /** Whether Apple's Command Line Tools are set up (`commandLineToolsReady` in `fudge:app`), asked again each time;
     * none means they aren't. */
    commandLineToolsReady?: () => Promise<boolean>;
    /** Shows the view for an extension with a part written in Swift while the tools aren't set up, and resolves with
     * the user's choice (SPEC-145 §3); none means Don't Install. Its third action resolves `build` only once the tools
     * are set up, and opens Settings → Development until then. */
    chooseSwiftParts?: (title: string) => Promise<SwiftPartsChoice>;
    run?: Run;
    now?: () => Date;
    /** Writes a line to `Fudge.log` (`logToFudge`); never throws. */
    log?: (line: string) => void;
    /** How the records of running builds are written (`installing/<pid>.json`); tests slow them down or fail them. */
    buildRecords?: BuildRecordFiles;
    /** The pids of this session's builds (`ownBuilds`). */
    ownBuilds?: Set<number>;
    /** Asks the app to have macOS ask about notifications (`askForNotifications` in `fudge:app`), once the user has
     * confirmed an install or update (SPEC-156 G); not waited for, and its failure never stops the install. */
    askForNotifications?: () => Promise<void>;
};

/**
 * A row's own copy (SPEC-157 D.6), by the row's copy id and never another's: its install, its compatibility check and
 * its README use that copy alone. Refused when its repository is off or was removed meanwhile.
 */
export function rowCopy(context: Pick<StoreContext, "copyOf">, copyId: string): RowCopy {
    const copy = context.copyOf(copyId);
    if (!copy || copy.entry.copyId !== copyId) throw new StoreError(offOrRemovedMessage);
    return copy;
}

/** The confirmation's first line (D.5): where the extension comes from, its repository's identity without `https://`,
 * and the commit. An added repository's extension also says it's kept apart (E.5). */
export function confirmationText(identity: string, commit: string, added: boolean, compatibility: string): string {
    const from = `From ${identity.replace(/^https:\/\//, "")} at ${commit.slice(0, 7)}. It runs its own code on your Mac, like any app you install.`;
    const apart = added ? "It's kept apart from other extensions with the same name, with its own settings and data." : undefined;
    return [from, apart, compatibility].filter((part): part is string => part !== undefined).join("\n\n");
}

/** Calls `askForNotifications` without waiting, swallowing any failure. */
function askForNotifications(context: StoreContext): void {
    try {
        void context.askForNotifications?.().catch(() => {});
    } catch {
        // The install goes on whatever the question did.
    }
}

/**
 * Runs `fudge build` with its record in `installing/` (SPEC-153 C.1): written once it has a pid, and removed when the run
 * has ended, after the write has settled. The record never changes the run's result. The build's output goes to files
 * beside the record, and it writes its outcome there (`--outcome`, SPEC-156 A); a folder that can't be made leaves both
 * out, and the build runs as before. `ran` is told the build's pid and start once it has started.
 */
async function recordedBuild(
    context: StoreContext,
    run: Run,
    args: string[],
    timeout: number,
    about: Omit<BuildAbout, "command">,
    ran: (build: BuildId) => void = () => {},
): Promise<GitResult> {
    const folder = installingFolder(context.supportPath);
    const kept = await mkdir(folder, { recursive: true }).then(
        () => true,
        (error: unknown) => {
            context.log?.(`Couldn't keep the output of ${about.title}'s build: ${error instanceof Error ? error.message : String(error)}`);
            return false;
        },
    );
    const built = kept ? [...args, "--outcome", folder] : args;
    const record = recordBuild({ ...about, command: [context.cli, ...built] }, timeout, {
        supportPath: context.supportPath,
        now: context.now,
        log: context.log,
        files: context.buildRecords ?? buildRecordFiles,
        own: context.ownBuilds ?? ownBuilds,
    });
    try {
        return await run(context.cli, built, { timeout, started: record.started, ...(kept ? { output: record.output } : {}) });
    } finally {
        const build = record.build();
        if (build) ran(build);
        await record.ended();
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
    for (const [key, record] of Object.entries(object)) {
        if (!isValidExtensionId(key) || typeof record !== "object" || record === null) continue;
        const { tree, commit, installedAt, dir, repository } = record as Record<string, unknown>;
        if (typeof tree !== "string" || typeof commit !== "string" || typeof installedAt !== "string") continue;
        if (dir !== undefined && !isValidFolder(dir)) continue;
        // A qualified id's record names its repository's folder, the id's own; Raycast's, under the bare name, names
        // none (SPEC-157 E.1). Swift's `Backup.storeInstalls` reads them the same way.
        const parts = key.split("+");
        const name = parts.at(-1)!;
        const folder = parts.length === 1 ? undefined : parts.slice(0, -1).join("/");
        if (repository !== folder) continue;
        installed[key] = { tree, commit, installedAt, dir: dir ?? name, ...(folder === undefined ? {} : { repository: folder }) };
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

/** The CLI's arguments for installing the extension in `source` into `extensionsDir`, and nowhere else, in Raycast's
 * folder there (`--repository raycast/extensions`, FUD-183), with what to do with a part written in Swift when it has
 * one. */
export function buildArguments(source: string, extensionsDir: string, swiftParts?: SwiftParts): string[] {
    return [
        "build",
        source,
        "--into",
        extensionsDir,
        "--repository",
        raycastFolder,
        ...(swiftParts ? ["--swift-parts", swiftParts] : []),
    ];
}

/** The folder of the store's install of `name`: `<extensionsDir>/raycast/extensions/<name>`, Raycast's folder (FUD-183).
 * Every place that works out where a store install is takes it from here. */
export function installFolder(extensionsDir: string, name: string): string {
    return path.join(extensionsDir, ...raycastFolder.split("/"), name);
}

/** Which of the store's installs of `names` were built without their part written in Swift (SPEC-145 §3), each read
 * from its folder in Raycast's (`installFolder`). */
export async function installsWithoutSwift(extensionsDir: string, names: Iterable<string>): Promise<Set<string>> {
    const found = new Set<string>();
    for (const name of names) {
        if (await installedWithoutSwift(installFolder(extensionsDir, name))) found.add(name);
    }
    return found;
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
 * `<extensionsDir>/raycast/extensions/<name>`, `installFolder`), and records it under its name with its folder. Resolves false when the user cancels, else
 * with what the done message adds (`installNote`); throws `StoreError` when a step refuses or fails. An extension of that name that the store didn't install from this
 * folder is never replaced: one installed another way, one from another folder whose manifest has the same name, or one
 * Fudge bundles.
 */
export async function install(
    entry: StoreEntry,
    context: StoreContext,
    ran: (build: BuildId) => void = () => {},
): Promise<InstallDone | false> {
    const name = checkedName(entry.name);
    const dir = checkedFolder(entry.dir);
    if (bundledNames.includes(name)) throw new StoreError(`${entry.title} can't be installed: ${name} is part of Fudge.`);
    const installed = await readInstalled(context.supportPath);
    const record = installed[name];
    // A development build of this name (`fudgeapp/development/<name>`) is kept apart, so it refuses nothing. An
    // install still at the extensions folder's top level (the app's move gave up, or an older Fudge installed it after
    // the move) isn't seen here: `fudge build`'s own move files it in Raycast's folder first, where this install then
    // replaces it.
    if (record ? !sameFolder(record.dir, dir) : await exists(installFolder(context.extensionsDir, name))) {
        throw new StoreError(nameTakenMessage(name));
    }
    // The row's own copy, as the list is now: one switched off or removed since installs nothing.
    const copy = rowCopy(context, entry.copyId);
    await copy.repo.add(`/extensions/${dir}/`);
    const source = path.join(copy.repo.path, "extensions", dir);
    // The build installs under the name in this manifest, so it must still be the one the list showed.
    const current = await readRegularFile(path.join(source, "package.json"), maxManifestBytes)
        .then((text) => (JSON.parse(text) as { name?: unknown }).name)
        .catch(() => undefined);
    if (current !== name) throw new StoreError(`${entry.title} has changed in the store's copy. Refresh the list and try again.`);
    const problem = await sourceProblem(source);
    if (problem) throw new StoreError(`${entry.title} can't be installed. ${problem}.`);

    const tree = (await copy.repo.trees()).get(dir);
    const checked = await compatibilityOf(source, tree, context);
    // A part written in Swift (SPEC-145 §3): built whenever the tools are set up, with nothing more said (D-118);
    // without them, the view's choice, before anything is installed.
    const choose = () => context.chooseSwiftParts?.(entry.title) ?? Promise.resolve<SwiftPartsChoice>("dont-install");
    const hasSwiftPart = checked !== undefined && !checked.notChecked && checked.swiftPart === true;
    const swift = await decideSwiftParts(hasSwiftPart, context.commandLineToolsReady ?? (async () => false), choose);
    if (!swift) return false;
    const compatibility = compatibilityLine(checked, commandTitles(entry));
    const commit = await copy.repo.commit();
    const confirmed = await context.confirm(
        `${record ? "Update" : "Install"} ${entry.title}?`,
        confirmationText(copy.entry.identity, commit, addedRepository(entry) !== undefined, compatibility),
        record ? "Update" : "Install",
    );
    if (!confirmed) return false;
    askForNotifications(context);

    const run = context.run ?? spawnProgram;
    // Building a part written in Swift fetches and compiles SwiftPM's packages the first time (`swiftBuildTimeout`).
    // When the check didn't answer (its scan failed), the build may have such a part, so it gets that time too.
    const unchecked = checked === undefined || checked.notChecked === true;
    const timeout = (parts?: SwiftParts) =>
        parts === "build" && (hasSwiftPart || unchecked) ? swiftBuildTimeout : buildTimeout;
    const about = { name, dir, title: entry.title, ...(tree === undefined ? {} : { tree }), commit, updating: record !== undefined };
    let args = buildArguments(source, context.extensionsDir, swift.swiftParts);
    let result = await recordedBuild(context, run, args, timeout(swift.swiftParts), about, ran);
    if (result.code === alreadyBuildingStatus) throw new AlreadyBuilding(entry.title);
    // A `swift:` import the check missed, without the tools: the build stopped at it, asking what to do, so the view
    // asks the user instead of showing that as an error.
    if (result.code !== 0 && swift.swiftParts === undefined && askedForSwiftParts(`${result.stdout}\n${result.stderr}`)) {
        const choice = await choose();
        if (choice === "dont-install") return false;
        args = buildArguments(source, context.extensionsDir, choice);
        result = await recordedBuild(context, run, args, choice === "build" ? swiftBuildTimeout : buildTimeout, about, ran);
        if (result.code === alreadyBuildingStatus) throw new AlreadyBuilding(entry.title);
    }
    if (result.code !== 0) {
        const output = [result.stdout, result.stderr].filter((part) => part.trim().length > 0).join("\n");
        throw new BuildFailed(output, ["fudge", ...args].join(" "), result.code);
    }
    if (!tree) throw new StoreError(`Couldn't read ${name}'s version in the store's copy`);
    const recorded: InstallRecord = { tree, commit, installedAt: (context.now?.() ?? new Date()).toISOString(), dir };
    await writeInstalled(context.supportPath, { ...(await readInstalled(context.supportPath)), [name]: recorded });
    // The build scanned the source again: what it turned off is what's true, so say so where it differs.
    const built = await builtCompatibility(
        installFolder(context.extensionsDir, name),
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
    const folder = installFolder(context.extensionsDir, name);
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

/** A row's extension being installed or updated, by this store or by a build an earlier one left running (SPEC-153 B). */
export type Busy = "installing" | "updating";

/**
 * The extensions this store is installing or updating, from the press until the install's run ends, after the list has
 * loaded again (SPEC-153 B). The key is the extension's id (`entryId`, SPEC-157 E.7), since each id is built under its
 * own lock into its own folder: the same name from another repository is another extension. A press for an id it
 * holds, or one `busyElsewhere` names, does nothing: no toast, nothing queued. A press for another id waits its turn in
 * `work`, and its row says so meanwhile.
 */
export class InstallPresses {
    private readonly ids = new Map<string, Busy>();
    private readonly changed: () => void;
    private readonly busyElsewhere: (id: string) => boolean;

    constructor(changed: () => void = () => {}, busyElsewhere: (id: string) => boolean = () => false) {
        this.changed = changed;
        this.busyElsewhere = busyElsewhere;
    }

    state(id: string): Busy | undefined {
        return this.ids.get(id);
    }

    press(id: string, updating: boolean, work: () => Promise<void>): Promise<void> {
        if (this.ids.has(id) || this.busyElsewhere(id)) return Promise.resolve();
        this.ids.set(id, updating ? "updating" : "installing");
        this.changed();
        const ended = () => {
            this.ids.delete(id);
            this.changed();
        };
        try {
            return work().finally(ended);
        } catch (error) {
            ended();
            return Promise.reject(error);
        }
    }
}

/** A toast the press changes as the install goes. Each change shows it again, so the style changes last when it's done. */
export type InstallToast = {
    hide: () => Promise<void>;
    done: (title: string, message?: string) => void;
    failed: (title: string, message: string) => void;
};

/** What the press needs from the view. `failed` logs the failure to `Fudge.log` and pushes `FailureView`. */
export type InstallView = {
    toast: (title: string) => Promise<InstallToast>;
    load: () => Promise<void>;
    failed: (title: string, error: unknown) => void;
    /** Install notifications (SPEC-156 D.1); without them, the press ends as it did before. */
    notices?: InstallNotices;
};

/** The view's side of install notifications. */
export type InstallNotices = {
    /** `installEnded` in `fudge:app`. */
    report: (report: InstallEndReport) => Promise<InstallAnswer>;
    /** Selects the row of `dir` in the repository whose folder is `repository` (Raycast's when none), once. */
    select: (dir: string, repository?: string) => void;
    /** A failure that got a notification: logged, its row marked, and kept for a click; no failure view. */
    failedNotified: (title: string, error: unknown, mark: FailureMark) => void;
    /** The name installed or updated from that repository (Raycast's when none): its row's mark goes. */
    succeeded?: (name: string, repository?: string) => void;
    /** How long to wait for the answer (`reportLimit`, 5 s). */
    limit?: number;
};

/**
 * ↵ Install, ⌘U Update and Try Again, in the store's queue: an animated toast, the install, the list loaded again and a
 * Success toast (SPEC-130). A failure ends in a Failure toast and the failure view (SPEC-116); another build of the
 * extension already running ends in a Success toast that says so, with no failure view and nothing in the log (SPEC-153
 * C.6).
 */
export async function installPressed(entry: StoreEntry, updating: boolean, context: StoreContext, view: InstallView): Promise<void> {
    // An added repository's folder, which the report, the mark and the saved failure carry; none for Raycast's.
    const repository = addedRepository(entry);
    const fromRepository = repository === undefined ? {} : { repository };
    // Pressed again: a failure saved for a click is out of date (SPEC-156 D.4).
    if (view.notices) await removeSavedFailure(context.supportPath, { name: entry.name, ...fromRepository });
    const toast = await view.toast(`${updating ? "Updating" : "Installing"} ${entry.title}…`);
    // The last `fudge build` the install ran, for the app to know it by (SPEC-156 C.1).
    let build: BuildId | undefined;
    const end = (outcome: InstallEndReport["outcome"]): InstallEndReport => ({
        ...(build ? { build: { pid: build.pid, startedAt: build.startedAt } } : {}),
        name: entry.name,
        dir: entry.dir,
        ...fromRepository,
        title: entry.title,
        updating,
        outcome,
    });
    try {
        const done = await install(entry, context, (ran) => {
            build = ran;
        });
        if (!done) {
            await toast.hide();
            return;
        }
        await view.load();
        // With the note when what's on and off isn't what the confirmation said (SPEC-121 §2).
        const shown = doneToast(entry.title, updating, done);
        // The app decides whether a notification says it (SPEC-156 D.1); then no HUD repeats it.
        const answer = view.notices ? await reportEnd(view.notices.report, end("installed"), view.notices.limit) : unanswered;
        view.notices?.succeeded?.(entry.name, repository);
        if (answer.notified) await toast.hide();
        else toast.done(shown.title, shown.message);
        if (!answer.onScreen) view.notices?.select(entry.dir, repository);
    } catch (error) {
        if (error instanceof AlreadyBuilding) {
            toast.done(error.message);
            return;
        }
        // The whole error, its likely cause, Copy Error and Try Again, in a view of its own; the toast only says where
        // to look.
        const title = `Couldn't ${updating ? "update" : "install"} ${entry.title}`;
        const answer = view.notices ? await reportEnd(view.notices.report, end("failed"), view.notices.limit) : unanswered;
        if (view.notices && answer.notified) {
            // The notification opens it, as the row's mark does: no failure view behind the hidden panel.
            await toast.hide();
            const mark: FailureMark = {
                name: entry.name,
                dir: entry.dir,
                ...fromRepository,
                title: entry.title,
                updating,
                failedAt: (context.now?.() ?? new Date()).toISOString(),
                details: failureDetails(error),
            };
            view.notices.failedNotified(title, error, mark);
            view.notices.select(entry.dir, repository);
            await saveFailure(context.supportPath, mark, context.log);
            return;
        }
        toast.failed(title, "See the details.");
        view.failed(title, error);
    }
}
