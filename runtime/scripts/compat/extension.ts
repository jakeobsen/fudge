// One extension's compatibility scan: what `make compat-scan` does for each extension in a folder, and what
// `fudge scan <folder>` does for one.

import { spawnSync } from "node:child_process";
import { lstatSync, readdirSync, statSync, type Dirent } from "node:fs";
import { basename, join, relative } from "node:path";
import { maxManifestBytes, maxSourceBytes, readRegularFile } from "./files.ts";
import { RAYCAST_UTILS_PATHS } from "./raycast-utils.generated.ts";
import { unsupported } from "../../src/api/stubs.ts";
import { gaps, isExtensionSource, toJavaScript, uses, type Gap, type Transform } from "./scan.ts";

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

export interface Result {
    gaps: Gap[];
    notRaycast: string[];
    utils: string[];
    /** Source files that couldn't be read or turned into JavaScript, relative to the extension. */
    unreadable: string[];
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
    const found = { api: new Set<string>(), utils: new Set<string>() };
    const { files, unwalked } = sources(folder);
    const unreadable = [...unwalked];
    for (const file of files) {
        try {
            const used = uses(await toJavaScript(readRegularFile(file, maxSourceBytes), file, options.transform));
            for (const path of used.api) found.api.add(path);
            for (const name of used.utils) found.utils.add(name);
        } catch {
            unreadable.push(relative(folder, file));
        }
    }
    return {
        ...gaps(found, options.api, options.declared, RAYCAST_UTILS_PATHS),
        utils: [...found.utils].sort(),
        unreadable,
    };
}

/** What `fudge scan <folder> --json` prints. `supported` means no gaps at all, the ones counted apart included, and
 * every source file read. A gap counted apart names its category in `byDesign`. */
export interface Report {
    extension: string;
    supported: boolean;
    gaps: (Gap & { byDesign?: string })[];
    unreadable: string[];
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
    }
    if (scanned.unreadable.length > 0) lines.push(`Couldn't read: ${scanned.unreadable.join(", ")}`);
    return lines.join("\n");
}
