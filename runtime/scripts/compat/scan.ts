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

/**
 * What a JavaScript module uses from @raycast/api and @raycast/utils. An export passed whole to `canAccess`
 * (`isAccessCheck`) isn't a use of it.
 */
export function uses(code: string): Uses {
    const api = new Set<string>();
    const body = withoutImports(code);
    for (const [local, imported] of bindings(code, "@raycast/api")) {
        const pattern = new RegExp(String.raw`(?<![\w$.])${local.replace("$", "\\$")}((?:\.${identifier})*)`, "g");
        for (const match of body.matchAll(pattern)) {
            const path = imported === "*" ? match[1].slice(1) : imported + match[1];
            if (path && !isAccessCheck(body, match.index, match[0].length, path)) api.add(path);
        }
    }
    const utils = new Set<string>();
    for (const [, imported] of bindings(code, "@raycast/utils")) if (imported !== "*") utils.add(imported);
    return { api, utils };
}

/** Right after `canAccess(`, as `environment.canAccess(` or a destructured `canAccess(`. */
const afterCanAccess = /(?<=(?:^|[^\w$])canAccess\s*\(\s*)/y;
/** Right before the call's closing parenthesis. */
const beforeClose = /\s*\)/y;

/**
 * Whether the reference to `path` at `start` (`length` characters long) is the whole argument of a `canAccess(…)`
 * call: `environment.canAccess(AI)`, a destructured `canAccess(BrowserExtension)`, or `canAccess(R.AI)` through a
 * namespace. That's how an extension asks whether an API is there (in Fudge it says no for those it doesn't support),
 * so it isn't a use of the API. Only an export passed whole counts: `canAccess(AI.Model)`, `const x = AI` and `AI.ask`
 * are uses.
 */
function isAccessCheck(code: string, start: number, length: number, path: string): boolean {
    if (path.includes(".")) return false;
    afterCanAccess.lastIndex = start;
    beforeClose.lastIndex = start + length;
    return afterCanAccess.test(code) && beforeClose.test(code);
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

/** The part of a path that names the missing API: up to its first lowercase segment (`Clipboard.copy`). */
export function apiName(path: string): string {
    const segments = path.split(".");
    const end = segments.findIndex((segment, index) => index > 0 && !/^[A-Z]/.test(segment));
    return segments.slice(0, end === -1 ? segments.length : end + 1).join(".");
}

// MARK: - Where an extension signs in (SPEC-132 §7)

/** The `OAuth.RedirectMethod`s among the API paths an extension's own code uses (`Web`, `App`, …), sorted. */
export function redirectMethods(found: Uses): string[] {
    const methods = new Set<string>();
    for (const path of found.api) {
        const method = /^OAuth\.RedirectMethod\.([A-Za-z]+)$/.exec(path);
        if (method) methods.add(method[1]!);
    }
    return [...methods].sort();
}

/**
 * What one module says about where it signs in: the authorize URLs it gives an OAuth client, as esbuild wrote their
 * expressions (`authorizeUrl` in an object, as `OAuthService` and its built-in providers take it, and `endpoint` in
 * `authorizationRequest({ … })`), and the constants it declares, by name (`const AUTHORIZE_URL = "https://…"`), to
 * resolve those with across the extension's files (`resolveString`). An authorize URL whose expression the scan can't
 * find is undefined.
 */
export interface SignInSites {
    urls: (string | undefined)[];
    constants: Map<string, string[]>;
}

/** Where the expression starting at `start` ends: before the first `,`, `;`, `)`, `]` or `}` outside brackets, strings
 * and templates, or at the end of the code. */
function expressionEnd(code: string, start: number): number {
    let depth = 0;
    let index = start;
    for (; index < code.length; index += 1) {
        const char = code[index]!;
        if (char === '"' || char === "'" || char === "`") index += literalLength(code.slice(index)) - 1;
        else if (char === "(" || char === "[" || char === "{") depth += 1;
        else if (char === ")" || char === "]" || char === "}") {
            if (depth === 0) return index;
            depth -= 1;
        } else if ((char === "," || char === ";") && depth === 0) return index;
    }
    return index;
}

/** How long the string or template literal at the start of `text` is, its quotes included; longer than `text` when
 * it isn't closed. */
function literalLength(text: string): number {
    const quote = text[0]!;
    let index = 1;
    while (index < text.length && text[index] !== quote) {
        if (text[index] === "\\") index += 2;
        else if (quote === "`" && text.startsWith("${", index)) index = expressionEnd(text, index + 2) + 1;
        else index += 1;
    }
    return index + 1;
}

/** The expression starting at `start`, trimmed. */
function expressionAt(code: string, start: number): string {
    return code.slice(start, expressionEnd(code, start)).trim();
}

/** A property name as written in an object: an identifier, quoted or not. */
const propertyName = String.raw`(["']?)(${identifier})\1`;

/** The top-level properties of an object literal's text (`{ a: 1, "b": 2, c }`): name → value expression, a shorthand
 * one as its own name. Undefined when it isn't an object literal. */
function objectProperties(literal: string): Map<string, string> | undefined {
    if (!literal.startsWith("{") || !literal.endsWith("}")) return undefined;
    const properties = new Map<string, string>();
    const body = literal.slice(1, -1);
    let index = 0;
    while (index < body.length) {
        const end = expressionEnd(body, index);
        const entry = body.slice(index, end).trim();
        const named = new RegExp(String.raw`^${propertyName}\s*:\s*([\s\S]+)$`).exec(entry);
        if (named) properties.set(named[2]!, named[3]!.trim());
        else if (new RegExp(String.raw`^${identifier}$`).test(entry)) properties.set(entry, entry);
        index = end + 1;
    }
    return properties;
}

/** Reads where one module signs in (`SignInSites`). */
export function signInSites(code: string): SignInSites {
    const body = withoutImports(code);
    const urls: (string | undefined)[] = [];
    // A property of an object: `{ authorizeUrl: "https://…" }`, and the shorthand `{ clientId, authorizeUrl }`.
    for (const match of body.matchAll(/(?<=[{,]\s*)(["']?)authorizeUrl\1\s*:\s*/g)) {
        urls.push(expressionAt(body, match.index + match[0].length));
    }
    for (const _ of body.matchAll(/(?<=[{,]\s*)authorizeUrl\s*(?=[,}])/g)) urls.push("authorizeUrl");
    for (const match of body.matchAll(/(?<![\w$])authorizationRequest\s*\(\s*/g)) {
        // An argument that isn't an object literal (`authorizationRequest(options)`), or one without an `endpoint`
        // the scan can see (`{ ...options }`), has an endpoint it can't read.
        const properties = objectProperties(expressionAt(body, match.index + match[0].length));
        urls.push(properties?.get("endpoint"));
    }
    const constants = new Map<string, string[]>();
    for (const match of body.matchAll(new RegExp(String.raw`\b(?:const|let|var)\s+(${identifier})\s*=\s*`, "g"))) {
        const values = constants.get(match[1]!) ?? [];
        values.push(expressionAt(body, match.index + match[0].length));
        constants.set(match[1]!, values);
    }
    return { urls, constants };
}

/** The top-level operands of a sum (`a + "b" + c`), outside brackets, strings and templates. */
function operands(expression: string): string[] {
    const parts: string[] = [];
    let depth = 0;
    let start = 0;
    for (let index = 0; index < expression.length; index += 1) {
        const char = expression[index]!;
        if (char === '"' || char === "'" || char === "`") index += literalLength(expression.slice(index)) - 1;
        else if (char === "(" || char === "[" || char === "{") depth += 1;
        else if (char === ")" || char === "]" || char === "}") depth -= 1;
        else if (char === "+" && depth === 0) {
            parts.push(expression.slice(start, index).trim());
            start = index + 1;
        }
    }
    parts.push(expression.slice(start).trim());
    return parts;
}

/** A string literal's or a template's plain text, with JavaScript's escapes read; undefined for an escape it doesn't
 * know. */
function unescaped(text: string): string | undefined {
    let failed = false;
    const value = text.replace(/\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|[\s\S])/g, (_, escape: string) => {
        if (escape.startsWith("u{")) return String.fromCodePoint(parseInt(escape.slice(2, -1), 16));
        if (/^[ux]/.test(escape) && escape.length > 1) return String.fromCharCode(parseInt(escape.slice(1), 16));
        const simple: Record<string, string> = { n: "\n", t: "\t", r: "\r", "0": "\0", "\n": "" };
        if (escape in simple) return simple[escape]!;
        if (/[\\'"`/$?#&=:.-]/.test(escape)) return escape;
        failed = true;
        return "";
    });
    return failed ? undefined : value;
}

/**
 * The string an expression stands for, when the scan can tell: a string literal, a template whose placeholders it
 * can tell, a constant with one value, or a sum of those. Anything else (a parameter, a preference, a call) is
 * undefined.
 */
export function resolveString(expression: string, constants: Map<string, string[]>, depth = 0): string | undefined {
    if (depth > 8) return undefined;
    let text = expression.trim();
    // Parentheses around the whole expression: `("https://" + host)`.
    while (text.startsWith("(") && text.endsWith(")") && expressionEnd(text, 1) === text.length - 1) {
        text = text.slice(1, -1).trim();
    }
    const parts = operands(text);
    if (parts.length > 1) {
        const values = parts.map((part) => resolveString(part, constants, depth + 1));
        return values.every((value) => value !== undefined) ? values.join("") : undefined;
    }
    if ((text.startsWith('"') || text.startsWith("'")) && literalLength(text) === text.length) {
        return unescaped(text.slice(1, -1));
    }
    if (text.startsWith("`") && literalLength(text) === text.length) {
        let value = "";
        let index = 1;
        let plain = 1;
        while (index < text.length - 1) {
            if (text[index] === "\\") index += 2;
            else if (text.startsWith("${", index)) {
                const end = expressionEnd(text, index + 2);
                const before = unescaped(text.slice(plain, index));
                const inside = resolveString(text.slice(index + 2, end), constants, depth + 1);
                if (before === undefined || inside === undefined) return undefined;
                value += before + inside;
                index = end + 1;
                plain = index;
            } else index += 1;
        }
        const rest = unescaped(text.slice(plain, text.length - 1));
        return rest === undefined ? undefined : value + rest;
    }
    if (new RegExp(String.raw`^${identifier}$`).test(text)) {
        const values = new Set((constants.get(text) ?? []).map((value) => resolveString(value, constants, depth + 1)));
        return values.size === 1 ? [...values][0] : undefined;
    }
    return undefined;
}
