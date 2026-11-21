// One extension's compatibility scan: what `make compat-scan` does for each extension in a folder, and what
// `fudge scan <folder>` does for one.

import { spawnSync } from "node:child_process";
import { lstatSync, readdirSync, statSync, type Dirent } from "node:fs";
import { basename, join, posix, relative, sep } from "node:path";
import { maxManifestBytes, maxSourceBytes, readRegularFile } from "./files.ts";
import { RAYCAST_UTILS_PATHS } from "./raycast-utils.generated.ts";
import { unsupported } from "../../src/api/stubs.ts";
import { gaps, imports, isExtensionSource, toJavaScript, uses, type Gap, type Transform, type Uses } from "./scan.ts";

/**
 * APIs counted apart from gaps, by category, each with what a person is told about it. Fudge doesn't support AI or
 * the Browser Extension at all (`unsupported`, FUD-118). OAuth (`OAuth.PKCEClient` and the @raycast/utils exports
 * built on it) signs in through a sign-in server, only to the providers that server supports (D-63), which a scan
 * can't tell from an extension's own.
 */
export const byDesign: Record<string, { api: RegExp; utils?: string[]; says: string }> = {
    ...Object.fromEntries(
        unsupported.map(({ category, api, name }) => [
            category,
            { api, says: `uses ${name}, which Fudge doesn't support` },
        ]),
    ),
    OAuth: {
        api: /^OAuth(\.|$)/,
        utils: ["OAuthService", "withAccessToken", "getAccessToken"],
        says: "signs in with OAuth, which needs a sign-in server (Settings → Sign-in)",
    },
};

/** The by-design category a gap belongs to, if any. */
export function category(gap: Gap): string | undefined {
    for (const [name, { api: pattern, utils }] of Object.entries(byDesign)) {
        if (pattern.test(gap.api)) return name;
        if (utils && gap.kind === "via @raycast/utils" && gap.via!.every((via) => utils.includes(via))) return name;
    }
    return undefined;
}

/**
 * What one command of the manifest reaches that Fudge doesn't support at all: `unsupported`'s categories ("AI",
 * "Browser Extension"), from the files its entry imports, and theirs, and so on. `traced` is false when an import
 * couldn't be followed (its entry missing or unreadable, a file outside `src/`, an alias the scan doesn't know), and
 * the command then counts as reaching all of the extension's source.
 */
export interface CommandResult {
    name: string;
    unsupported: string[];
    traced: boolean;
}

export interface Result {
    gaps: Gap[];
    notRaycast: string[];
    utils: string[];
    /** Source files that couldn't be read or turned into JavaScript, relative to the extension. */
    unreadable: string[];
    /** Each command in the manifest, in its order; none when the manifest can't be read. */
    commands: CommandResult[];
}

export interface ScanOptions {
    /** `createApiModule()`. */
    api: Record<string, unknown>;
    /** Whether Raycast's types declare a path (`raycastDeclarations`). */
    declared: (path: string) => boolean;
    /** How sources become JavaScript; esbuild's JS API unless given. */
    transform?: Transform;
}

/** A transform that runs an esbuild binary, as `fudge scan` does with the app's own (no esbuild package there). It
 * takes the same options as the JS API's, so both give the same JavaScript. */
export function binaryTransform(esbuild: string): Transform {
    return async (source, loader) => {
        const result = spawnSync(
            esbuild,
            [`--loader=${loader}`, "--jsx=preserve", "--format=esm", "--target=esnext", "--log-level=error"],
            { input: source, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: 30_000 },
        );
        if (result.status !== 0) throw new Error(result.stderr || result.error?.message || "esbuild failed");
        return result.stdout;
    };
}

/**
 * The source files under `folder`'s `src`, found without following a link: only real folders are walked. A link with
 * a source's name is a source like any other, which `readRegularFile` then refuses. A link to a folder (`src/lib ->
 * ../../elsewhere`, `src/self -> .`) is never walked, and goes in `unwalked` unless the scan would skip that folder
 * anyway (`__tests__`, `node_modules`, …); so do a `src` that's a link and a folder that can't be listed.
 */
function sources(folder: string): { files: string[]; unwalked: string[] } {
    const files: string[] = [];
    const unwalked: string[] = [];
    const walk = (dir: string, relativeDir: string) => {
        let entries: Dirent[];
        try {
            entries = readdirSync(dir, { withFileTypes: true });
        } catch {
            unwalked.push(relative(folder, dir));
            return;
        }
        for (const entry of entries) {
            const path = join(dir, entry.name);
            const relativePath = relativeDir ? `${relativeDir}/${entry.name}` : entry.name;
            // Anything with a source's name is a source, even a folder or a link, which `readRegularFile` refuses.
            if (isExtensionSource(relativePath)) files.push(path);
            // Only stat (never read or list) what a link points to, to tell a folder from anything else.
            else if (entry.isSymbolicLink() && isFolder(path) && isExtensionSource(`${relativePath}/index.ts`)) {
                unwalked.push(relative(folder, path));
            }
            if (entry.isDirectory()) walk(path, relativePath);
        }
    };
    const src = join(folder, "src");
    if (lstatSync(src, { throwIfNoEntry: false })?.isDirectory()) walk(src, "");
    else unwalked.push("src");
    return { files, unwalked };
}

function isFolder(path: string): boolean {
    try {
        return statSync(path).isDirectory();
    } catch {
        return false;
    }
}

/**
 * Scans the extension in `folder`: every source file under its `src/`. Nothing is built or run, and no link is
 * followed. Only regular files of at most `maxSourceBytes` are read (`readRegularFile`); a link, FIFO, device or folder
 * with a source's name, a bigger file, and a link to a folder (`sources`) are listed as unreadable.
 */
export async function scanExtension(folder: string, options: ScanOptions): Promise<Result> {
    const { files, unwalked } = sources(folder);
    const unreadable = [...unwalked];
    const scanned = new Map<string, { uses: Uses; imports: string[] }>();
    for (const file of files) {
        try {
            const code = await toJavaScript(readRegularFile(file, maxSourceBytes), file, options.transform);
            scanned.set(relative(folder, file).split(sep).join("/"), { uses: uses(code), imports: imports(code) });
        } catch {
            unreadable.push(relative(folder, file));
        }
    }
    const found = union([...scanned.values()].map((file) => file.uses));
    const known = knownFiles([...scanned.keys(), ...unreadable.map((file) => file.split(sep).join("/"))]);
    const commands = commandNames(folder).map((name): CommandResult => {
        const { files: reached, traced } = reach(name, scanned, known);
        const used = traced ? union(reached.map((file) => scanned.get(file)!.uses)) : found;
        const categories = new Set(gaps(used, options.api, options.declared, RAYCAST_UTILS_PATHS).gaps.map(category));
        return { name, unsupported: unsupportedCategories.filter((name) => categories.has(name)), traced };
    });
    return {
        ...gaps(found, options.api, options.declared, RAYCAST_UTILS_PATHS),
        utils: [...found.utils].sort(),
        unreadable,
        commands,
    };
}

/** The categories Fudge doesn't support at all, in `unsupported`'s order. */
const unsupportedCategories = unsupported.map(({ category }) => category);

function union(all: Uses[]): Uses {
    const found: Uses = { api: new Set<string>(), utils: new Set<string>() };
    for (const used of all) {
        for (const path of used.api) found.api.add(path);
        for (const name of used.utils) found.utils.add(name);
    }
    return found;
}

/** The manifest's command names, read as the package.json the report reads; none when it can't be read. */
function commandNames(folder: string): string[] {
    try {
        const manifest = JSON.parse(readRegularFile(join(folder, "package.json"), maxManifestBytes)) as {
            commands?: unknown;
        };
        if (!Array.isArray(manifest.commands)) return [];
        return manifest.commands.flatMap((command: unknown) => {
            const name = (command as { name?: unknown } | null)?.name;
            return typeof name === "string" && /^[a-z0-9][a-z0-9_-]*$/.test(name) ? [name] : [];
        });
    } catch {
        return [];
    }
}

/** Looks a relative path up among the extension's files ignoring case, as APFS (and so the build) does. */
export type KnownFiles = (path: string) => string | undefined;

export function knownFiles(paths: string[]): KnownFiles {
    const byKey = new Map<string, string>();
    for (const path of paths) if (!byKey.has(path.toLowerCase())) byKey.set(path.toLowerCase(), path);
    return (path) => byKey.get(path.toLowerCase());
}

/** A command's entry, as `fudge build` finds it (`ExtensionBuilder.sourceExtensions`' order). */
const entryExtensions = ["tsx", "ts", "jsx", "js"];
/** Files a module may import that aren't code, so they can't reach Raycast's API. */
const dataFile = /\.(?:json|css|scss|sass|less|svg|png|jpe?g|gif|webp|ico|txt|md|html?|ya?ml|toml|csv|xml|wasm)$/i;

/**
 * The source files a command reaches from its entry, as relative paths, and whether every import could be followed.
 * Only imports of the extension's own files are followed, against the files the scan found under `src/`: relative
 * ones, and `@/…` or `~/…` as `src/…`, the alias extensions use; a package's import is the package's.
 */
export function reach(
    command: string,
    scanned: Map<string, { imports: string[] }>,
    known: KnownFiles,
): { files: string[]; traced: boolean } {
    const entry = entryExtensions.map((extension) => known(`src/${command}.${extension}`)).find((file) => file);
    if (!entry) return { files: [], traced: false };
    const seen = new Set<string>([entry]);
    const pending = [entry];
    let traced = true;
    while (pending.length > 0) {
        const file = pending.pop()!;
        const module = scanned.get(file);
        if (!module) {
            traced = false;
            continue;
        }
        for (const specifier of module.imports) {
            const target = resolveImport(file, specifier, known);
            if (target === "package" || target === "data") continue;
            if (target === undefined) traced = false;
            else if (!seen.has(target)) {
                seen.add(target);
                pending.push(target);
            }
        }
    }
    return { files: [...seen].filter((file) => scanned.has(file)), traced };
}

/**
 * The file `specifier`, imported from `from`, names among `known`; "package" for a package, "data" for a file that
 * isn't code, undefined for one of the extension's own that can't be found. TypeScript's ESM style names the output
 * (`./x.js` for `x.ts`), so that's tried too.
 */
export function resolveImport(from: string, specifier: string, known: KnownFiles): string | "package" | "data" | undefined {
    let base: string;
    if (specifier === "." || specifier === ".." || specifier.startsWith("./") || specifier.startsWith("../")) {
        base = posix.normalize(posix.join(posix.dirname(from), specifier));
    } else if (specifier.startsWith("@/") || specifier.startsWith("~/")) {
        base = `src/${specifier.slice(2)}`;
    } else if (specifier.startsWith("src/")) {
        base = posix.normalize(specifier);
    } else if (specifier.startsWith("/") || specifier.startsWith("#")) {
        return undefined;
    } else {
        return "package";
    }
    if (dataFile.test(base)) return "data";
    if (!base.startsWith("src/")) return undefined;
    const stem = base.replace(/\.(?:[cm]?js|jsx)$/, "");
    const candidates = [
        base,
        ...entryExtensions.map((extension) => `${base}.${extension}`),
        ...entryExtensions.map((extension) => `${stem}.${extension}`),
        ...entryExtensions.map((extension) => `${base}/index.${extension}`),
    ];
    for (const candidate of candidates) {
        const found = known(candidate);
        if (found) return found;
    }
    return undefined;
}

/** What `fudge scan <folder> --json` prints. `supported` means no gaps at all, the ones counted apart included, and
 * every source file read. A gap counted apart names its category in `byDesign`. */
export interface Report {
    extension: string;
    supported: boolean;
    gaps: (Gap & { byDesign?: string })[];
    unreadable: string[];
    /** Each command and what it reaches that Fudge doesn't support (`CommandResult`). */
    commands: CommandResult[];
}

/** The report for one scanned extension, named by its manifest's `name` (else its folder's). */
export function report(folder: string, result: Result): Report {
    let name = basename(folder);
    try {
        const manifest = JSON.parse(readRegularFile(join(folder, "package.json"), maxManifestBytes)) as {
            name?: unknown;
        };
        if (typeof manifest.name === "string" && manifest.name) name = manifest.name;
    } catch {
        // The folder's name will do.
    }
    return {
        extension: name,
        supported: result.gaps.length === 0 && result.unreadable.length === 0,
        gaps: result.gaps.map((gap) => {
            const design = category(gap);
            return design ? { ...gap, byDesign: design } : gap;
        }),
        unreadable: result.unreadable,
        commands: result.commands,
    };
}

const kindWords: Record<Gap["kind"], string> = {
    missing: "not in Fudge",
    "render-but-fail": "shows, but fails when used",
    "not-drawn": "not drawn",
    "via @raycast/utils": "through @raycast/utils",
};

/**
 * `fudge scan <folder>` without `--json`: a short list for a person. What Fudge doesn't have yet comes first; the
 * APIs counted apart follow, by category, each saying why (`byDesign`).
 */
export function describe(scanned: Report): string {
    if (scanned.supported) return `${scanned.extension}: Fudge supports everything it uses.`;
    const via = (gap: Gap) => (gap.kind === "via @raycast/utils" ? `through @raycast/utils: ${gap.via!.join(", ")}` : "");
    const lines: string[] = [];
    const missing = scanned.gaps.filter((gap) => !gap.byDesign);
    if (missing.length > 0) lines.push(`${scanned.extension} uses things Fudge doesn't have yet:`);
    for (const gap of missing) lines.push(`  ${gap.api} (${via(gap) || kindWords[gap.kind]})`);
    for (const design of new Set(scanned.gaps.flatMap((gap) => (gap.byDesign ? [gap.byDesign] : [])))) {
        lines.push(`${scanned.extension} ${byDesign[design]?.says ?? `uses ${design}`}:`);
        for (const gap of scanned.gaps.filter((gap) => gap.byDesign === design)) {
            lines.push(`  ${gap.api}${via(gap) ? ` (${via(gap)})` : ""}`);
        }
        const using = scanned.commands.filter((command) => command.unsupported.includes(design));
        if (unsupportedCategories.includes(design) && scanned.commands.length > 0) {
            const which = using.length === scanned.commands.length ? "every command" : `${using.length} of ${scanned.commands.length} commands`;
            lines.push(`  in ${which}${using.length > 0 && using.length < scanned.commands.length ? `: ${using.map((command) => command.name).join(", ")}` : ""}`);
        }
    }
    if (scanned.unreadable.length > 0) lines.push(`Couldn't read: ${scanned.unreadable.join(", ")}`);
    return lines.join("\n");
}
