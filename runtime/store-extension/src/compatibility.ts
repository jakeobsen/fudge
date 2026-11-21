// What the store says about an extension's compatibility: from `fudge scan`, cached by the folder's git tree id, so
// each version of an extension is fetched and scanned once. The detail pane scans the selected row only once the
// selection has rested on it; the list shows only what's cached.
import { lstat, mkdir, readdir, rename, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { readRegularFile } from "./files.ts";
import { RestingWork, type Timers } from "./resting.ts";
import { spawnProgram } from "./git.ts";
import type { StoreContext } from "./store.ts";
import { scanTimeout } from "./timeouts.ts";

/** What the store needs from `fudge scan <folder> --json`. `byDesign` names the category of a gap counted apart:
 * one Fudge doesn't support (AI, Browser Extension), or signing in (OAuth). */
export type ScanReport = { supported: boolean; gaps: { api: string; byDesign?: string }[]; unreadable: string[] };

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

/** One scan's outcome, as the store keeps it. `notChecked`: the source was over the caps, so it wasn't scanned. */
export type Compatibility =
    | { notChecked: true }
    | { notChecked?: false; notSupported: string[]; missing: string[]; signsIn: boolean; unreadable: boolean };

/** The parts of a scan the store shows: categories Fudge doesn't support, APIs it lacks, signing in. */
export function fromReport(report: ScanReport): Compatibility {
    const designed = (gap: { byDesign?: unknown }) =>
        typeof gap.byDesign === "string" && gap.byDesign !== "" ? gap.byDesign : undefined;
    const categories = new Set(report.gaps.map(designed).filter((category) => category !== undefined));
    return {
        notSupported: Object.keys(notSupportedNames).filter((category) => categories.has(category)),
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

export function isNotCompatible(result: Compatibility | undefined): boolean {
    return result !== undefined && !result.notChecked && result.notSupported.length > 0;
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
export function compatibilityLine(result: Compatibility | undefined): string {
    if (!result || result.notChecked) return "Fudge couldn't check what this extension uses.";
    const sentences: string[] = [];
    if (result.notSupported.length > 0) {
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

/** What the detail pane is showing for a row: a result, a scan waiting or running, or one that failed. */
export type CheckState = Compatibility | "checking" | "failed";

/** The detail pane's Compatibility line. API names are code spans; `readCompatibility` only lets identifiers in. */
export function compatibilityText(state: CheckState): string {
    if (state === "checking") return "Checking…";
    if (state === "failed") return "Couldn't check";
    if (state.notChecked) return "Not checked: installing checks it";
    const parts: string[] = [];
    if (state.notSupported.length > 0) {
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
    return { notSupported: notSupported as string[], missing: missing as string[], signsIn, unreadable };
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

/** What a detail scan fetches: the folder's source files only, never its assets or anything else. */
export function scanPatterns(dir: string): string[] {
    return ["ts", "tsx", "js", "jsx"].map((extension) => `/extensions/${dir}/src/**/*.${extension}`);
}
const isFetchedSource = (file: string) => /\.(tsx?|jsx?)$/.test(file);

/**
 * The caps on a scan while browsing. The number of source files is known from the trees before anything is
 * downloaded (no extension in the store has more than about 220); their size only once they're fetched, and it's
 * checked before scanning (only 3 of about 3,600 have more than 5 MiB, all of it generated data). Past either, the
 * row says "Not checked", and installing it scans it anyway.
 */
export const maxScanFiles = 300;
export const maxScanBytes = 5 * 1024 * 1024;

async function sourceBytes(folder: string): Promise<number> {
    let total = 0;
    const walk = async (dir: string) => {
        const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
        for (const entry of entries) {
            const target = path.join(dir, entry.name);
            if (entry.isDirectory()) await walk(target);
            else if (entry.isFile() && isFetchedSource(entry.name)) total += (await lstat(target)).size;
        }
    };
    await walk(folder);
    return total;
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
): Promise<Compatibility | undefined> {
    const files = (await context.repo.sourceFiles(dir)).filter(isFetchedSource);
    if (files.length > maxScanFiles) return { notChecked: true };
    if (cancelled()) return undefined;
    const patterns = scanPatterns(dir);
    await context.repo.add(...patterns);
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
