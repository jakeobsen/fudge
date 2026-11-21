// Writes the notices of the third-party code and data Fudge.app ships, from their own license files:
//
//   THIRD-PARTY-NOTICES.md                            the repo's copy, as Markdown
//   --text <file>                                     the app's copy (`make app`: Contents/Resources/Third-Party Notices.txt)
//
// Run it with `npm run generate`. `npm run typecheck` runs it with --check, which fails if THIRD-PARTY-NOTICES.md is out
// of date, or if a bundle Fudge ships takes in an npm package that `components` doesn't list.
// Nothing is fetched: the license files come from node_modules and vendor/.

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const runtime = (path: string) => fileURLToPath(new URL(`../${path}`, import.meta.url));
const repo = (path: string) => fileURLToPath(new URL(`../../${path}`, import.meta.url));
const markdownPath = repo("THIRD-PARTY-NOTICES.md");

/** The Node.js the Makefile pins (`NODE_VERSION`) and unpacks into .cache/node, which `make app` bundles with its
 *  LICENSE. The license is the same for every architecture; this Mac's is read when there are several. */
function bundledNode(): { version: string; folder: string } {
    const match = readFileSync(repo("Makefile"), "utf8").match(/^NODE_VERSION\s*:?=\s*(\S+)\s*$/m);
    if (!match) throw new Error("The Makefile pins no NODE_VERSION");
    const version = match[1];
    const cache = repo(".cache/node");
    const names = existsSync(cache) ? readdirSync(cache) : [];
    const name = [`node-v${version}-darwin-${process.arch}`, ...names.sort()].find(
        (candidate) => candidate.startsWith(`node-v${version}-darwin-`) && existsSync(`${cache}/${candidate}/LICENSE`),
    );
    if (!name) throw new Error(`Node.js ${version} isn't in .cache/node: run \`make node\` first`);
    return { version, folder: `${cache}/${name}` };
}

/** One piece of third-party code or data in the app. */
export type Component = {
    name: string;
    /** Where it is in Fudge.app, and what for. */
    where: string;
    /** An npm package in runtime/node_modules, whose version, license and license file are read from it. */
    package?: string;
    /** Else a license file of the repo's, relative to runtime/, or a function giving its full path. */
    licenseFile?: string | (() => string);
    license?: string;
    version?: () => string;
};

/** Everything third-party the app ships. A component bundled into Fudge.app adds its entry here. */
export const components: Component[] = [
    {
        name: "React",
        package: "react",
        where: "Bundled into the extension host (`runtime/worker.js`) and `fudge scan` (`runtime/compat-scan.js`).",
    },
    {
        name: "react-reconciler",
        package: "react-reconciler",
        where: "Bundled into the extension host (`runtime/worker.js`) and `fudge scan` (`runtime/compat-scan.js`).",
    },
    {
        name: "scheduler",
        package: "scheduler",
        where: "Bundled into the extension host (`runtime/worker.js`) and `fudge scan` (`runtime/compat-scan.js`).",
    },
    {
        name: "Node.js",
        licenseFile: () => `${bundledNode().folder}/LICENSE`,
        license: "MIT, and the licenses its LICENSE lists for what Node.js bundles",
        version: () => bundledNode().version,
        where: "The `node` program in `Contents/Helpers`, which runs extensions and `fudge build`, and npm in `Contents/Resources/node/npm`, from Node.js's own distribution. Its license, as Node.js ships it, also covers what Node.js bundles, npm among them, and is beside it as `Contents/Resources/node/LICENSE`.",
    },
    {
        name: "esbuild",
        package: "esbuild",
        where: "The `esbuild` program in `Contents/Helpers`, which `fudge build` compiles extensions with.",
    },
    {
        name: "Unicode emoji data and CLDR annotations",
        licenseFile: "vendor/unicode/LICENSE",
        license: "Unicode-3.0",
        version: () => {
            const match = readFileSync(runtime("vendor/unicode/emoji-test.txt"), "utf8").match(/^# Version: (\S+)$/m);
            if (!match) throw new Error("vendor/unicode/emoji-test.txt names no version");
            return `Emoji ${match[1]}`;
        },
        where: "The emoji, names and keywords of Search Emoji & Symbols (`emoji-extension`), made from Unicode's emoji-test.txt and CLDR's English annotations.",
    },
    {
        name: "Raycast API type definitions",
        licenseFile: "vendor/raycast-api/LICENSE",
        license: "MIT",
        version: () => `@raycast/api ${readFileSync(runtime("vendor/raycast-api/VERSION"), "utf8").trim()}`,
        where: "`runtime/raycast-api.d.ts`, which `fudge scan` reads, with its own notice beside it (`raycast-api.LICENSE`).",
    },
];

type Resolved = { name: string; version: string; license: string; where: string; text: string };

function packageFolder(name: string): string {
    return runtime(`node_modules/${name}`);
}

/** A package's license file: LICENSE, LICENSE.md or LICENSE.txt, in any letter case. */
function packageLicenseFile(folder: string): string {
    const file = readdirSync(folder).find((name) => /^licen[cs]e(\.(md|txt))?$/i.test(name));
    if (!file) throw new Error(`${folder} has no license file`);
    return `${folder}/${file}`;
}

function resolve(component: Component): Resolved {
    if (component.package) {
        const folder = packageFolder(component.package);
        const manifest = JSON.parse(readFileSync(`${folder}/package.json`, "utf8"));
        return {
            name: component.name,
            version: String(manifest.version),
            license: String(manifest.license),
            where: component.where,
            text: readFileSync(packageLicenseFile(folder), "utf8"),
        };
    }
    if (!component.licenseFile || !component.license || !component.version) {
        throw new Error(`${component.name} needs a package, or a license file, a license and a version`);
    }
    return {
        name: component.name,
        version: component.version(),
        license: component.license,
        where: component.where,
        text: readFileSync(
            typeof component.licenseFile === "string" ? runtime(component.licenseFile) : component.licenseFile(),
            "utf8",
        ),
    };
}

/** The license text as the file has it, with its line endings made `\n` and no blank lines at either end. */
function body(text: string): string {
    return text.replace(/\r\n?/g, "\n").replace(/^\n+|\s+$/g, "");
}

/** The heading line of a component: its name and version. */
function title(entry: Resolved): string {
    return /^\d/.test(entry.version) ? `${entry.name} ${entry.version}` : `${entry.name} (${entry.version})`;
}

/** A fence longer than any run of backticks in the text, so no line of it can close the block. */
function fence(text: string): string {
    const longest = Math.max(0, ...[...text.matchAll(/`+/g)].map((match) => match[0].length));
    return "`".repeat(Math.max(3, longest + 1));
}

export function markdown(entries: Resolved[]): string {
    const lines = [
        "# Third-party notices",
        "",
        "Fudge.app includes the third-party code and data below, each under its own license.",
        "Fudge itself is under the GNU Affero General Public License, version 3 or later (see [LICENSE](LICENSE)).",
        "",
        "This file is generated by `runtime/scripts/notices.ts` (`npm run generate`), and the app carries the same text as `Contents/Resources/Third-Party Notices.txt`.",
    ];
    for (const entry of entries) {
        const text = body(entry.text);
        const marks = fence(text);
        lines.push("", `## ${title(entry)}`, "", `${entry.where} License: ${entry.license}.`, "", `${marks}text`, text, marks);
    }
    return `${lines.join("\n")}\n`;
}

export function plainText(entries: Resolved[]): string {
    const rule = "=".repeat(78);
    const parts = [
        "Third-party notices",
        "",
        "Fudge.app includes the third-party code and data below, each under its own license.",
        "Fudge itself is under the GNU Affero General Public License, version 3 or later (LICENSE.txt, beside this file).",
    ];
    for (const entry of entries) {
        parts.push("", rule, title(entry), `${entry.where.replaceAll("`", "")} License: ${entry.license}.`, rule, "", body(entry.text));
    }
    return `${parts.join("\n")}\n`;
}

/** The npm packages each bundle Fudge ships takes in: the host, the worker, `fudge scan`'s script, and the bundled
 *  extensions' commands, built as `npm run build` and `fudge build` build them, without writing anything. */
export async function bundledPackages(): Promise<Set<string>> {
    const common = {
        bundle: true,
        write: false,
        metafile: true,
        platform: "node" as const,
        target: "node22",
        logLevel: "silent" as const,
        define: { "process.env.NODE_ENV": '"production"' },
    };
    const results = [
        await esbuild.build({
            ...common,
            entryPoints: [runtime("src/host.ts"), runtime("src/worker.ts")],
            format: "esm",
            outdir: "out",
        }),
        await esbuild.build({
            ...common,
            entryPoints: [runtime("scripts/compat/fudge-scan.ts")],
            format: "esm",
            outdir: "out",
            external: ["esbuild"],
        }),
    ];
    for (const folder of readdirSync(runtime("."))) {
        if (!folder.endsWith("-extension") || !existsSync(runtime(`${folder}/package.json`))) continue;
        const manifest = JSON.parse(readFileSync(runtime(`${folder}/package.json`), "utf8"));
        const entryPoints = (manifest.commands ?? []).flatMap((command: { name: string }) =>
            ["tsx", "ts", "jsx", "js"]
                .map((extension) => runtime(`${folder}/src/${command.name}.${extension}`))
                .filter((path) => existsSync(path))
                .slice(0, 1),
        );
        results.push(
            await esbuild.build({
                ...common,
                entryPoints,
                format: "cjs",
                jsx: "automatic",
                outdir: "out",
                // ExtensionBuilder.providedModules: the host gives these to every extension.
                external: ["@raycast/api", "react", "react/jsx-runtime", "react/jsx-dev-runtime", "fudge:app"],
            }),
        );
    }
    const packages = new Set<string>();
    for (const result of results) {
        if (!result.metafile) throw new Error("esbuild wrote no metafile");
        for (const input of Object.keys(result.metafile.inputs)) {
            const match = input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)\//);
            if (match) packages.add(match[1]);
        }
    }
    return packages;
}

/** The esbuild binary `make app` copies is its platform package's: it must be the version whose license is listed. */
function checkEsbuildBinary(): void {
    const esbuildVersion = JSON.parse(readFileSync(`${packageFolder("esbuild")}/package.json`, "utf8")).version;
    for (const platform of readdirSync(packageFolder("@esbuild"))) {
        const version = JSON.parse(readFileSync(`${packageFolder(`@esbuild/${platform}`)}/package.json`, "utf8")).version;
        if (version !== esbuildVersion) {
            throw new Error(`@esbuild/${platform} is ${version}, but esbuild is ${esbuildVersion}`);
        }
    }
}

if (import.meta.url.endsWith("/notices.ts") && process.argv[1] === fileURLToPath(import.meta.url)) {
    checkEsbuildBinary();
    const entries = components.map(resolve);
    const textIndex = process.argv.indexOf("--text");
    if (textIndex !== -1) {
        const file = process.argv[textIndex + 1];
        if (!file) throw new Error("--text needs a file");
        writeFileSync(file, plainText(entries));
    } else if (process.argv.includes("--check")) {
        let current = "";
        try {
            current = readFileSync(markdownPath, "utf8");
        } catch {}
        if (current !== markdown(entries)) {
            console.error("THIRD-PARTY-NOTICES.md is out of date: run `npm run generate`.");
            process.exit(1);
        }
        const listed = new Set(components.flatMap((component) => (component.package ? [component.package] : [])));
        const missing = [...(await bundledPackages())].filter((name) => !listed.has(name)).sort();
        if (missing.length > 0) {
            console.error(`Fudge.app bundles ${missing.join(", ")}, which scripts/notices.ts doesn't list.`);
            process.exit(1);
        }
    } else {
        writeFileSync(markdownPath, markdown(entries));
    }
}
