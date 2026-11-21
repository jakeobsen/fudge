// Static compatibility scan of Raycast extensions, such as a checkout of the
// raycast/extensions repo:
//
//   node scripts/compat-scan.ts <folder of extensions> [--json <file>]
//
// Every folder with a package.json and a src/ is an extension. The report, in
// Markdown on stdout, says how many use nothing fudge lacks and ranks the
// missing APIs by how many extensions use them. --json also writes what each
// extension misses, and of what kind. Nothing is built or run.

import { existsSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createApiModule } from "../src/api/module.ts";
import { byDesign, category, scanExtension, type Result } from "./compat/extension.ts";
import { RAYCAST_UTILS_PATHS, RAYCAST_UTILS_VERSION } from "./compat/raycast-utils.generated.ts";
import { support, type Gap, type GapKind } from "./compat/scan.ts";
import { raycastDeclarations, vendoredTypes } from "./raycast-types.ts";

const args = process.argv.slice(2);
const folder = args.find((arg, index) => !arg.startsWith("--") && args[index - 1] !== "--json");
const jsonIndex = args.indexOf("--json");
const jsonFile = jsonIndex === -1 ? undefined : args[jsonIndex + 1];
if (!folder) {
    console.error("usage: node scripts/compat-scan.ts <folder of extensions> [--json <file>]");
    process.exit(2);
}

const api = createApiModule() as Record<string, unknown>;
const declared = raycastDeclarations(vendoredTypes());

function isDirectory(path: string): boolean {
    try {
        return statSync(path).isDirectory();
    } catch {
        return false;
    }
}

const scan = (extension: string) => scanExtension(extension, { api, declared });

const names = readdirSync(folder)
    .filter((name) => isDirectory(join(folder, name, "src")) && existsSync(join(folder, name, "package.json")))
    .sort();

const results = new Map<string, Result>();
const batch = 16;
for (let start = 0; start < names.length; start += batch) {
    const slice = names.slice(start, start + batch);
    const scanned = await Promise.all(slice.map((name) => scan(join(folder, name))));
    slice.forEach((name, index) => results.set(name, scanned[index]!));
}

const total = results.size;
const percent = (count: number) => `${((100 * count) / Math.max(total, 1)).toFixed(1)}%`;
const all = [...results.values()];
const clean = all.filter((result) => result.gaps.length === 0).length;
const onlyByDesign = all.filter((result) => result.gaps.length > 0 && result.gaps.every((gap) => category(gap)));
const rest = total - clean - onlyByDesign.length;
const perCategory = Object.keys(byDesign).map((name) => {
    const count = onlyByDesign.filter((result) => result.gaps.some((gap) => category(gap) === name)).length;
    return `${name} ${count}`;
});
const unreadable = all.filter((result) => result.unreadable.length > 0).length;

/** Items ranked by how many extensions have them, then by name. */
function ranked<T>(pick: (result: Result) => T[], key: (item: T) => string): [T, string[]][] {
    const users = new Map<string, { item: T; names: string[] }>();
    for (const [name, result] of results) {
        for (const item of pick(result)) {
            const entry = users.get(key(item)) ?? { item, names: [] };
            entry.names.push(name);
            users.set(key(item), entry);
        }
    }
    return [...users.values()]
        .map(({ item, names }): [T, string[]] => [item, names])
        .sort((a, b) => b[1].length - a[1].length || key(a[0]).localeCompare(key(b[0])));
}

const gapKey = (gap: Gap) => `${gap.api} ${gap.kind}`;

// Extensions with exactly one gap that isn't by design, by that gap: what fixing it alone would unlock.
const unlocks = new Map<string, number>();
for (const result of all) {
    const open = result.gaps.filter((gap) => !category(gap));
    if (open.length === 1) unlocks.set(gapKey(open[0]!), (unlocks.get(gapKey(open[0]!)) ?? 0) + 1);
}

const kinds: Record<GapKind, string> = {
    missing: "Fudge doesn't provide it",
    "render-but-fail": "it renders, and fails when used",
    "not-drawn": "the extension host renders it, but the app can't draw it",
    "via @raycast/utils": "only needed through a @raycast/utils export the extension uses",
};

const lines: string[] = [
    "# Static compatibility scan",
    "",
    `${total} extensions scanned. Nothing was built or run: this reads their source, so it's an upper bound.`,
    "",
    `- No gaps: **${clean}** (${percent(clean)})`,
    `- Only gaps left out by design: ${onlyByDesign.length} (${percent(onlyByDesign.length)}): ${perCategory.join(", ")}`,
    `- The rest: ${rest} (${percent(rest)})`,
    `- Have a source file that couldn't be read: ${unreadable}`,
    "",
    "By design: AI and the Browser Extension depend on Raycast's servers, and OAuth is left out by decision D-50. " +
        "An extension that lacks more than one of these counts under each.",
    "",
    "## Missing APIs",
    "",
    "Ranked by how many extensions use each. *Alone* counts the extensions it's the only gap for, apart from " +
        "by-design ones. An API reached in two ways has a row for each; an extension that uses it directly counts " +
        "only there.",
    "",
    ...Object.entries(kinds).map(([kind, meaning]) => `- \`${kind}\`: ${meaning}`),
    "",
    "| API | Kind | Extensions | Alone | By design |",
    "|---|---|---:|---:|---|",
];
for (const [gap, users] of ranked((result) => result.gaps, gapKey)) {
    const design = category(gap);
    lines.push(`| \`${gap.api}\` | ${gap.kind} | ${users.length} | ${unlocks.get(gapKey(gap)) ?? 0} | ${design ?? ""} |`);
}

lines.push(
    "",
    "## @raycast/utils",
    "",
    `Bundled from each extension's own dependencies. What each export needs comes from @raycast/utils ` +
        `${RAYCAST_UTILS_VERSION} (\`scripts/compat/raycast-utils.generated.ts\`). Ranked by use.`,
    "",
    "| Export | Extensions | Brings gaps |",
    "|---|---:|---|",
);
for (const [name, users] of ranked((result) => result.utils, (name) => name)) {
    const brought = (RAYCAST_UTILS_PATHS[name] ?? []).filter((path) => {
        const result = support(api, path, declared);
        return result !== "implemented" && result !== "not-raycast";
    });
    lines.push(`| \`${name}\` | ${users.length} | ${brought.map((path) => `\`${path}\``).join(", ")} |`);
}

const notRaycast = ranked((result) => result.notRaycast, (path) => path);
const shown = 30;
lines.push(
    "",
    "## Not Raycast API",
    "",
    "Paths through `@raycast/api` imports that Raycast's types don't declare: members it doesn't have " +
        "(`Color.Gray`), test mocks outside test files, and members of the values themselves. They aren't gaps. " +
        `${notRaycast.length} paths in ${all.filter((result) => result.notRaycast.length > 0).length} extensions; ` +
        `the ${Math.min(shown, notRaycast.length)} most used:`,
    "",
    "| Path | Extensions |",
    "|---|---:|",
);
for (const [path, users] of notRaycast.slice(0, shown)) lines.push(`| \`${path}\` | ${users.length} |`);
console.log(lines.join("\n"));

if (jsonFile) writeFileSync(jsonFile, JSON.stringify(Object.fromEntries(results), null, 2));
