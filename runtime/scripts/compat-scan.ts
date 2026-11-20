// Static compatibility scan of Raycast extensions, such as a checkout of the
// raycast/extensions repo:
//
//   node scripts/compat-scan.ts <folder of extensions> [--json <file>]
//
// Every folder with a package.json and a src/ is an extension. The report, in
// Markdown on stdout, says how many use nothing fudge lacks and ranks the
// missing APIs by how many extensions use them. --json also writes what each
// extension uses and misses. Nothing is built or run.

import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createApiModule } from "../src/api/module.ts";
import { apiName, support, toJavaScript, uses } from "./compat/scan.ts";

/** APIs that depend on Raycast's servers, left out of fudge on purpose. */
const byDesign = [/^AI(\.|$)/, /^BrowserExtension(\.|$)/];

interface Result {
    missing: string[];
    utils: string[];
    unreadable: string[];
}

const args = process.argv.slice(2);
const folder = args.find((arg, index) => !arg.startsWith("--") && args[index - 1] !== "--json");
const jsonIndex = args.indexOf("--json");
const jsonFile = jsonIndex === -1 ? undefined : args[jsonIndex + 1];
if (!folder) {
    console.error("usage: node scripts/compat-scan.ts <folder of extensions> [--json <file>]");
    process.exit(2);
}

const api = createApiModule() as Record<string, unknown>;

function isDirectory(path: string): boolean {
    try {
        return statSync(path).isDirectory();
    } catch {
        return false;
    }
}

function sources(src: string): string[] {
    return (readdirSync(src, { recursive: true }) as string[])
        .filter((file) => /\.(tsx?|jsx?)$/.test(file) && !file.endsWith(".d.ts") && !file.includes("node_modules"))
        .map((file) => join(src, file));
}

async function scan(extension: string): Promise<Result> {
    const paths = new Set<string>();
    const utils = new Set<string>();
    const unreadable: string[] = [];
    for (const file of sources(join(extension, "src"))) {
        try {
            const found = uses(await toJavaScript(readFileSync(file, "utf8"), file));
            for (const path of found.api) paths.add(path);
            for (const name of found.utils) utils.add(name);
        } catch {
            unreadable.push(file.slice(extension.length + 1));
        }
    }
    const missing = new Set<string>();
    for (const path of paths) if (support(api, path) === "missing") missing.add(apiName(path));
    return { missing: [...missing].sort(), utils: [...utils].sort(), unreadable };
}

const names = readdirSync(folder)
    .filter((name) => isDirectory(join(folder, name, "src")) && existsSync(join(folder, name, "package.json")))
    .sort();

const results = new Map<string, Result>();
const batch = 16;
for (let start = 0; start < names.length; start += batch) {
    const slice = names.slice(start, start + batch);
    const scanned = await Promise.all(slice.map((name) => scan(join(folder, name))));
    slice.forEach((name, index) => results.set(name, scanned[index]));
}

const total = results.size;
const percent = (count: number) => `${((100 * count) / Math.max(total, 1)).toFixed(1)}%`;
const isByDesign = (name: string) => byDesign.some((pattern) => pattern.test(name));
const clean = [...results.values()].filter((result) => result.missing.length === 0).length;
const cleanButByDesign = [...results.values()].filter(
    (result) => result.missing.length > 0 && result.missing.every(isByDesign),
).length;
const unreadable = [...results.values()].filter((result) => result.unreadable.length > 0).length;

function ranked(pick: (result: Result) => string[]): [string, string[]][] {
    const users = new Map<string, string[]>();
    for (const [name, result] of results) {
        for (const item of pick(result)) users.set(item, [...(users.get(item) ?? []), name]);
    }
    return [...users].sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]));
}

// Extensions that miss exactly one API, by that API: what implementing it alone would unlock.
const unlocks = new Map<string, number>();
for (const result of results.values()) {
    const gaps = result.missing.filter((name) => !isByDesign(name));
    if (gaps.length === 1) unlocks.set(gaps[0], (unlocks.get(gaps[0]) ?? 0) + 1);
}

const lines: string[] = [
    "# Static compatibility scan",
    "",
    `${total} extensions scanned. Nothing was built or run: this reads their source, so it's an upper bound.`,
    "",
    `- Use nothing fudge lacks: **${clean}** (${percent(clean)})`,
    `- Lack only APIs left out by design (AI, Browser Extension): ${cleanButByDesign} (${percent(cleanButByDesign)})`,
    `- Have a source file that couldn't be read: ${unreadable}`,
    "",
    "## Missing APIs",
    "",
    "Ranked by how many extensions use each. *Alone* counts the extensions it's the only gap for.",
    "",
    "| API | Extensions | Alone | By design |",
    "|---|---:|---:|---|",
];
for (const [name, users] of ranked((result) => result.missing)) {
    lines.push(`| \`${name}\` | ${users.length} | ${unlocks.get(name) ?? 0} | ${isByDesign(name) ? "yes" : ""} |`);
}
lines.push("", "## @raycast/utils", "", "Bundled from each extension's own dependencies. Ranked by use.", "");
lines.push("| Export | Extensions |", "|---|---:|");
for (const [name, users] of ranked((result) => result.utils)) lines.push(`| \`${name}\` | ${users.length} |`);
console.log(lines.join("\n"));

if (jsonFile) writeFileSync(jsonFile, JSON.stringify(Object.fromEntries(results), null, 2));
