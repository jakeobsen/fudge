// The `rust:` imports of an extension, as Raycast's own esbuild plugin handles them on a Mac (`@raycast/api`'s
// `rust-files.js` and `rust-parser.js`). Rust parts are built and run only on Windows, so nothing is compiled: the module
// written in a Rust package's place exports each of its `#[raycast]` functions, and every call rejects with Raycast's
// own message.

import { existsSync, lstatSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import type { Plugin } from "esbuild";

/** What every Rust function answers on a Mac, word for word as in Raycast. */
export const notSupportedOnMacOS = "Rust functions are not supported on macOS";

/** A `#[raycast]` function: its name and its parameters' names. */
export type RustFunction = { name: string; parameters: string[] };

/** Raycast's comment stripping: line comments first, then block comments. */
export function removeComments(source: string): string {
    return source.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
}

/** The `#[raycast]` functions in one `.rs` file, in order, found as Raycast's parser finds them. */
export function parseFunctions(source: string): RustFunction[] {
    const pattern = /#\[raycast\]\s*(?:pub\s+)?(async\s+)?fn\s+(\w+)\s*\(([^)]*)\)\s*(?:->\s*([^{]+?))?\s*\{/g;
    const text = removeComments(source);
    const functions: RustFunction[] = [];
    for (let match = pattern.exec(text); match !== null; match = pattern.exec(text)) {
        functions.push({ name: match[2]!, parameters: parameterNames(match[3]!) });
    }
    return functions;
}

/** Raycast's parameter list: split at the commas outside angle brackets, each part read as `name: Type`. */
function parameterNames(list: string): string[] {
    if (!list.trim()) return [];
    const parts: string[] = [];
    let current = "";
    let depth = 0;
    for (const character of list) {
        if (character === "<") depth++;
        else if (character === ">") depth--;
        else if (character === "," && depth === 0) {
            parts.push(current.trim());
            current = "";
            continue;
        }
        current += character;
    }
    if (current.trim()) parts.push(current.trim());
    return parts.flatMap((part) => {
        const match = part.trim().match(/(\w+)\s*:\s*(.+)/);
        return match ? [match[1]!] : [];
    });
}

/**
 * The `#[raycast]` functions of the Rust package in `folder`: those of every `.rs` file under its `src/`, as Raycast
 * reads them, except that only regular files and folders are read, and no link is followed.
 */
export function packageFunctions(folder: string): RustFunction[] {
    const functions: RustFunction[] = [];
    const visit = (directory: string) => {
        for (const name of readdirSync(directory)) {
            const file = path.join(directory, name);
            const stat = lstatSync(file);
            if (stat.isDirectory()) visit(file);
            else if (stat.isFile() && name.endsWith(".rs")) functions.push(...parseFunctions(readFileSync(file, "utf8")));
        }
    };
    const sources = path.join(folder, "src");
    if (existsSync(sources) && lstatSync(sources).isDirectory()) visit(sources);
    return functions;
}

/**
 * The module Raycast writes for a Rust package, with `runRustFunction` refusing every call: a proxy holding an async
 * function per `#[raycast]` function, each also exported by name, the proxy as the default export, and `RustError`.
 */
export function rustModule(functions: RustFunction[]): string {
    let proxy = "const proxy = {\n";
    for (const { name, parameters } of functions) {
        const names = parameters.join(", ");
        proxy += `  ${name}: async (${names}) => {\n`;
        proxy += `    return await runRustFunction("${name}"${parameters.length > 0 ? `, ${names}` : ""});\n`;
        proxy += "  },\n";
    }
    proxy += "};\n\n";
    for (const { name } of functions) proxy += `export const ${name} = proxy.${name};\n`;
    proxy += "\nexport default proxy;\n";
    return `
async function runRustFunction(command, ...args) {
  return Promise.reject(new Error(${JSON.stringify(notSupportedOnMacOS)}));
}

${proxy}

export class RustError extends Error {
  constructor(message) {
    super(message);
    this.name = "RustError";
  }
}
`;
}

/** Whether `child` is `parent` or inside it, both already resolved. */
function within(child: string, parent: string): boolean {
    const relative = path.relative(parent, child);
    return relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

/**
 * Whether `folder` is the extension's folder or inside it, compared with links resolved, as `checkDestination` compares
 * (esbuild's own paths have them resolved), so a link that points out is refused too. A folder that doesn't exist is
 * compared as written, against the extension's folder as written or resolved.
 */
export function isInsideExtension(folder: string, extension: string): boolean {
    const home = realpathSync.native(extension);
    let resolved: string;
    try {
        resolved = realpathSync.native(folder);
    } catch {
        const written = path.resolve(folder);
        return within(written, path.resolve(extension)) || within(written, home);
    }
    return within(resolved, home);
}

/**
 * The `rust:` plugin for the extension in `extension` (the folder holding its `package.json`). An import resolves
 * against the importing file's folder, as in Raycast; the folder must be inside the extension's and hold a
 * `Cargo.toml`, which is checked here, so the error points at the import.
 */
export function rustPlugin(extension: string): Plugin {
    return {
        name: "rust",
        setup(build) {
            build.onResolve({ filter: /^rust:/ }, (args) => {
                const folder = path.join(args.resolveDir, args.path.replace(/^rust:/, ""));
                if (!isInsideExtension(folder, extension)) {
                    return { errors: [{ text: `the Rust package "${args.path}" is outside the extension's folder` }] };
                }
                if (!existsSync(path.join(folder, "Cargo.toml"))) {
                    return {
                        errors: [
                            {
                                text: `failed to import Rust package from "${folder}". Make sure you reference the folder that includes the 'Cargo.toml' file`,
                            },
                        ],
                    };
                }
                return { path: folder, namespace: "rust", sideEffects: false };
            });
            build.onLoad({ filter: /.*/, namespace: "rust" }, (args) => {
                try {
                    return { contents: rustModule(packageFunctions(args.path)), loader: "js" };
                } catch (error) {
                    return { errors: [{ text: `failed to parse Rust source files: ${(error as Error).message}` }] };
                }
            });
        },
    };
}
