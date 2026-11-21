// What the store says about an extension's compatibility: from `fudge scan`, cached by the folder's git tree id, so
// each version of an extension is fetched and scanned once. The detail pane scans the selected row only once the
// selection has rested on it; the list shows only what's cached.
import { lstat, mkdir, readdir, rename, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { hasSourceExtension, sourceExtensions } from "../../scripts/compat/source-files.ts";
import { readRegularFile } from "./files.ts";
import { RestingWork, type Timers } from "./resting.ts";
import { spawnProgram } from "./git.ts";
import type { StoreContext } from "./store.ts";
import { scanTimeout } from "./timeouts.ts";

/** What the store needs from `fudge scan <folder> --json`. `byDesign` names the category of a gap counted apart:
 * one Fudge doesn't support (AI, Browser Extension), or signing in (OAuth). `commands` says, for each command of the
 * manifest, which of those it reaches from its own entry (SPEC-109); a scanner from before it has none. */
export type ScanReport = {
    supported: boolean;
    gaps: { api: string; byDesign?: string }[];
    unreadable: string[];
    commands?: { name: string; unsupported: string[] }[];
};

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

/**
 * The categories Fudge doesn't support at all, as `fudge scan` names them (`unsupported` in the runtime's
 * `src/api/stubs.ts`), with how the store names them. Both are in every sentence about them.
 */
export const notSupportedNames: Record<string, string> = {
    AI: "Raycast AI",
    "Browser Extension": "the Raycast Browser Extension",
};
/** `fudge scan`'s category for APIs that sign in, which work through a sign-in server. */
const signInCategory = "OAuth";

/**
 * Which commands use something Fudge doesn't support: how many the manifest has, and the names of those that reach it
 * (`fudge build` installs those not enabled, SPEC-109).
 */
export type ByCommand = { count: number; using: string[] };

/** One scan's outcome, as the store keeps it. `notChecked`: the source was over the caps, so it wasn't scanned.
 * `byCommand` is there when the scan said what each command reaches. */
export type Compatibility =
    | { notChecked: true }
    | {
          notChecked?: false;
          notSupported: string[];
          missing: string[];
          signsIn: boolean;
          unreadable: boolean;
          byCommand?: ByCommand;
      };

/** A command name as the manifest rule has it (`isValidName`'s shape). */
const isCommandName = (name: unknown): name is string => typeof name === "string" && /^[a-z0-9][a-z0-9_-]*$/.test(name);

/** The report's per-command results, when they're all well formed. */
function commandsOf(report: ScanReport): { name: string; unsupported: string[] }[] | undefined {
    const commands = report.commands;
    if (!Array.isArray(commands) || commands.length === 0) return undefined;
    const valid = commands.every(
        (command) =>
            typeof command === "object" &&
            command !== null &&
            isCommandName(command.name) &&
            Array.isArray(command.unsupported) &&
            command.unsupported.every((category) => typeof category === "string"),
    );
    return valid ? commands : undefined;
}

/** The parts of a scan the store shows: categories Fudge doesn't support, APIs it lacks, signing in. */
export function fromReport(report: ScanReport): Compatibility {
    const designed = (gap: { byDesign?: unknown }) =>
        typeof gap.byDesign === "string" && gap.byDesign !== "" ? gap.byDesign : undefined;
    const categories = new Set(report.gaps.map(designed).filter((category) => category !== undefined));
    // With each command's result, what Fudge doesn't support counts only where a command reaches it: an AI tool's
    // use isn't a command's.
    const commands = commandsOf(report);
    const reached = commands ? new Set(commands.flatMap((command) => command.unsupported)) : categories;
    const notSupported = Object.keys(notSupportedNames).filter((category) => reached.has(category));
    const byCommand: ByCommand | undefined = commands && {
        count: commands.length,
        using: commands
            .filter((command) => command.unsupported.some((category) => category in notSupportedNames))
            .map((command) => command.name),
    };
    return {
        ...(byCommand ? { byCommand } : {}),
        notSupported,
        // A category this store doesn't know reads as the APIs it covers.
        missing: [
            ...new Set(
                report.gaps
                    .filter((gap) => {
                        const category = designed(gap);
                        if (category === undefined) return true;
                        return category !== signInCategory && !(category in notSupportedNames);
                    })
                    .map((gap) => gap.api),
            ),
        ],
        signsIn: categories.has(signInCategory),
        unreadable: report.unreadable.length > 0,
    };
}

/** Not compatible: it uses something Fudge doesn't support, in every command (or the scan didn't say which). */
export function isNotCompatible(result: Compatibility | undefined): boolean {
    if (result === undefined || result.notChecked || result.notSupported.length === 0) return false;
    return !result.byCommand || result.byCommand.using.length >= result.byCommand.count;
}

/** Partly compatible: some of its commands use something Fudge doesn't support, and the others don't. */
export function isPartlyCompatible(result: Compatibility | undefined): boolean {
    if (result === undefined || result.notChecked || result.notSupported.length === 0 || !result.byCommand) return false;
    return result.byCommand.using.length > 0 && result.byCommand.using.length < result.byCommand.count;
}

/** The list's tag for a cached result: red Not compatible, orange Partly compatible, or none. */
export function compatibilityTag(result: Compatibility | undefined): "Not compatible" | "Partly compatible" | undefined {
    if (isNotCompatible(result)) return "Not compatible";
    return isPartlyCompatible(result) ? "Partly compatible" : undefined;
}

/** A command's title from its name, for the sentences that name commands; its name when the manifest has no title. */
export type CommandTitles = (name: string) => string;
const byName: CommandTitles = (name) => name;

/** "Raycast AI", "Raycast AI or the Raycast Browser Extension". */
function unsupportedNames(categories: string[], join: "and" | "or"): string {
    const names = categories.map((category) => notSupportedNames[category]!);
    return names.length <= 1 ? (names[0] ?? "") : `${names.slice(0, -1).join(", ")} ${join} ${names.at(-1)}`;
}

/** "a", "a and b", "a, b and c". */
export function listed(names: string[]): string {
    return names.length <= 1 ? (names[0] ?? "") : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

/** Up to five names, then how many more. */
function fewOf(names: string[], each: (name: string) => string = (name) => name): string {
    const more = names.length > 5 ? `, and ${names.length - 5} more` : "";
    return `${names.slice(0, 5).map(each).join(", ")}${more}`;
}

/**
 * The install confirmation's line about what works: from the scan, or saying it couldn't run. What Fudge doesn't
 * support comes first, as not compatible; what it doesn't have yet next; signing in last, never as not compatible.
 */
export function compatibilityLine(result: Compatibility | undefined, titles: CommandTitles = byName): string {
    if (!result || result.notChecked) return "Fudge couldn't check what this extension uses.";
    const sentences: string[] = [];
    const turnOn = "You can turn them on in Settings → Commands.";
    if (isPartlyCompatible(result)) {
        // The commands this scan found, which `fudge build` installs not enabled; the build scans again, and the done
        // message says where it differs (`installNote`).
        const using = result.byCommand!.using;
        const they = using.length === 1 ? "It" : "They";
        sentences.push(
            `Partly compatible with Fudge: ${listed(using.map(titles))} ${using.length === 1 ? "uses" : "use"} ` +
                `${unsupportedNames(result.notSupported, "or")}, which Fudge doesn't support. ` +
                `${they} won't be enabled. ${turnOn.replace("them", using.length === 1 ? "it" : "them")}`,
        );
    } else if (result.notSupported.length > 0 && result.byCommand) {
        sentences.push(
            `Not compatible with Fudge: every command uses ${unsupportedNames(result.notSupported, "or")}, which ` +
                `Fudge doesn't support, so none of them will be enabled. ${turnOn}`,
        );
    } else if (result.notSupported.length > 0) {
        const names = listed(result.notSupported.map((category) => notSupportedNames[category]!));
        const it = result.notSupported.length > 1 ? "them" : "it";
        sentences.push(
            `Not compatible with Fudge: this extension uses ${names}, which Fudge doesn't support. ` +
                `Commands that use ${it} won't work.`,
        );
    }
    if (result.missing.length > 0) {
        const subject = sentences.length > 0 ? "It also uses" : "This extension uses";
        sentences.push(
            `${subject} things Fudge doesn't have yet: ${fewOf(result.missing)}. Some of its commands may not work.`,
        );
    }
    if (result.signsIn) {
        const subject = sentences.length > 0 ? "It signs" : "This extension signs";
        sentences.push(
            `${subject} in with OAuth, which works if the sign-in server chosen in Settings → Sign-in supports its ` +
                "provider.",
        );
    }
    if (sentences.length > 0) return sentences.join(" ");
    if (result.unreadable) return "Fudge couldn't read all of this extension's source, so some of it may not work.";
    return "Fudge supports everything this extension uses.";
}

/**
 * What `fudge build` turned off, from the install's `compatibility.json` (`{ "commands": { "<command>": ["AI"] } }`):
 * the commands of `commands` that use something Fudge doesn't support, and what. Undefined when there's no such file,
 * or it isn't one: the build couldn't check, so every command is on, as the app reads it too.
 */
export async function builtCompatibility(
    installed: string,
    commands: string[],
): Promise<Record<string, string[]> | undefined> {
    let file: unknown;
    try {
        file = JSON.parse(await readRegularFile(path.join(installed, "compatibility.json"), maxBuiltBytes));
    } catch {
        return undefined;
    }
    const listed = (file as { commands?: unknown } | null)?.commands;
    if (typeof listed !== "object" || listed === null || Array.isArray(listed)) return undefined;
    const off: Record<string, string[]> = {};
    for (const name of commands) {
        const uses = (listed as Record<string, unknown>)[name];
        const known = Array.isArray(uses) ? uses.filter((category) => category in notSupportedNames) : [];
        if (known.length > 0) off[name] = known;
    }
    return off;
}

/** The build's own small file; anything bigger isn't one (the app's `CommandCompatibility.maxBytes`). */
const maxBuiltBytes = 1 << 20;

/**
 * What the install's done message adds when what `fudge build` turned off (`built`) isn't what the confirmation named
 * from the store's result (`confirmed`), so the user is never left with commands off that weren't named, or on that
 * were (SPEC-121 §2). The build scans exactly the source it installs, so `built` is what's true. Undefined when the two
 * agree.
 */
export function installNote(
    confirmed: Compatibility | undefined,
    built: Record<string, string[]> | undefined,
    titles: CommandTitles = byName,
): string | undefined {
    const result = confirmed && !confirmed.notChecked ? confirmed : undefined;
    const named = result?.byCommand?.using ?? [];
    if (!built) {
        if (!result || named.length === 0) return undefined;
        return `Fudge couldn't check which of its commands use ${unsupportedNames(result.notSupported, "or")}, so every command is on.`;
    }
    const off = Object.keys(built);
    if (off.length === named.length && off.every((name) => named.includes(name))) return undefined;
    if (off.length === 0) return `Every command is on: none of them uses ${unsupportedNames(result!.notSupported, "or")}.`;
    const categories = Object.keys(notSupportedNames).filter((category) =>
        off.some((name) => built[name]!.includes(category)),
    );
    const one = off.length === 1;
    return (
        `Turned off: ${listed(off.map(titles))}, which ${one ? "uses" : "use"} ${unsupportedNames(categories, "or")}. ` +
        `You can turn ${one ? "it" : "them"} on in Settings → Commands.`
    );
}

/** What the detail pane is showing for a row: a result, a scan waiting or running, or one that failed. */
export type CheckState = Compatibility | "checking" | "failed";

/** The detail pane's Compatibility line. API names are code spans; `readCompatibility` only lets identifiers in. */
export function compatibilityText(state: CheckState, titles: CommandTitles = byName): string {
    if (state === "checking") return "Checking…";
    if (state === "failed") return "Couldn't check";
    if (state.notChecked) return "Not checked: installing checks it";
    const parts: string[] = [];
    if (isPartlyCompatible(state)) {
        const { count, using } = state.byCommand!;
        const names = unsupportedNames(state.notSupported, "or").replace(/^the /, "");
        parts.push(
            `Partly compatible: ${using.length} of ${count} commands ${using.length === 1 ? "uses" : "use"} ${names}: ` +
                fewOf(using.map(titles)),
        );
    } else if (state.notSupported.length > 0) {
        const names = state.notSupported.map((category) => notSupportedNames[category]!.replace(/^the /, ""));
        parts.push(`Not compatible: ${listed(names)}`);
    }
    if (state.missing.length > 0) parts.push(`Missing: ${fewOf(state.missing, (api) => `\`${api}\``)}`);
    if (state.signsIn) parts.push("Signs in with OAuth (Settings → Sign-in)");
    if (parts.length === 0 && state.unreadable) parts.push("Partly checked: some of its source couldn't be read");
    return parts.length > 0 ? parts.join(". ") : "Compatible";
}

// MARK: - The cache

/** Where the results are kept, by tree id: in the store's data folder, which outlives `repo/`. */
export function compatibilityFile(supportPath: string): string {
    return path.join(supportPath, "compatibility.json");
}
export const maxCachedResults = 4000;
const maxCacheBytes = 4 * 1024 * 1024;
const isTree = (key: string) => /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/.test(key);
const isAPI = (name: unknown) => typeof name === "string" && /^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*$/.test(name);

/**
 * Which scanner wrote a result: the `fudge` tool's size and modification time. Every build or update of Fudge
 * replaces the tool, and what it supports may change with it, so results from another one aren't used.
 */
export async function scannerIdentity(cli: string): Promise<string> {
    try {
        const info = await stat(cli);
        return `${info.size}-${Math.floor(info.mtimeMs)}`;
    } catch {
        return "unknown";
    }
}

function validResult(value: unknown): Compatibility | undefined {
    if (typeof value !== "object" || value === null) return undefined;
    const record = value as Record<string, unknown>;
    if (record.notChecked === true) return { notChecked: true };
    const { notSupported, missing, signsIn, unreadable } = record;
    const known = (category: unknown) => typeof category === "string" && category in notSupportedNames;
    if (!Array.isArray(notSupported) || !notSupported.every(known)) return undefined;
    if (!Array.isArray(missing) || missing.length > 500 || !missing.every(isAPI)) return undefined;
    if (typeof signsIn !== "boolean" || typeof unreadable !== "boolean") return undefined;
    const result = { notSupported: notSupported as string[], missing: missing as string[], signsIn, unreadable };
    if (record.byCommand === undefined) return result;
    const { count, using } = (record.byCommand ?? {}) as Record<string, unknown>;
    if (!Number.isInteger(count) || (count as number) < 1 || (count as number) > 1000) return undefined;
    if (!Array.isArray(using) || using.length > (count as number) || !using.every(isCommandName)) return undefined;
    return { ...result, byCommand: { count: count as number, using: using as string[] } };
}

/**
 * The cached results this scanner wrote, by tree id, oldest first. A file from another scanner, or one that's
 * missing, broken or too big, reads as empty, and entries that don't pass the checks are dropped.
 */
export async function readCompatibility(supportPath: string, scanner: string): Promise<Map<string, Compatibility>> {
    const results = new Map<string, Compatibility>();
    let file: unknown;
    try {
        file = JSON.parse(await readRegularFile(compatibilityFile(supportPath), maxCacheBytes));
    } catch {
        return results;
    }
    if (typeof file !== "object" || file === null) return results;
    const { scanner: writtenBy, trees } = file as Record<string, unknown>;
    if (writtenBy !== scanner || typeof trees !== "object" || trees === null) return results;
    for (const [tree, value] of Object.entries(trees)) {
        const result = validResult(value);
        if (isTree(tree) && result) results.set(tree, result);
    }
    return results;
}

/** Writes the results atomically, keeping the newest `maxCachedResults`. */
export async function writeCompatibility(
    supportPath: string,
    scanner: string,
    results: Map<string, Compatibility>,
): Promise<void> {
    const kept = [...results].slice(-maxCachedResults);
    await mkdir(supportPath, { recursive: true });
    const file = compatibilityFile(supportPath);
    const temporary = `${file}.${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify({ scanner, trees: Object.fromEntries(kept) })}\n`);
    await rename(temporary, file);
}

/** Adds one result to the file, as its newest. Call it in the store's queue (`oneAtATime`), like every write. */
export async function rememberCompatibility(
    supportPath: string,
    scanner: string,
    tree: string,
    result: Compatibility,
): Promise<void> {
    const results = await readCompatibility(supportPath, scanner);
    results.delete(tree);
    results.set(tree, result);
    await writeCompatibility(supportPath, scanner, results);
}

// MARK: - Checking one folder

/**
 * What a detail scan checks out: the files under the folder's `src/` with the extensions the scanner reads
 * (`sourceExtensions`), never its assets or anything else.
 */
export function scanPatterns(dir: string): string[] {
    return sourceExtensions.map((extension) => `/extensions/${dir}/src/**/*.${extension}`);
}

/**
 * Whether `scanPatterns` checks out a file under `src/` (`file` is relative to it): a source file. A sparse pattern
 * matches a path's folders too, so a file in a folder named like a script (`lib.ts/`) is one as well.
 */
export const isScanned = (file: string) => file.split("/").some(hasSourceExtension);

/**
 * The caps on a scan while browsing, the first two known from the trees before anything is downloaded:
 * - `maxScanFiles`, the source files (`isScanned`): no extension in the store has more than about 220.
 * - `maxSrcFiles`, every file under `src/`, assets included: the bound on the download, since the fetch brings each
 *   one of at most `maxScanBytes`, and a partial clone's filter can't pick files by name. The most in the store is
 *   about 300.
 * - `maxScanBytes`, each file's size, which the fetch applies, and the source's total, checked before scanning (only 3
 *   of about 3,600 have more than 5 MiB, all of it generated data).
 * Past any of them the row says "Not checked", and installing it scans it anyway.
 */
export const maxScanFiles = 300;
export const maxSrcFiles = 1000;
export const maxScanBytes = 5 * 1024 * 1024;

async function sourceBytes(folder: string): Promise<number> {
    let total = 0;
    const walk = async (dir: string) => {
        const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
        for (const entry of entries) {
            const target = path.join(dir, entry.name);
            if (entry.isDirectory()) await walk(target);
            else if (entry.isFile() && isScanned(path.relative(folder, target))) total += (await lstat(target)).size;
        }
    };
    await walk(folder);
    return total;
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

/**
 * Whether git's error says the server refused to send an object it didn't advertise, by git's own words: protocol v0's
 * "not our ref" (`remote error: upload-pack: not our ref <id>`), and "Server does not allow request for unadvertised
 * object" when the server allows no such request at all. Protocol v2, which GitHub speaks, takes any id. Anything
 * else (a timeout, a network failure, a protocol error) isn't a refusal.
 */
export function isRefusedWant(error: unknown): boolean {
    const text = errorText(error);
    return /\bnot our ref\b/.test(text) || text.includes("Server does not allow request for unadvertised object");
}

/**
 * Fetches `dir`'s source files, scans them with `fudge scan`, and takes the patterns out again. Resolves undefined
 * when `cancelled()` turns true before the fetch or before the scan; throws when git or the scan fails. Call it in
 * the store's git queue (`oneAtATime`). `dir` is a checked folder.
 */
export async function checkFolder(
    dir: string,
    context: StoreContext,
    cancelled: () => boolean,
    signal?: AbortSignal,
): Promise<Compatibility | undefined> {
    // The fetch brings every file under `src/` of at most `maxScanBytes`, assets included, so the download's cap counts
    // them all; the scan's counts only the source files.
    const files = await context.repo.srcFiles(dir);
    const sources = files.filter((file) => isScanned(file.path));
    if (files.length > maxSrcFiles || sources.length > maxScanFiles) return { notChecked: true };
    if (cancelled()) return undefined;
    const patterns = scanPatterns(dir);
    // Only a source file that isn't here matters: an asset left out for its size is never read.
    const missingSources = async () => {
        const missing = await context.repo.missingObjects(dir);
        return sources.filter((file) => missing.has(file.object)).length;
    };
    let bounded = sources.length > 0;
    // Only what isn't here yet is fetched: a folder checked before in this version downloads nothing again.
    if (bounded && (await missingSources()) > 0) {
        try {
            // The one step a cancel ends (`signal`), since it writes nothing but new packs; every other step runs to
            // its end, and the check stops between steps.
            await context.repo.fetchSource(dir, maxScanBytes, signal);
        } catch (error) {
            if (cancelled()) return undefined;
            // Only a server that won't send a folder's tree gets the fetch as before (`add`'s lazy fetch: each source
            // file by its id, whatever its size), with the size checked after it's here. Any other failure fails the
            // check, since falling back would drop the per-file cap for a timeout or a network error.
            if (!isRefusedWant(error)) {
                console.error(`The store's bounded fetch failed: ${errorText(error)}`);
                throw error;
            }
            console.error(`The server won't send the folder's tree, so the store fetches its source as before: ${errorText(error)}`);
            bounded = false;
        }
        if (cancelled()) return undefined;
        // A source file over the cap wasn't downloaded, and the scan would need it.
        if (bounded && (await missingSources()) > 0) return { notChecked: true };
    }
    if (bounded) await context.repo.addFetched(...patterns);
    else await context.repo.add(...patterns);
    try {
        const source = path.join(context.repo.path, "extensions", dir);
        if ((await sourceBytes(path.join(source, "src"))) > maxScanBytes) return { notChecked: true };
        if (cancelled()) return undefined;
        const report = await scanExtension(source, context);
        if (!report) throw new Error("fudge scan failed");
        return fromReport(report);
    } finally {
        await context.repo.drop(patterns);
    }
}

// MARK: - Checking the selected row

/**
 * Scans the row the selection rests on, one at a time (`RestingWork`): a check starts only after the selection has
 * stayed on an uncached row for `delay` ms, and a new `select` cancels the last: its timer, or the check itself, which
 * stops before its fetch or scan, and whose fetch is ended (`signal`). So moving through rows fetches nothing, and a
 * cached row never fetches.
 */
export class CompatibilityChecks {
    readonly #work: RestingWork<Compatibility>;

    constructor(options: {
        delay?: number;
        timers?: Timers;
        cached: (tree: string) => Compatibility | undefined;
        check: (
            dir: string,
            tree: string,
            cancelled: () => boolean,
            signal: AbortSignal,
        ) => Promise<Compatibility | undefined>;
        changed: (dir: string, tree: string, result: Compatibility | "failed") => void;
    }) {
        const split = (key: string) => key.split("\0") as [string, string];
        this.#work = new RestingWork({
            delay: options.delay,
            timers: options.timers,
            done: (key) => options.cached(split(key)[1]) !== undefined,
            run: (key, cancelled, signal) => options.check(...split(key), cancelled, signal),
            changed: (key, result) => options.changed(...split(key), result),
        });
    }

    /** The row now selected with the detail showing, or nothing. */
    select(dir: string | undefined, tree: string | undefined): void {
        this.#work.select(dir && tree ? `${dir}\0${tree}` : undefined);
    }

    /** Cancels the waiting or running check. */
    stop(): void {
        this.#work.stop();
    }
}
