// The package-source check: the store installs an extension only if every npm package it uses comes from
// registry.npmjs.org. Anything that could point npm elsewhere is refused before installing.
import { readdir } from "node:fs/promises";
import path from "node:path";
import { maxLockfileBytes, maxManifestBytes, readRegularFile } from "./files.ts";

export const registry = "https://registry.npmjs.org/";

const dependencySections = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"];

/**
 * Why `spec` isn't a registry version, or undefined when it is: a range (`^1.2.0`, `>=1 <2`, `*`, `1.x`, `""`), a
 * dist-tag (`latest`, `next`) or an `npm:` alias of one (`npm:other@^1`). Git, GitHub, URLs, `file:`, `link:`,
 * `workspace:`, `user/repo` shorthands and tarball names (`evil.tgz`, which npm reads as a file) all name another
 * source.
 */
export function specProblem(name: string, spec: unknown): string | undefined {
    if (typeof spec !== "string") return `${name}'s version isn't a string`;
    const alias = /^npm:((?:@[\w.-]+\/)?[\w.-]+)(?:@(.*))?$/.exec(spec);
    if (alias) return alias[2] === undefined ? undefined : specProblem(name, alias[2]);
    if (spec.includes(":") || spec.includes("/") || spec.includes("\\") || spec.startsWith("."))
        return `${name} comes from "${spec}", not the npm registry`;
    if (isTarball(spec)) return `${name} comes from the file "${spec}", not the npm registry`;
    if (!/^[\w.*^~<>=|+\- ]*$/.test(spec)) return `${name}'s version "${spec}" isn't a registry version`;
    return undefined;
}

const isTarball = (spec: string) => /\.(?:tgz|tar|tar\.gz)$/i.test(spec.trim());

/** The first problem in a `package.json`'s dependency sections and `overrides`. */
export function packageJSONProblem(manifest: unknown): string | undefined {
    if (typeof manifest !== "object" || manifest === null) return "package.json isn't a JSON object";
    const object = manifest as Record<string, unknown>;
    for (const section of dependencySections) {
        const dependencies = object[section];
        if (dependencies === undefined) continue;
        if (typeof dependencies !== "object" || dependencies === null) return `package.json's ${section} isn't an object`;
        for (const [name, spec] of Object.entries(dependencies)) {
            const problem = specProblem(name, spec);
            if (problem) return problem;
        }
    }
    return overridesProblem(object.overrides);
}

/** `overrides` can point any package anywhere: its values are checked like specs (`$name` refers to a dependency). */
function overridesProblem(overrides: unknown): string | undefined {
    if (overrides === undefined) return undefined;
    if (typeof overrides !== "object" || overrides === null) return "package.json's overrides isn't an object";
    for (const [name, value] of Object.entries(overrides)) {
        const problem =
            typeof value === "object" && value !== null
                ? overridesProblem(value)
                : typeof value === "string" && value.startsWith("$")
                  ? undefined
                  : specProblem(name, value);
        if (problem) return problem;
    }
    return undefined;
}

function entryProblem(name: string, entry: unknown): string | undefined {
    if (typeof entry !== "object" || entry === null) return undefined;
    const { resolved, link, version } = entry as Record<string, unknown>;
    if (link === true) return `${name} is linked from a local folder`;
    if (typeof resolved === "string" && !resolved.startsWith(registry))
        return `${name} is downloaded from ${resolved}, not the npm registry`;
    if (
        typeof version === "string" &&
        !version.startsWith("npm:") &&
        (version.includes(":") || version.includes("/") || isTarball(version))
    )
        return `${name} comes from "${version}", not the npm registry`;
    return entrySpecsProblem(name, entry as Record<string, unknown>);
}

/**
 * The first problem in a lockfile entry's own dependency specs, checked like `package.json`'s: a version 2 or 3
 * entry lists them in the dependency sections, a version 1 entry in `requires`. A version 1 entry's `dependencies`
 * also holds its nested entries, which are walked as entries; any other value there is a spec.
 */
function entrySpecsProblem(name: string, entry: Record<string, unknown>): string | undefined {
    for (const section of [...dependencySections, "requires"]) {
        const specs = entry[section];
        if (typeof specs !== "object" || specs === null) continue;
        for (const [dependency, spec] of Object.entries(specs)) {
            if (typeof spec === "object" && spec !== null) continue;
            const problem = specProblem(dependency, spec);
            if (problem) return `${name}: ${problem}`;
        }
    }
    return undefined;
}

/**
 * The first problem in a lockfile: any `resolved` URL off the registry, a `link: true` entry, a `file:` (or git, or
 * URL) version, or an entry whose own dependency specs aren't registry versions. Version 2 and 3 lockfiles list
 * `packages`; version 1 nests `dependencies`, which are walked recursively. A version 2 file has both, and both are
 * checked.
 */
export function lockfileProblem(lockfile: unknown): string | undefined {
    if (typeof lockfile !== "object" || lockfile === null) return "the lockfile isn't a JSON object";
    const object = lockfile as Record<string, unknown>;
    if (typeof object.packages === "object" && object.packages !== null) {
        for (const [key, entry] of Object.entries(object.packages)) {
            const problem = entryProblem(key || "the extension", entry);
            if (problem) return problem;
        }
    }
    const walk = (dependencies: unknown): string | undefined => {
        if (typeof dependencies !== "object" || dependencies === null) return undefined;
        for (const [name, entry] of Object.entries(dependencies)) {
            const problem =
                entryProblem(name, entry) ??
                (typeof entry === "object" && entry !== null
                    ? walk((entry as Record<string, unknown>).dependencies)
                    : undefined);
            if (problem) return problem;
        }
        return undefined;
    };
    return walk(object.dependencies);
}

/** Every file's path under `folder`, relative to it. */
async function files(folder: string, prefix = ""): Promise<string[]> {
    const entries = await readdir(path.join(folder, prefix), { withFileTypes: true });
    const nested = await Promise.all(
        entries.map((entry) => {
            const relative = path.join(prefix, entry.name);
            return entry.isDirectory() ? files(folder, relative) : Promise.resolve([relative]);
        }),
    );
    return nested.flat();
}

/** Paths in `files` that differ only by case: on APFS they name one file, which a check could read either way. */
export function caseClash(files: string[]): string[] | undefined {
    const byName = new Map<string, string[]>();
    for (const file of files) byName.set(file.toLowerCase(), [...(byName.get(file.toLowerCase()) ?? []), file]);
    return [...byName.values()].find((names) => names.length > 1);
}

/**
 * Why the extension in `folder` may get packages from somewhere other than the npm registry, or undefined when it
 * can't: an `.npmrc` anywhere in it, a lockfile entry off the registry, or a dependency spec that isn't a registry
 * version. Names are compared ignoring case, as APFS and the build (which copies these files by name) do, and two
 * names that differ only by case are refused.
 */
export async function sourceProblem(folder: string): Promise<string | undefined> {
    const all = await files(folder);
    const clash = caseClash(all);
    if (clash) return `It has files whose names differ only by case (${clash.join(", ")})`;
    const named = (name: string) => all.find((file) => file.toLowerCase() === name);
    const npmrc = all.find((file) => path.basename(file).toLowerCase() === ".npmrc");
    if (npmrc) return `It has an .npmrc (${npmrc}), which can point npm at another registry`;
    // Read only as regular files (`readRegularFile`): a link or something too big is refused, never followed.
    const read = async (file: string, maxBytes: number): Promise<{ json: unknown } | { problem: string }> => {
        let text: string;
        try {
            text = await readRegularFile(path.join(folder, file), maxBytes);
        } catch (error) {
            return (error as NodeJS.ErrnoException).code === "ENOENT"
                ? { problem: `It has no ${file}` }
                : { problem: `Its ${file} isn't a regular file of at most ${maxBytes / 1024 / 1024} MB` };
        }
        try {
            return { json: JSON.parse(text) };
        } catch {
            return { json: null };
        }
    };
    const manifest = await read(named("package.json") ?? "package.json", maxManifestBytes);
    if ("problem" in manifest) return manifest.problem;
    const manifestProblem = packageJSONProblem(manifest.json);
    if (manifestProblem) return manifestProblem;
    for (const lockfile of ["package-lock.json", "npm-shrinkwrap.json"]) {
        const file = named(lockfile);
        if (!file) continue;
        const contents = await read(file, maxLockfileBytes);
        if ("problem" in contents) return contents.problem;
        const problem = lockfileProblem(contents.json);
        if (problem) return `${file}: ${problem}`;
    }
    return undefined;
}
