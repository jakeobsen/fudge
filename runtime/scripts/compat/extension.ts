// One extension's compatibility scan: what `make compat-scan` does for each extension in a folder, and what
// `fudge scan <folder>` does for one.

import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { RAYCAST_UTILS_PATHS } from "./raycast-utils.generated.ts";
import { gaps, isExtensionSource, toJavaScript, uses, type Gap, type Transform } from "./scan.ts";

/**
 * APIs left out of fudge on purpose, by category. AI and the Browser Extension depend on Raycast's servers. OAuth
 * (`OAuth.PKCEClient` and the @raycast/utils exports built on it) is left out by the architect's decision D-50.
 */
export const byDesign: Record<string, { api: RegExp; utils?: string[] }> = {
    AI: { api: /^AI(\.|$)/ },
    "Browser Extension": { api: /^BrowserExtension(\.|$)/ },
    OAuth: { api: /^OAuth(\.|$)/, utils: ["OAuthService", "withAccessToken", "getAccessToken"] },
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

function sources(src: string): string[] {
    return (readdirSync(src, { recursive: true }) as string[]).filter(isExtensionSource).map((file) => join(src, file));
}

/** Scans the extension in `folder`: every source file under its `src/`. Nothing is built or run. */
export async function scanExtension(folder: string, options: ScanOptions): Promise<Result> {
    const found = { api: new Set<string>(), utils: new Set<string>() };
    const unreadable: string[] = [];
    for (const file of sources(join(folder, "src"))) {
        try {
            const used = uses(await toJavaScript(readFileSync(file, "utf8"), file, options.transform));
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

/** What `fudge scan <folder> --json` prints. `supported` means no gaps at all, by-design ones included, and every
 * source file read. */
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
        const manifest = JSON.parse(readFileSync(join(folder, "package.json"), "utf8")) as { name?: unknown };
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

/** `fudge scan <folder>` without `--json`: a short list for a person. */
export function describe(scanned: Report): string {
    if (scanned.supported) return `${scanned.extension}: Fudge supports everything it uses.`;
    const lines =
        scanned.gaps.length === 0 ? [] : [`${scanned.extension} uses things Fudge doesn't have yet:`];
    for (const gap of scanned.gaps) {
        const how = gap.kind === "via @raycast/utils" ? `${kindWords[gap.kind]}: ${gap.via!.join(", ")}` : kindWords[gap.kind];
        lines.push(`  ${gap.api} (${how}${gap.byDesign ? `; ${gap.byDesign}, left out on purpose` : ""})`);
    }
    if (scanned.unreadable.length > 0) lines.push(`Couldn't read: ${scanned.unreadable.join(", ")}`);
    return lines.join("\n");
}
