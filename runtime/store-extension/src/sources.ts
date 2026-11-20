// The package-source check: the store installs an extension only if every npm package it uses comes from
// registry.npmjs.org. Anything that could point npm elsewhere is refused before installing.
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

export const registry = "https://registry.npmjs.org/";

const dependencySections = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"];

/**
 * Why `spec` isn't a registry version, or undefined when it is: a range (`^1.2.0`, `>=1 <2`, `*`, `1.x`, `""`), a
 * dist-tag (`latest`, `next`) or an `npm:` alias of one (`npm:other@^1`). Git, GitHub, URLs, `file:`, `link:`,
 * `workspace:` and `user/repo` shorthands all name another source.
 */
export function specProblem(name: string, spec: unknown): string | undefined {
    if (typeof spec !== "string") return `${name}'s version isn't a string`;
    const alias = /^npm:((?:@[\w.-]+\/)?[\w.-]+)(?:@(.*))?$/.exec(spec);
    if (alias) return alias[2] === undefined ? undefined : specProblem(name, alias[2]);
    if (spec.includes(":") || spec.includes("/") || spec.includes("\\") || spec.startsWith("."))
        return `${name} comes from "${spec}", not the npm registry`;
    if (!/^[\w.*^~<>=|+\- ]*$/.test(spec)) return `${name}'s version "${spec}" isn't a registry version`;
    return undefined;
}

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
    if (typeof version === "string" && version.includes(":") && !version.startsWith("npm:"))
        return `${name} comes from "${version}", not the npm registry`;
    return undefined;
}

/**
 * The first problem in a lockfile: any `resolved` URL off the registry, a `link: true` entry, or a `file:` (or git,
 * or URL) version. Version 2 and 3 lockfiles list `packages`; version 1 nests `dependencies`, which are walked
 * recursively. A version 2 file has both, and both are checked.
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

/**
 * Why the extension in `folder` may get packages from somewhere other than the npm registry, or undefined when it
 * can't: an `.npmrc` anywhere in it, a lockfile entry off the registry, or a dependency spec that isn't a registry
 * version.
 */
export async function sourceProblem(folder: string): Promise<string | undefined> {
    const all = await files(folder);
    const npmrc = all.find((file) => path.basename(file) === ".npmrc");
    if (npmrc) return `It has an .npmrc (${npmrc}), which can point npm at another registry`;
    const read = async (file: string): Promise<unknown> => {
        const text = await readFile(path.join(folder, file), "utf8");
        try {
            return JSON.parse(text);
        } catch {
            return null;
        }
    };
    const manifestProblem = packageJSONProblem(await read("package.json"));
    if (manifestProblem) return manifestProblem;
    for (const lockfile of ["package-lock.json", "npm-shrinkwrap.json"]) {
        if (!all.includes(lockfile)) continue;
        const problem = lockfileProblem(await read(lockfile));
        if (problem) return `${lockfile}: ${problem}`;
    }
    return undefined;
}
