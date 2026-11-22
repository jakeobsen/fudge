// The `swift:` imports of an extension (SPEC-145 §2): a Swift package whose `@raycast` functions the extension calls.
// Raycast builds them before they reach its store; Fudge builds them on the user's Mac, with Apple's Command Line Tools
// (`fudge build --swift-parts build`), or installs without them (`--swift-parts leave-out`), whose functions then
// refuse every call. Without either, a `swift:` import stops the build, asking for one.
//
// The module written in a package's place is Raycast's: `runSwiftFunction` (`@raycast/api` 2.13.1's `swift-files.js`,
// in Fudge's own code, without its Windows check), the `raycast.js` the package's own plugin wrote, and `SwiftError`.

import { spawn, type ChildProcess } from "node:child_process";
import {
    chmodSync,
    copyFileSync,
    cpSync,
    existsSync,
    lstatSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    readdirSync,
    statSync,
    writeFileSync,
} from "node:fs";
import path from "node:path";
import type { Plugin } from "esbuild";
import { isInsideExtension } from "./rust.ts";

/** What `fudge build` was told to do with a part written in Swift; none means it wasn't told. */
export type SwiftPartsMode = "build" | "leave-out";

/** What the bundling script gets for Swift parts, from `ExtensionBuilder`. */
export type SwiftRequest = {
    /** `--swift-parts`, or none. */
    mode?: SwiftPartsMode;
    /** The tools' `swift` (`CommandLineTools.resolve`), or none when they aren't set up. Run with `DEVELOPER_DIR`
     * already in the environment. */
    swift?: string;
    /** SwiftPM's shared cache (`--cache-path`). */
    cache: string;
    /** Where each package is copied and built, never the extension's own folder. */
    scratch: string;
    /** Where each built program goes, by its package folder's name: `ExtensionBuilder` puts them in the install's
     * `assets/compiled_raycast_swift/`. */
    binaries: string;
    /** A file the script writes: the mode each `swift:` package was bundled with, so the install remembers it. */
    report: string;
};

/** Without `--swift-parts`. */
export const chooseSwiftParts =
    "this extension has a part written in Swift: choose --swift-parts build or --swift-parts leave-out";
/** `--swift-parts build` with no tools. */
export const toolsNotSetUp = "Apple's Command Line Tools aren't set up. Set them up in Settings → Development.";
/** A build of the package that failed, before SwiftPM's output. */
export const didntBuild = "the part written in Swift didn't build";
/** What every function of a part left out answers. */
export const leftOut =
    "This extension's part written in Swift wasn't installed. Reinstall it with Apple's Command Line Tools set up in Settings → Development.";

/** Raycast's messages about the package, word for word. */
export const packageMessages = {
    noPackage: (folder: string) =>
        `failed to import Swift package from "${folder}". Make sure you reference the folder that includes the 'Package.swift' file`,
    noName: "failed to read the schema name from swift package",
    moreThanOne: "failed to parse the swift package: expected one executable target but found more than one",
    none: "failed to parse the swift package: expected one executable target but found none",
};

/** Raycast's comment stripping, as for Rust: line comments first, then block comments. */
export function removeComments(source: string): string {
    return source.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
}

/** Swift's declaration modifiers, which may stand between `@raycast` and `func`. */
const modifiers = [
    "public", "private", "fileprivate", "internal", "package", "open", "static", "class", "final", "nonisolated",
    "override", "mutating", "nonmutating", "dynamic", "required", "convenience", "distributed", "consuming", "borrowing",
];
/** `@raycast`, then any whitespace (newlines too), other attributes (`@MainActor`, `@available(…)`) and modifiers, then
 * `func <name>`. */
const raycastFunction = new RegExp(
    String.raw`@raycast\b(?:\s+(?:@\w+(?:\([^)]*\))?|(?:${modifiers.join("|")})\b))*\s+func\s+(\w+)`,
    "g",
);
/** Raycast's older form. */
const exportFunction = /#exportFunction\((\w+)\)/g;

/** The functions one Swift file exports, in order, comments stripped. */
export function swiftFunctions(source: string): string[] {
    const text = removeComments(source);
    const names: string[] = [];
    for (const pattern of [raycastFunction, exportFunction]) {
        for (const match of text.matchAll(pattern)) names.push(match[1]!);
    }
    return names;
}

/**
 * The functions a Swift package exports: those of every `.swift` file in its folder outside `.build`, wherever its
 * targets keep them (`path: "src"`), each once. Only regular files and folders are read, and no link is followed.
 */
export function packageFunctions(folder: string): string[] {
    const names = new Set<string>();
    const visit = (directory: string) => {
        for (const name of readdirSync(directory).sort()) {
            const file = path.join(directory, name);
            const stat = lstatSync(file);
            if (stat.isDirectory()) {
                if (name !== ".build") visit(file);
            } else if (stat.isFile() && name.endsWith(".swift")) {
                for (const found of swiftFunctions(readFileSync(file, "utf8"))) names.add(found);
            }
        }
    };
    visit(folder);
    return [...names];
}

/**
 * Raycast's module for a package: `runSwiftFunction`, which runs the program at `compiled_raycast_swift/<folder name>`
 * in the extension's assets, then `body` (the functions), then `SwiftError`. Raycast's own, apart from its refusal on
 * Windows, which never runs here.
 */
export function swiftModule(folderName: string, body: string): string {
    return `
import { environment } from "@raycast/api";
import { join } from "path";
import { chmod } from "fs/promises";
import { spawn } from "child_process";

async function runSwiftFunction(command, ...args) {
  const swiftPath = join(environment.assetsPath, "compiled_raycast_swift", ${JSON.stringify(folderName)});
  await chmod(swiftPath, "755");

  return new Promise((resolve, reject) => {
    const commandArgs = [command];
    for (const arg of args) {
      try {
        commandArgs.push(JSON.stringify(arg, (k, v) => v === undefined ? null : v));
      } catch (err) {
        reject(new SwiftError("Failed to serialize input to JSON: " + err.message));
        return;
      }
    }
    const child = spawn(swiftPath, commandArgs);
    const stdout = [];
    const stderr = [];

    child.stdout?.on("data", (data) => {
      stdout.push(data.toString());
    });
    child.stderr?.on("data", (data) => {
      stderr.push(data.toString());
    });

    child.on("exit", (code) => {
      if (code === 0) {
        try {
          const result = stdout.join("").trim();
          if (result.length != 0) {
            resolve(JSON.parse(result));
          } else {
            resolve(null);
          }
        } catch (err) {
          const error = new SwiftError("Failed to deserialize result from JSON: " + err.message);
          error.stdout = stdout.join("").trim();
          error.stderr = stderr.join("").trim();
          reject(error);
        }
      } else {
        const error = new SwiftError(stderr.join("").trim() || stdout.join("").trim() || "Could not get any data");
        error.stdout = stdout.join("").trim();
        error.stderr = stderr.join("").trim();
        reject(error);
      }
    });

    child.on("error", (error) => {
      reject(error);
    });
  });
}

${body}

export class SwiftError extends Error {
  constructor(message) {
    super(message);
    this.name = "SwiftError";
  }
}
`;
}

/** Each name as `raycast.js` writes a function, for a package whose build wrote none. */
export function runnerFunctions(names: string[]): string {
    return names
        .map((name) => `export async function ${name}(...args) {\n  return await runSwiftFunction("${name}", ...args)\n}`)
        .join("\n\n");
}

/** The module for a package left out: the same names, each refusing with `leftOut`, and `SwiftError`. */
export function leftOutModule(names: string[]): string {
    const functions = names
        .map((name) => `export async function ${name}(...args) {\n  throw new SwiftError(${JSON.stringify(leftOut)});\n}`)
        .join("\n\n");
    return `${functions}

export class SwiftError extends Error {
  constructor(message) {
    super(message);
    this.name = "SwiftError";
  }
}
`;
}

/** The programs the script has started and not yet seen end, which a signal ending it ends too. */
const running = new Set<ChildProcess>();
let forwarding = false;

/** How long a stopped script waits for `swift` to cancel its jobs: under the 1 s `ChildProcesses.endAll` gives the
 * script's process group before SIGKILL. */
const cancelWait = 800;

/**
 * On SIGTERM or SIGINT, cancels every `swift` running, then ends with the status the signal would give.
 *
 * SwiftPM starts each compile job (`swift-driver`, `swift-frontend`) in a process group of its own, so a signal to
 * `swift` alone, or to this script's group, never reaches them, and `swift build` dies at once on SIGTERM. SIGINT is
 * what makes SwiftPM cancel its jobs, so each `swift` runs in a process group of its own (`detached`), out of reach of
 * the SIGKILL that may follow, and gets SIGINT there. The script waits up to `cancelWait` for them to end.
 */
function forwardSignals(): void {
    if (forwarding) return;
    forwarding = true;
    for (const [signal, number] of [
        ["SIGTERM", 15],
        ["SIGINT", 2],
    ] as const) {
        process.on(signal, () => {
            for (const child of running) cancel(child);
            const end = Date.now() + cancelWait;
            const ended = () => [...running].every((child) => child.exitCode !== null || child.signalCode !== null);
            const check = () => (ended() || Date.now() >= end ? process.exit(128 + number) : setTimeout(check, 20));
            check();
        });
    }
}

/** SIGINT to `child`'s process group, which SwiftPM answers by cancelling its jobs. */
function cancel(child: ChildProcess): void {
    if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
    try {
        process.kill(-child.pid, "SIGINT");
    } catch {
        // The group is gone already.
    }
}

/** What a program printed, and how it ended. */
type Ran = { code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string };

/** Runs `swift` with `args` in `directory`, with this script's environment, keeping its output. */
function runSwift(swift: string, args: string[], directory: string): Promise<Ran> {
    forwardSignals();
    return new Promise((resolve, reject) => {
        // In a process group of its own, so stopping the build cancels SwiftPM's jobs (`forwardSignals`).
        const child = spawn(swift, args, { cwd: directory, stdio: ["ignore", "pipe", "pipe"], detached: true });
        running.add(child);
        const stdout: Buffer[] = [];
        const stderr: Buffer[] = [];
        child.stdout!.on("data", (data: Buffer) => stdout.push(data));
        child.stderr!.on("data", (data: Buffer) => stderr.push(data));
        child.on("error", (error) => {
            running.delete(child);
            reject(error);
        });
        child.on("close", (code, signal) => {
            running.delete(child);
            resolve({
                code,
                signal,
                stdout: Buffer.concat(stdout).toString("utf8"),
                stderr: Buffer.concat(stderr).toString("utf8"),
            });
        });
    });
}

/** What a failed run printed, stdout and stderr together, for the error after `didntBuild`. */
function output(ran: Ran): string {
    return [ran.stdout, ran.stderr]
        .map((part) => part.trim())
        .filter((part) => part.length > 0)
        .join("\n");
}

class SwiftBuildError extends Error {}

/** `swift package dump-package`'s executable target, exactly one, as Raycast requires. */
export function executableTarget(dump: string): string {
    let manifest: { name?: unknown; targets?: { name?: unknown; type?: unknown }[] };
    try {
        manifest = JSON.parse(dump);
    } catch (error) {
        throw new SwiftBuildError(`failed to parse the swift package: ${String(error)}`);
    }
    if (typeof manifest.name !== "string" || !manifest.name) throw new SwiftBuildError(packageMessages.noName);
    const executables = (Array.isArray(manifest.targets) ? manifest.targets : []).filter(
        (target) => target?.type === "executable" && typeof target.name === "string",
    );
    if (executables.length > 1) throw new SwiftBuildError(packageMessages.moreThanOne);
    if (executables.length === 0) throw new SwiftBuildError(packageMessages.none);
    return executables[0]!.name as string;
}

/** The `raycast.js` the package's plugin wrote: SwiftPM's place for it, else one found in `.build` for that target
 * (Xcode's Swift lays `.build` out differently), else none. */
export function generatedFunctions(copy: string, target: string): string | undefined {
    const identity = path.basename(copy).toLowerCase();
    const plugin = "RaycastTypeScriptPlugin";
    const usual = path.join(copy, ".build", "plugins", "outputs", identity, target, "destination", plugin, "raycast.js");
    if (existsSync(usual)) return readFileSync(usual, "utf8");
    const found: string[] = [];
    const visit = (directory: string, depth: number) => {
        if (depth > 12) return;
        let names: string[];
        try {
            names = readdirSync(directory).sort();
        } catch {
            return;
        }
        for (const name of names) {
            const file = path.join(directory, name);
            const stat = lstatSync(file);
            if (stat.isDirectory()) visit(file, depth + 1);
            else if (
                name === "raycast.js" &&
                path.basename(directory) === plugin &&
                file.split(path.sep).includes(target)
            ) {
                found.push(file);
            }
        }
    };
    visit(path.join(copy, ".build"), 0);
    return found.length > 0 ? readFileSync(found[0]!, "utf8") : undefined;
}

/**
 * Builds the package in `folder` (SPEC-145 §2): copies it into the scratch folder, keeping its name, builds its one
 * executable target there with SwiftPM and the shared cache, copies the program to `binaries/<folder name>` with mode
 * 755, and returns the module.
 */
export async function buildPackage(folder: string, request: SwiftRequest & { swift: string }): Promise<string> {
    const name = path.basename(folder);
    // A folder of its own for each package, so two packages with one folder name never share a copy.
    mkdirSync(request.scratch, { recursive: true });
    const copy = path.join(mkdtempSync(path.join(request.scratch, "package-")), name);
    cpSync(folder, copy, {
        recursive: true,
        filter: (source) => path.basename(source) !== ".build" || source === folder,
    });
    const swift = request.swift;
    const dump = await runSwift(swift, ["package", "dump-package"], copy);
    if (dump.code !== 0) throw new SwiftBuildError(`${didntBuild}\n${output(dump)}`);
    const target = executableTarget(dump.stdout);
    const build = ["build", "-c", "release", "--product", target, "--cache-path", request.cache];
    const built = await runSwift(swift, build, copy);
    if (built.code !== 0) throw new SwiftBuildError(`${didntBuild}\n${output(built)}`);
    const where = await runSwift(swift, [...build, "--show-bin-path"], copy);
    if (where.code !== 0) throw new SwiftBuildError(`${didntBuild}\n${output(where)}`);
    const program = path.join(where.stdout.trim(), target);
    let executable = false;
    try {
        const stat = statSync(program);
        executable = stat.isFile() && (stat.mode & 0o111) !== 0;
    } catch {
        executable = false;
    }
    if (!executable) throw new SwiftBuildError(`${didntBuild}\nthe build wrote no program at ${program}`);
    mkdirSync(request.binaries, { recursive: true });
    const destination = path.join(request.binaries, name);
    copyFileSync(program, destination);
    chmodSync(destination, 0o755);
    const functions = generatedFunctions(copy, target) ?? runnerFunctions(packageFunctions(folder));
    return swiftModule(name, functions);
}

/** The modes the packages were bundled with, by folder, for `request.report`. */
function remember(request: SwiftRequest, folder: string, mode: SwiftPartsMode): void {
    let seen: Record<string, SwiftPartsMode> = {};
    try {
        seen = JSON.parse(readFileSync(request.report, "utf8"));
    } catch {
        seen = {};
    }
    seen[folder] = mode;
    mkdirSync(path.dirname(request.report), { recursive: true });
    writeFileSync(request.report, JSON.stringify(seen));
}

/**
 * The `swift:` plugin for the extension in `extension` (the folder holding its `package.json`). An import resolves
 * against the importing file's folder, as in Raycast; the folder must be inside the extension's and hold a
 * `Package.swift`, which is checked here, so the error points at the import. Then the mode decides: none stops the
 * build asking for one, `build` needs the tools, and `leave-out` runs nothing.
 */
export function swiftPlugin(extension: string, request?: SwiftRequest): Plugin {
    return {
        name: "swift",
        setup(build) {
            build.onResolve({ filter: /^swift:/ }, (args) => {
                const folder = path.join(args.resolveDir, args.path.replace(/^swift:/, ""));
                if (!isInsideExtension(folder, extension)) {
                    return { errors: [{ text: `the Swift package "${args.path}" is outside the extension's folder` }] };
                }
                if (!existsSync(path.join(folder, "Package.swift"))) {
                    return { errors: [{ text: packageMessages.noPackage(folder) }] };
                }
                if (!request?.mode) return { errors: [{ text: chooseSwiftParts }] };
                if (request.mode === "build" && !request.swift) return { errors: [{ text: toolsNotSetUp }] };
                return { path: folder, namespace: "swift", sideEffects: false };
            });
            build.onLoad({ filter: /.*/, namespace: "swift" }, async (args) => {
                const folder = args.path;
                const mode = request!.mode!;
                try {
                    const contents =
                        mode === "build"
                            ? await buildPackage(folder, { ...request!, swift: request!.swift! })
                            : leftOutModule(packageFunctions(folder));
                    remember(request!, folder, mode);
                    return { contents, loader: "js" };
                } catch (error) {
                    return { errors: [{ text: error instanceof Error ? error.message : String(error) }] };
                }
            });
        },
    };
}
