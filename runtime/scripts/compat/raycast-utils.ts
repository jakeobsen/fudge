// Derives scripts/compat/raycast-utils.generated.ts: each export of @raycast/utils, with the @raycast/api paths
// its code uses. Extensions bundle @raycast/utils from their own dependencies, so the compat scan can't see what
// it calls; with this table, an extension using an export inherits its paths.
//
// The source is the published package at the version pinned in package.json (a devDependency): its source map
// carries the original `src/` files. Each one goes through the scanner's own path extraction (`toJavaScript`,
// `uses`). An export gets the paths of the file that defines it and of every file that file imports, so a file
// exporting several functions gives each of them all of its paths.
//
// Run it with `npm run generate`. `npm run typecheck` runs it with --check, which fails if the file is out of date
// (after a version bump, or a change to the extraction).

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { apiName, toJavaScript, uses } from "./scan.ts";

const outputPath = fileURLToPath(new URL("./raycast-utils.generated.ts", import.meta.url));
// Its `exports` hide package.json and the source map from `require.resolve`, so it is read from node_modules.
const packageDirectory = fileURLToPath(new URL("../../node_modules/@raycast/utils/", import.meta.url));

interface SourceMap {
    sources: string[];
    sourcesContent: (string | null)[];
}

interface Module {
    /** API paths the file itself uses. */
    paths: Set<string>;
    /** Files it imports or re-exports from. */
    imports: Set<string>;
    /** Exported name → the file and name it comes from (itself, for a local declaration). */
    exports: Map<string, { file: string; name: string }>;
    /** Files it re-exports everything from (`export * from`). */
    exportAll: string[];
}

/** The source file a relative specifier names, among the package's files. */
function resolve(files: Map<string, string>, from: string, specifier: string): string | undefined {
    const base = normalize(join(dirname(from), specifier));
    const candidates = ["", ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.tsx", "/index.js"].map((end) => base + end);
    return candidates.find((candidate) => files.has(candidate));
}

async function readModule(files: Map<string, string>, file: string): Promise<Module> {
    const code = await toJavaScript(files.get(file)!, file);
    const module: Module = { paths: new Set(), imports: new Set(), exports: new Map(), exportAll: [] };
    for (const path of uses(code).api) module.paths.add(apiName(path));
    const local = (specifier: string) => (specifier.startsWith(".") ? resolve(files, file, specifier) : undefined);
    /** `{ a, b as c }` → [name, alias]. */
    const names = (list: string) =>
        list
            .split(",")
            .map((part) => part.trim().split(/\s+as\s+/))
            .filter(([name]) => name);
    // esbuild turns `export { a } from "./b"` into an import and a local `export { a }`, so a local export of an
    // imported name is followed to the file it came from.
    const imported = new Map<string, { file: string; name: string }>();
    for (const match of code.matchAll(/(?:^|[;\s])(import|export)\s*(?:([^;]*?)\s*from\s*)?["']([^"']+)["']/g)) {
        const target = local(match[3]!);
        if (!target) continue;
        module.imports.add(target);
        const clause = match[2]?.trim() ?? "";
        const list = /\{([^}]*)\}/.exec(clause);
        if (match[1] === "import") {
            for (const [name, alias] of list ? names(list[1]!) : []) imported.set(alias ?? name!, { file: target, name: name! });
        } else if (clause === "*") {
            module.exportAll.push(target);
        } else {
            for (const [name, alias] of list ? names(list[1]!) : []) module.exports.set(alias ?? name!, { file: target, name: name! });
        }
    }
    for (const match of code.matchAll(/(?:^|[;\s])export\s+(?:async\s+)?(?:function\*?|class|const|let|var)\s+([\w$]+)/g)) {
        module.exports.set(match[1]!, { file, name: match[1]! });
    }
    for (const match of code.matchAll(/(?:^|[;\s])export\s*\{([^}]*)\}(?!\s*from)/g)) {
        for (const [name, alias] of names(match[1]!)) {
            if (!module.exports.has(alias ?? name!)) module.exports.set(alias ?? name!, imported.get(name!) ?? { file, name: name! });
        }
    }
    return module;
}

/** Each export of the package's entry point → the @raycast/api paths it needs. */
export async function utilsTable(map: SourceMap, entry = "src/index.ts"): Promise<Record<string, string[]>> {
    const files = new Map<string, string>();
    map.sources.forEach((source, index) => {
        const content = map.sourcesContent[index];
        if (content != null) files.set(normalize(source), content);
    });
    const modules = new Map<string, Module>();
    for (const file of files.keys()) modules.set(file, await readModule(files, file));

    /** The file that declares `name`, following re-exports. */
    const definition = (file: string, name: string, seen = new Set<string>()): string | undefined => {
        if (seen.has(`${file}#${name}`)) return undefined;
        seen.add(`${file}#${name}`);
        const module = modules.get(file);
        const exported = module?.exports.get(name);
        if (exported) return exported.file === file ? file : definition(exported.file, exported.name, seen);
        for (const all of module?.exportAll ?? []) {
            const found = definition(all, name, seen);
            if (found) return found;
        }
        return undefined;
    };
    const closure = (file: string): Set<string> => {
        const reached = new Set<string>([file]);
        for (const current of reached) for (const imported of modules.get(current)?.imports ?? []) reached.add(imported);
        return reached;
    };
    const names = (file: string, seen = new Set<string>()): string[] => {
        if (seen.has(file)) return [];
        seen.add(file);
        const module = modules.get(file);
        return [...(module?.exports.keys() ?? []), ...(module?.exportAll ?? []).flatMap((all) => names(all, seen))];
    };

    const table: Record<string, string[]> = {};
    for (const name of [...new Set(names(entry))].sort()) {
        const file = definition(entry, name);
        if (!file) continue;
        const paths = new Set<string>();
        for (const reached of closure(file)) for (const path of modules.get(reached)!.paths) paths.add(path);
        table[name] = [...paths].sort();
    }
    return table;
}

export function renderTable(table: Record<string, string[]>, version: string): string {
    const lines = [
        `// Generated by scripts/compat/raycast-utils.ts from @raycast/utils ${version} (the sources in its source map). Don't edit.`,
        "",
        `export const RAYCAST_UTILS_VERSION = ${JSON.stringify(version)};`,
        "",
        "/** Each export of @raycast/utils, with the @raycast/api paths its code uses. */",
        "export const RAYCAST_UTILS_PATHS: Readonly<Record<string, readonly string[]>> = {",
    ];
    for (const [name, paths] of Object.entries(table)) {
        lines.push(`    ${name}: [${paths.map((path) => JSON.stringify(path)).join(", ")}],`);
    }
    lines.push("};", "");
    return lines.join("\n");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const version = (JSON.parse(readFileSync(join(packageDirectory, "package.json"), "utf8")) as { version: string }).version;
    const map = JSON.parse(readFileSync(join(packageDirectory, "dist/module.js.map"), "utf8")) as SourceMap;
    const expected = renderTable(await utilsTable(map), version);
    if (process.argv.includes("--check")) {
        if (readFileSync(outputPath, "utf8") !== expected) {
            console.error("scripts/compat/raycast-utils.generated.ts is out of date: run `npm run generate`");
            process.exit(1);
        }
    } else {
        writeFileSync(outputPath, expected);
    }
}
