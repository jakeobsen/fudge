// Static compatibility scan: which parts of @raycast/api an extension's source
// uses, and which of those fudge's runtime doesn't provide.
//
// Sources are first turned into JavaScript by esbuild, which drops everything
// that's only a type (`LaunchProps`, `List.Item.Accessory`, `import type`), so
// what's left is what runs. JSX stays as written, so `<Action.CopyToClipboard>`
// counts like `Action.CopyToClipboard`.

import { isNotAvailable, LEFT_OUT, NOT_DRAWN, NotAvailableError, plainRecords, UNAVAILABLE } from "../../src/api/stubs.ts";

/** What one source file uses: API paths such as `Clipboard.copy`, and the names it imports from @raycast/utils. */
export interface Uses {
    api: Set<string>;
    utils: Set<string>;
}

const identifier = String.raw`[A-Za-z_$][\w$]*`;

/** Turns one source file into JavaScript without types, keeping JSX, as esbuild does with these options. */
export type Transform = (source: string, loader: "ts" | "tsx" | "jsx") => Promise<string>;

/** esbuild's JS API, from runtime/node_modules. It's imported only when used: the scanner bundled into the app
 * (`fudge scan`) has no esbuild package, and passes a transform that runs the app's esbuild binary instead. */
const esbuildTransform: Transform = async (source, loader) => {
    const { transform } = await import("esbuild");
    const result = await transform(source, { loader, jsx: "preserve", format: "esm", target: "esnext" });
    return result.code;
};

/** Turns TypeScript, TSX or JSX into JavaScript without types; JSX is kept. */
export async function toJavaScript(source: string, file: string, transform: Transform = esbuildTransform): Promise<string> {
    const loader = file.endsWith(".tsx") ? "tsx" : file.endsWith(".ts") ? "ts" : "jsx";
    return transform(source, loader);
}

/** The bindings a module's imports and requires create: local name → imported name, `*` for the whole module. */
function bindings(code: string, module: string): Map<string, string> {
    const names = new Map<string, string>();
    const quoted = `["']${module.replace("/", "\\/")}["']`;
    const named = (list: string, separator: RegExp) => {
        for (const part of list.split(",")) {
            const [imported, local] = part.trim().split(separator).map((name) => name.trim());
            if (imported && new RegExp(`^${identifier}$`).test(imported)) names.set(local || imported, imported);
        }
    };
    for (const match of code.matchAll(new RegExp(String.raw`import\s+([^;]*?)\s+from\s*${quoted}`, "g"))) {
        let clause = match[1];
        const braces = /\{([^}]*)\}/.exec(clause);
        if (braces) {
            named(braces[1], /\s+as\s+/);
            clause = clause.replace(braces[0], "");
        }
        const star = new RegExp(String.raw`\*\s*as\s+(${identifier})`).exec(clause);
        if (star) names.set(star[1], "*");
        // A default import of an ES module namespace (with esModuleInterop) behaves like `* as`.
        const fallback = new RegExp(String.raw`^\s*(${identifier})\s*,?`).exec(clause);
        if (fallback && !star) names.set(fallback[1], "*");
    }
    const require = String.raw`require\(\s*${quoted}\s*\)`;
    // `[^{}]`, so a brace before the destructuring (esbuild's CommonJS wrapper, `__commonJS({ … (exports) {`) can't
    // swallow it.
    for (const match of code.matchAll(new RegExp(String.raw`\{([^{}]*)\}\s*=\s*${require}`, "g"))) named(match[1], /\s*:\s*/);
    for (const match of code.matchAll(new RegExp(String.raw`(?:const|let|var)\s+(${identifier})\s*=\s*${require}`, "g"))) {
        names.set(match[1], "*");
    }
    return names;
}

/** The import and require statements themselves, so their names don't count as uses. */
function withoutImports(code: string): string {
    return code
        .replace(/import\s+[^;]*?\s+from\s*["'][^"']+["'];?/g, "")
        .replace(/(?:const|let|var)\s+[^;=]*=\s*require\(\s*["'][^"']+["']\s*\);?/g, "");
}

/** What a JavaScript module uses from @raycast/api and @raycast/utils. */
export function uses(code: string): Uses {
    const api = new Set<string>();
    const body = withoutImports(code);
    for (const [local, imported] of bindings(code, "@raycast/api")) {
        const pattern = new RegExp(String.raw`(?<![\w$.])${local.replace("$", "\\$")}((?:\.${identifier})*)`, "g");
        for (const match of body.matchAll(pattern)) {
            const path = imported === "*" ? match[1].slice(1) : imported + match[1];
            if (path) api.add(path);
        }
    }
    const utils = new Set<string>();
    for (const [, imported] of bindings(code, "@raycast/utils")) if (imported !== "*") utils.add(imported);
    return { api, utils };
}

/**
 * Every module specifier a JavaScript module loads: `import … from`, a bare `import "…"`, `export … from` (a barrel's
 * re-exports), `import("…")` and `require("…")`. esbuild has already dropped the imports used only as types, so what's
 * left is what runs.
 */
export function imports(code: string): string[] {
    const found = new Set<string>();
    const patterns = [
        /\b(?:import|export)\s+[^;]*?\bfrom\s*["']([^"']+)["']/g,
        /\bimport\s*["']([^"']+)["']/g,
        /\bimport\s*\(\s*["']([^"']+)["']\s*\)/g,
        /\brequire\s*\(\s*["']([^"']+)["']\s*\)/g,
    ];
    for (const pattern of patterns) for (const match of code.matchAll(pattern)) found.add(match[1]!);
    return [...found];
}

/**
 * Whether `code` has an `import()` or `require()` whose target isn't a plain string (a template with a value in it, a
 * variable, a sum), which no scan can follow: `import(\`./commands/${name}\`)`.
 */
export function hasComputedImport(code: string): boolean {
    return /\b(?:import|require)\s*\(\s*(?!["'][^"']*["']\s*\))/.test(code);
}

/** Why an extension can't use an API in fudge. */
export type GapKind = "missing" | "render-but-fail" | "not-drawn" | "via @raycast/utils";

/**
 * What fudge does with an API path: provides it, lacks it (and how), or the path isn't Raycast API at all
 * (`Color.Gray`, a test mock's `showToast.mockResolvedValue`).
 */
export type Support = "implemented" | "not-raycast" | Exclude<GapKind, "via @raycast/utils">;

function isObjectLike(value: unknown): value is object {
    return (typeof value === "object" || typeof value === "function") && value !== null;
}

/** The gap a value itself stands for: a stub, or a component carrying one of the markers (src/api/stubs.ts). */
function gapOf(value: unknown): Support | undefined {
    if (isNotAvailable(value)) return "missing";
    if (!isObjectLike(value)) return undefined;
    if (Reflect.get(value, LEFT_OUT) !== undefined) return "missing";
    if (Reflect.get(value, NOT_DRAWN) !== undefined) return "not-drawn";
    if (Reflect.get(value, UNAVAILABLE) !== undefined) return "render-but-fail";
    return undefined;
}

/** Reads a member: its value, or `missing` when reading it throws `NotAvailableError`. */
function read(value: object, key: string): { value: unknown } | "missing" {
    try {
        return { value: Reflect.get(value, key) };
    } catch (error) {
        // A getter that needs a running command (`environment.commandName`) throws something else: it's there.
        return error instanceof NotAvailableError ? "missing" : { value: undefined };
    }
}

/**
 * Whether fudge provides `path` in `api` (the module extensions receive). Capitalised segments are components,
 * namespaces and constants (`Action.CopyToClipboard`, `Toast.Style`) and are followed; the first lowercase
 * segment is a function or property (`Clipboard.copy`, `environment.supportPath`), checked for being there, and
 * nothing after it is (`environment.commandName.length` is about the string). A value on the way that's a stub,
 * or a component marked as failing when used or as not drawn by the app, makes the path a gap of that kind.
 * Anything under a record of the extension's own data (`plainRecords`: the deprecated `preferences`, read as
 * `preferences.apiKey.value`) is there, since its members are the extension's names, known only during a launch.
 * `declared` says whether Raycast's types declare the path; without it, only the export is checked.
 */
export function support(api: Record<string, unknown>, path: string, declared?: (path: string) => boolean): Support {
    const [first, ...rest] = path.split(".");
    if (!(first! in api) || (declared && !declared(apiName(path)))) return "not-raycast";
    const top = read(api, first!);
    if (top === "missing") return "missing";
    let value = top.value;
    let gap = gapOf(value);
    if (gap) return gap;
    for (const segment of rest) {
        if (!isObjectLike(value) || plainRecords.has(value)) return "implemented";
        const capitalised = /^[A-Z]/.test(segment);
        if (!capitalised && !(segment in value)) return "missing";
        const member = read(value, segment);
        if (member === "missing") return "missing";
        value = member.value;
        if (capitalised && value === undefined) return "missing";
        gap = gapOf(value);
        if (gap) return gap;
        if (!capitalised) return "implemented";
    }
    return "implemented";
}

/** One API an extension can't use in fudge. `via` names the @raycast/utils exports it comes through. */
export interface Gap {
    api: string;
    kind: GapKind;
    via?: string[];
}

/**
 * The gaps in what an extension uses, and the paths it uses that aren't Raycast API. Each @raycast/utils export
 * it uses adds the paths that export needs (`utilsPaths`); a gap only reached that way is `via @raycast/utils`.
 */
export function gaps(
    found: Uses,
    api: Record<string, unknown>,
    declared: (path: string) => boolean,
    utilsPaths: Readonly<Record<string, readonly string[]>>,
): { gaps: Gap[]; notRaycast: string[] } {
    const byApi = new Map<string, Gap>();
    const notRaycast = new Set<string>();
    for (const path of found.api) {
        const result = support(api, path, declared);
        if (result === "not-raycast") notRaycast.add(apiName(path));
        else if (result !== "implemented" && !byApi.has(apiName(path))) byApi.set(apiName(path), { api: apiName(path), kind: result });
    }
    for (const name of [...found.utils].sort()) {
        for (const path of utilsPaths[name] ?? []) {
            const result = support(api, path, declared);
            if (result === "implemented" || result === "not-raycast") continue;
            const gap = byApi.get(apiName(path)) ?? { api: apiName(path), kind: "via @raycast/utils", via: [] };
            if (gap.kind === "via @raycast/utils" && !gap.via!.includes(name)) gap.via!.push(name);
            byApi.set(gap.api, gap);
        }
    }
    const sorted = [...byApi.values()].sort((a, b) => a.api.localeCompare(b.api));
    return { gaps: sorted, notRaycast: [...notRaycast].sort() };
}

/**
 * Whether a file under an extension's `src/` is extension code: a script, not a declaration file, and not a test
 * or mock (`*.test.*`, `*.spec.*`, or inside `__mocks__/`, `__tests__/`, `test/` or `tests/`).
 */
export function isExtensionSource(relativePath: string): boolean {
    if (!/\.(tsx?|jsx?)$/.test(relativePath) || relativePath.endsWith(".d.ts")) return false;
    const segments = relativePath.split(/[\\/]/);
    if (segments.includes("node_modules")) return false;
    if (segments.slice(0, -1).some((folder) => ["__mocks__", "__tests__", "test", "tests"].includes(folder))) return false;
    return !/\.(test|spec)\.[^.]+$/.test(segments.at(-1)!);
}

/** The part of a path that names the missing API: up to its first lowercase segment (`Clipboard.copy`). */
export function apiName(path: string): string {
    const segments = path.split(".");
    const end = segments.findIndex((segment, index) => index > 0 && !/^[A-Z]/.test(segment));
    return segments.slice(0, end === -1 ? segments.length : end + 1).join(".");
}
