// Static compatibility scan: which parts of @raycast/api an extension's source
// uses, and which of those fudge's runtime doesn't provide.
//
// Sources are first turned into JavaScript by esbuild, which drops everything
// that's only a type (`LaunchProps`, `List.Item.Accessory`, `import type`), so
// what's left is what runs. JSX stays as written, so `<Action.CopyToClipboard>`
// counts like `Action.CopyToClipboard`.

import { transform } from "esbuild";

/** What one source file uses: API paths such as `Clipboard.copy`, and the names it imports from @raycast/utils. */
export interface Uses {
    api: Set<string>;
    utils: Set<string>;
}

const identifier = String.raw`[A-Za-z_$][\w$]*`;

/** Turns TypeScript, TSX or JSX into JavaScript without types; JSX is kept. */
export async function toJavaScript(source: string, file: string): Promise<string> {
    const loader = file.endsWith(".tsx") ? "tsx" : file.endsWith(".ts") ? "ts" : "jsx";
    const result = await transform(source, { loader, jsx: "preserve", format: "esm", target: "esnext" });
    return result.code;
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
    for (const match of code.matchAll(new RegExp(String.raw`\{([^}]*)\}\s*=\s*${require}`, "g"))) named(match[1], /\s*:\s*/);
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

export type Support = "implemented" | "missing" | "unknown";

/** Reading any member of a not-available stub throws; reading one of an implemented value doesn't. */
function isStub(value: unknown): boolean {
    if ((typeof value !== "object" && typeof value !== "function") || value === null) return false;
    try {
        Reflect.get(value, "__fudgeProbe");
        return false;
    } catch {
        return true;
    }
}

/**
 * Whether fudge provides `path` in `api` (the module extensions receive). Capitalised segments are components,
 * namespaces and constants (`Action.CopyToClipboard`, `Toast.Style`) and are followed; the first lowercase
 * segment is a function or property (`Clipboard.copy`, `environment.supportPath`), checked for being there, and
 * nothing after it is (`environment.commandName.length` is about the string). "unknown" is a name that isn't
 * one of Raycast's exports at all.
 */
export function support(api: Record<string, unknown>, path: string): Support {
    const [first, ...rest] = path.split(".");
    if (!(first in api)) return "unknown";
    let value: unknown;
    try {
        value = api[first];
    } catch {
        return "missing";
    }
    if (isStub(value)) return "missing";
    for (const segment of rest) {
        if ((typeof value !== "object" && typeof value !== "function") || value === null) return "implemented";
        if (/^[A-Z]/.test(segment)) {
            try {
                value = Reflect.get(value, segment);
            } catch {
                return "missing";
            }
            if (value === undefined || isStub(value)) return "missing";
        } else {
            return segment in value ? "implemented" : "missing";
        }
    }
    return "implemented";
}

/** The part of a path that names the missing API: up to its first lowercase segment (`Clipboard.copy`). */
export function apiName(path: string): string {
    const segments = path.split(".");
    const end = segments.findIndex((segment, index) => index > 0 && !/^[A-Z]/.test(segment));
    return segments.slice(0, end === -1 ? segments.length : end + 1).join(".");
}
