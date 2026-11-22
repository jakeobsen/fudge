// SPEC-145 §2: the `swift:` plugin of `fudge build`'s compile step, through the shipped `bundle-extension.cjs`, with a
// fake `swift` that answers as SwiftPM does, so nothing is fetched or compiled.

import assert from "node:assert/strict";
import { spawn, spawnSync, type SpawnSyncReturns } from "node:child_process";
import {
    chmodSync,
    cpSync,
    existsSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    readdirSync,
    realpathSync,
    statSync,
    symlinkSync,
    writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { before, test } from "node:test";
import { fileURLToPath } from "node:url";
import type * as esbuild from "esbuild";
import { makeBundler } from "../scripts/compile/make-bundler.ts";
import {
    chooseSwiftParts,
    didntBuild,
    executableTarget,
    leftOut,
    packageFunctions,
    packageMessages,
    swiftFunctions,
    toolsNotSetUp,
} from "../scripts/compile/swift.ts";

const runtime = fileURLToPath(new URL("..", import.meta.url));
const hostPath = path.join(runtime, "src/host.ts");
/** The made-up extension with a part written in Swift. */
const swiftPart = path.join(runtime, "../Tests/FudgeCoreTests/Fixtures/swift-part");
/** Links resolved, as esbuild hands the plugin its paths. */
const scratch = realpathSync(mkdtempSync(path.join(tmpdir(), "fudge-swift-parts-")));

const esbuildBinary = (() => {
    const packages = path.join(runtime, "node_modules/@esbuild");
    const platform = readdirSync(packages).find((name) => name.startsWith("darwin-"));
    assert.ok(platform, "esbuild's macOS package is installed");
    return path.join(packages, platform, "bin/esbuild");
})();

const shipped = path.join(scratch, "bundle-extension.cjs");
before(async () => {
    await makeBundler(shipped);
});

/** The made-up `swift` (its folder goes to `<tools>/usr/bin`): see the script for what it answers. */
const fakeSwift = path.join(runtime, "../Tests/FudgeCoreTests/Fixtures/fake-swift");

/** A tools folder with the fake `usr/bin/swift`, and the files where it logs its runs and environments. */
function fakeTools(): { swift: string; log: string; environment: string; folder: string } {
    const folder = mkdtempSync(path.join(scratch, "tools-"));
    const bin = path.join(folder, "usr/bin");
    cpSync(fakeSwift, bin, { recursive: true });
    return {
        swift: path.join(bin, "swift"),
        log: path.join(bin, "runs.log"),
        environment: path.join(bin, "environment.log"),
        folder,
    };
}

/** A copy of the Swift fixture, with `files` added (path → contents), that a test may change. */
function swiftPartCopy(files: Record<string, string> = {}): string {
    const copy = path.join(mkdtempSync(path.join(scratch, "extension-")), "swift-part");
    cpSync(swiftPart, copy, { recursive: true });
    for (const [file, contents] of Object.entries(files)) {
        mkdirSync(path.dirname(path.join(copy, file)), { recursive: true });
        writeFileSync(path.join(copy, file), contents);
    }
    return copy;
}

/** `ExtensionBuilder.BundleOptions` for `entries` of `extension`, into a new folder. */
function options(extension: string, entries: string[]): esbuild.BuildOptions & { outdir: string } {
    return {
        entryPoints: entries.map((entry) => path.join(extension, entry)),
        bundle: true,
        platform: "node",
        format: "cjs",
        target: "node22",
        jsx: "automatic",
        outdir: mkdtempSync(path.join(scratch, "out-")),
        outbase: path.join(extension, "src"),
        outExtension: { ".js": ".cjs" },
        define: { "process.env.NODE_ENV": '"production"' },
        legalComments: "none",
        logLevel: "warning",
        external: ["@raycast/api", "react", "react/jsx-runtime", "react/jsx-dev-runtime", "fudge:app"],
        nodePaths: [],
    };
}

type Swift = { mode?: "build" | "leave-out"; swift?: string };

/** `ExtensionBuilder.SwiftRequest`, in a new scratch folder. */
function swiftRequest(swift: Swift) {
    const folder = mkdtempSync(path.join(scratch, "build-"));
    return {
        ...swift,
        cache: path.join(folder, "cache"),
        scratch: path.join(folder, "swift"),
        binaries: path.join(folder, "swift-programs"),
        report: path.join(folder, "swift-parts-report.json"),
    };
}

/** Runs the shipped compile step as `fudge build` does, with `env` added to the environment. */
function compile(
    extension: string,
    entries: string[],
    swift: Swift,
    env: Record<string, string> = {},
): { result: SpawnSyncReturns<string>; build: ReturnType<typeof options>; request: ReturnType<typeof swiftRequest> } {
    const build = options(extension, entries);
    const request = swiftRequest(swift);
    const file = path.join(mkdtempSync(path.join(scratch, "request-")), "request.json");
    writeFileSync(file, JSON.stringify({ extension, options: build, swift: request }));
    const result = spawnSync(process.execPath, [shipped, file], {
        cwd: extension,
        encoding: "utf8",
        env: { ...process.env, ESBUILD_BINARY_PATH: esbuildBinary, ...env },
    });
    return { result, build, request };
}

/** Runs `file` as a no-view command in the extension host, with its assets in `assets`, and returns its logs and
 * errors. */
async function run(file: string, assets: string): Promise<{ logs: unknown[]; errors: unknown[] }> {
    const host = spawn(process.execPath, [hostPath], { stdio: ["pipe", "pipe", "pipe"] });
    const messages: Record<string, unknown>[] = [];
    try {
        await new Promise<void>((resolve) => {
            createInterface({ input: host.stdout }).on("line", (line) => {
                const message = JSON.parse(line) as Record<string, unknown>;
                messages.push(message);
                if (message.type === "exit") resolve();
            });
            const environment = {
                extensionName: "swift-part",
                commandName: path.basename(file, ".cjs"),
                commandMode: "no-view",
                assetsPath: assets,
                manifestPath: "",
                supportPath: scratch,
                cachePath: scratch,
                localStoragePath: path.join(scratch, "local-storage.json"),
                ownerOrAuthorName: "",
                appearance: "light",
                isDevelopment: false,
            };
            host.stdin.write(`${JSON.stringify({ type: "launch", session: "s", entry: file, mode: "no-view", environment })}\n`);
        });
    } finally {
        host.kill();
    }
    return {
        logs: messages.filter((m) => m.type === "log").map((m) => m.message),
        errors: messages.filter((m) => m.type === "error").map((m) => m.message),
    };
}

test("the plugin's messages, word for word (SPEC-145 §2), and Raycast's about the package", () => {
    assert.equal(chooseSwiftParts, "this extension has a part written in Swift: choose --swift-parts build or --swift-parts leave-out");
    assert.equal(toolsNotSetUp, "Apple's Command Line Tools aren't set up. Set them up in Settings → Development.");
    assert.equal(didntBuild, "the part written in Swift didn't build");
    assert.equal(
        leftOut,
        "This extension's part written in Swift wasn't installed. Reinstall it with Apple's Command Line Tools set up in Settings → Development.",
    );
    assert.equal(
        packageMessages.noPackage("/x/swift"),
        `failed to import Swift package from "/x/swift". Make sure you reference the folder that includes the 'Package.swift' file`,
    );
    assert.equal(packageMessages.noName, "failed to read the schema name from swift package");
    assert.equal(packageMessages.moreThanOne, "failed to parse the swift package: expected one executable target but found more than one");
    assert.equal(packageMessages.none, "failed to parse the swift package: expected one executable target but found none");
});

test("the leave-out scan: @raycast, then whitespace, attributes and modifiers, then func; #exportFunction; no comments", () => {
    const source = `
        @raycast func one(a: Int) -> Int { a }
        @raycast
        func two() {}
        @raycast @MainActor func three() async {}
        @raycast
        @available(macOS 13, *)
        public nonisolated func four() {}
        #exportFunction(five)
        // @raycast func lineComment() {}
        /* @raycast func blockComment() {} */
        func unmarked() {}
        @raycast let notAFunction = 1
    `;
    assert.deepEqual(swiftFunctions(source), ["one", "two", "three", "four", "five"]);
});

test("a package's functions come from every .swift file in its folder outside .build, wherever its target keeps them", () => {
    const folder = mkdtempSync(path.join(scratch, "package-"));
    writeFileSync(path.join(folder, "Package.swift"), '// .executableTarget(name: "X", path: "src")\n');
    mkdirSync(path.join(folder, "src/nested"), { recursive: true });
    writeFileSync(path.join(folder, "src/Main.swift"), "@raycast\nfunc first() {}\n");
    writeFileSync(path.join(folder, "src/nested/More.swift"), "@raycast func second() {}\n@raycast func first() {}\n");
    mkdirSync(path.join(folder, ".build/checkouts"), { recursive: true });
    writeFileSync(path.join(folder, ".build/checkouts/Dependency.swift"), "@raycast func built() {}\n");
    writeFileSync(path.join(folder, "notes.txt"), "@raycast func notSwift() {}\n");
    writeFileSync(path.join(scratch, "Outside.swift"), "@raycast func outside() {}\n");
    symlinkSync(path.join(scratch, "Outside.swift"), path.join(folder, "src/Linked.swift"));
    symlinkSync(folder, path.join(folder, "src/loop"));
    assert.deepEqual(packageFunctions(folder), ["first", "second"]);
});

test("the executable target comes from dump-package: exactly one, with Raycast's messages otherwise", () => {
    const target = (targets: unknown[], name: unknown = "Package") =>
        executableTarget(JSON.stringify({ name, targets }));
    assert.equal(target([{ name: "Tool", type: "executable" }, { name: "Library", type: "regular" }]), "Tool");
    assert.throws(() => target([{ name: "A", type: "executable" }, { name: "B", type: "executable" }]), {
        message: packageMessages.moreThanOne,
    });
    assert.throws(() => target([{ name: "Library", type: "regular" }]), { message: packageMessages.none });
    assert.throws(() => target([{ name: "Tool", type: "executable" }], ""), { message: packageMessages.noName });
});

test("a swift: import with no --swift-parts stops the build, at the import, asking for one", () => {
    const tools = fakeTools();
    const { result } = compile(swiftPart, ["src/greet.ts", "src/plain.ts"], { swift: tools.swift });
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`✘ \\[ERROR\\] ${chooseSwiftParts} \\[plugin swift\\]`));
    assert.match(result.stderr, /src\/greet\.ts:1:22:/);
    assert.equal(result.stderr.match(/\[ERROR\]/g)?.length, 1);
    assert.equal(existsSync(tools.log), false, "no swift ran");
});

test("--swift-parts build with no tools stops the build, pointing to Settings → Development", () => {
    const { result } = compile(swiftPart, ["src/greet.ts"], { mode: "build" });
    assert.equal(result.status, 1);
    assert.ok(result.stderr.includes(`✘ [ERROR] ${toolsNotSetUp} [plugin swift]`), result.stderr);
});

test("without a swift: import, --swift-parts changes nothing", () => {
    const tools = fakeTools();
    const plain = compile(swiftPart, ["src/plain.ts"], {});
    const built = compile(swiftPart, ["src/plain.ts"], { mode: "build", swift: tools.swift });
    const left = compile(swiftPart, ["src/plain.ts"], { mode: "leave-out" });
    for (const { result } of [plain, built, left]) assert.equal(result.status, 0, result.stderr);
    const bytes = readFileSync(path.join(plain.build.outdir, "plain.cjs"));
    assert.deepEqual(readFileSync(path.join(built.build.outdir, "plain.cjs")), bytes);
    assert.deepEqual(readFileSync(path.join(left.build.outdir, "plain.cjs")), bytes);
    assert.equal(existsSync(tools.log), false, "no swift ran");
    assert.equal(existsSync(built.request.report), false, "nothing to remember");
});

test("--swift-parts build: SwiftPM builds a copy in the scratch folder, and the program runs as Raycast runs it", async () => {
    const tools = fakeTools();
    const extension = swiftPartCopy({ "src/fails.ts": 'import { fail } from "swift:../swift";\nexport default async function Command() {\n  await fail();\n}\n' });
    const { result, build, request } = compile(extension, ["src/greet.ts", "src/plain.ts", "src/fails.ts"], {
        mode: "build",
        swift: tools.swift,
    });
    assert.equal(result.status, 0, result.stderr);

    // The copy keeps the folder's name and is built in the scratch folder, with the shared cache; the extension's
    // own folder gets no .build.
    const runs = readFileSync(tools.log, "utf8").trim().split("\n");
    assert.equal(runs.length, 3);
    const copy = runs[0]!.split(" ")[0]!;
    assert.equal(path.basename(copy), "swift");
    assert.ok(copy.startsWith(request.scratch), copy);
    assert.equal(runs[0], `${copy} package dump-package`);
    assert.equal(runs[1], `${copy} build -c release --product swift --cache-path ${request.cache}`);
    assert.equal(runs[2], `${copy} build -c release --product swift --cache-path ${request.cache} --show-bin-path`);
    assert.equal(existsSync(path.join(extension, "swift/.build")), false);
    assert.deepEqual(readdirSync(path.join(extension, "swift")).sort(), ["Package.swift", "Sources"]);

    // The program, by its package folder's name, with mode 755.
    const programPath = path.join(request.binaries, "swift");
    assert.equal(statSync(programPath).mode & 0o777, 0o755);
    assert.deepEqual(JSON.parse(readFileSync(request.report, "utf8")), { [path.join(extension, "swift")]: "build" });

    const assets = mkdtempSync(path.join(scratch, "assets-"));
    mkdirSync(path.join(assets, "compiled_raycast_swift"));
    cpSync(programPath, path.join(assets, "compiled_raycast_swift/swift"));
    chmodSync(path.join(assets, "compiled_raycast_swift/swift"), 0o644);
    const greeted = await run(path.join(build.outdir, "greet.cjs"), assets);
    assert.deepEqual(greeted.logs, ["Hello, Mac"]);
    assert.deepEqual(greeted.errors, []);
    assert.equal(statSync(path.join(assets, "compiled_raycast_swift/swift")).mode & 0o777, 0o755, "chmod 755 first");
    const failed = await run(path.join(build.outdir, "fails.cjs"), assets);
    assert.deepEqual(failed.errors, ["the Swift part failed"], "stderr is the message");
    assert.deepEqual((await run(path.join(build.outdir, "plain.cjs"), assets)).logs, ["works without its Swift part"]);
});

test("the module exports what Raycast's does: the plugin's functions and SwiftError, a SwiftError with stdout and stderr", async () => {
    const tools = fakeTools();
    const extension = swiftPartCopy({
        "src/all.ts": `import * as part from "swift:../swift";
export default async function Command() {
  console.log(JSON.stringify(Object.keys(part).sort()));
  try {
    await part.fail();
  } catch (error) {
    console.log(JSON.stringify([error instanceof part.SwiftError, error.name, error.message, error.stdout, error.stderr]));
  }
  console.log(JSON.stringify(await runNothing()));
  async function runNothing() {
    return null;
  }
}
`,
    });
    const { result, build, request } = compile(extension, ["src/all.ts"], { mode: "build", swift: tools.swift });
    assert.equal(result.status, 0, result.stderr);
    const assets = mkdtempSync(path.join(scratch, "assets-"));
    mkdirSync(path.join(assets, "compiled_raycast_swift"));
    cpSync(path.join(request.binaries, "swift"), path.join(assets, "compiled_raycast_swift/swift"));
    const { logs, errors } = await run(path.join(build.outdir, "all.cjs"), assets);
    assert.deepEqual(errors, []);
    assert.deepEqual(logs.slice(0, 2), [
        JSON.stringify(["SwiftError", "fail", "greet"]),
        JSON.stringify([true, "SwiftError", "the Swift part failed", "", "the Swift part failed"]),
    ]);
});

test("a build with no raycast.js exports the scanned names, each running the program", async () => {
    const tools = fakeTools();
    const { result, build, request } = compile(swiftPart, ["src/greet.ts"], { mode: "build", swift: tools.swift }, {
        FAKE_SWIFT_NO_JS: "1",
    });
    assert.equal(result.status, 0, result.stderr);
    const assets = mkdtempSync(path.join(scratch, "assets-"));
    mkdirSync(path.join(assets, "compiled_raycast_swift"));
    cpSync(path.join(request.binaries, "swift"), path.join(assets, "compiled_raycast_swift/swift"));
    assert.deepEqual((await run(path.join(build.outdir, "greet.cjs"), assets)).logs, ["Hello, Mac"]);
});

test("the plugin's output folder is the package's identity, its folder's name lowercased; the program keeps the case", () => {
    const tools = fakeTools();
    const extension = swiftPartCopy({ "src/capital.ts": 'export { greet } from "swift:../SwiftPart";\n' });
    cpSync(path.join(extension, "swift"), path.join(extension, "SwiftPart"), { recursive: true });
    const { result, build, request } = compile(extension, ["src/capital.ts"], { mode: "build", swift: tools.swift });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(existsSync(path.join(request.binaries, "SwiftPart")));
    assert.match(readFileSync(path.join(build.outdir, "capital.cjs"), "utf8"), /runSwiftFunction\("greet", name\)/);
    assert.match(readFileSync(path.join(build.outdir, "capital.cjs"), "utf8"), /"compiled_raycast_swift", "SwiftPart"/);
});

test("a failed build fails the install with SwiftPM's output after the first line", () => {
    const tools = fakeTools();
    const { result } = compile(swiftPart, ["src/greet.ts"], { mode: "build", swift: tools.swift }, { FAKE_SWIFT_FAIL: "1" });
    assert.equal(result.status, 1);
    assert.ok(
        result.stderr.includes(`✘ [ERROR] ${didntBuild}\nSources/X/Y.swift:1:1: error: cannot find 'x' in scope`),
        result.stderr,
    );
});

test("two executable targets, or none, stop the build with Raycast's messages", () => {
    const tools = fakeTools();
    const two = JSON.stringify({ name: "P", targets: [{ name: "A", type: "executable" }, { name: "B", type: "executable" }] });
    let { result } = compile(swiftPart, ["src/greet.ts"], { mode: "build", swift: tools.swift }, { FAKE_SWIFT_DUMP: two });
    assert.equal(result.status, 1);
    assert.ok(result.stderr.includes(packageMessages.moreThanOne), result.stderr);
    const none = JSON.stringify({ name: "P", targets: [{ name: "L", type: "regular" }] });
    ({ result } = compile(swiftPart, ["src/greet.ts"], { mode: "build", swift: tools.swift }, { FAKE_SWIFT_DUMP: none }));
    assert.ok(result.stderr.includes(packageMessages.none), result.stderr);
});

test("a swift: import is refused when its folder has no Package.swift or is outside the extension's folder", () => {
    for (const mode of [undefined, "build", "leave-out"] as const) {
        const tools = fakeTools();
        const noPackage = swiftPartCopy({ "src/no-package.ts": 'import { greet } from "swift:../src";\nvoid greet;\n' });
        let { result } = compile(noPackage, ["src/no-package.ts"], { mode, swift: tools.swift });
        assert.equal(result.status, 1);
        assert.ok(result.stderr.includes(`[ERROR] ${packageMessages.noPackage(path.join(noPackage, "src"))}`), result.stderr);
        assert.match(result.stderr, /src\/no-package\.ts:1:22:/, "at the import");

        const outside = swiftPartCopy({ "src/outside.ts": 'import { greet } from "swift:../../elsewhere";\nvoid greet;\n' });
        cpSync(path.join(outside, "swift"), path.join(outside, "../elsewhere"), { recursive: true });
        ({ result } = compile(outside, ["src/outside.ts"], { mode, swift: tools.swift }));
        assert.equal(result.status, 1);
        assert.match(result.stderr, /\[ERROR\] the Swift package "swift:\.\.\/\.\.\/elsewhere" is outside the extension's folder/);

        const linked = swiftPartCopy({ "src/linked.ts": 'import { greet } from "swift:../linked";\nvoid greet;\n' });
        symlinkSync(path.join(outside, "../elsewhere"), path.join(linked, "linked"));
        ({ result } = compile(linked, ["src/linked.ts"], { mode, swift: tools.swift }));
        assert.equal(result.status, 1);
        assert.match(result.stderr, /\[ERROR\] the Swift package "swift:\.\.\/linked" is outside the extension's folder/);
        assert.equal(existsSync(tools.log), false, "no swift ran");
    }
});

test("--swift-parts leave-out: nothing runs swift, the same names refuse every call with Fudge's message", async () => {
    const tools = fakeTools();
    const extension = swiftPartCopy({
        "src/all.ts": `import * as part from "swift:../swift";
export default async function Command() {
  console.log(JSON.stringify(Object.keys(part).sort()));
  for (const call of [() => part.greet("Mac"), () => part.fail()]) {
    try {
      await call();
    } catch (error) {
      console.log(JSON.stringify([error instanceof part.SwiftError, error.name, error.message]));
    }
  }
}
`,
    });
    const { result, build, request } = compile(extension, ["src/all.ts", "src/greet.ts", "src/plain.ts"], {
        mode: "leave-out",
        swift: tools.swift,
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(existsSync(tools.log), false, "no swift ran");
    assert.equal(existsSync(request.binaries), false, "no program");
    assert.deepEqual(JSON.parse(readFileSync(request.report, "utf8")), { [path.join(extension, "swift")]: "leave-out" });
    const assets = mkdtempSync(path.join(scratch, "assets-"));
    const { logs } = await run(path.join(build.outdir, "all.cjs"), assets);
    assert.deepEqual(logs, [
        JSON.stringify(["SwiftError", "fail", "greet"]),
        JSON.stringify([true, "SwiftError", leftOut]),
        JSON.stringify([true, "SwiftError", leftOut]),
    ]);
    assert.deepEqual((await run(path.join(build.outdir, "greet.cjs"), assets)).errors, [leftOut]);
    assert.deepEqual((await run(path.join(build.outdir, "plain.cjs"), assets)).logs, ["works without its Swift part"]);
});

test("stopping the build stops swift too", async () => {
    const tools = fakeTools();
    const pidFile = path.join(tools.folder, "swift.pid");
    const request = swiftRequest({ mode: "build", swift: tools.swift });
    const file = path.join(mkdtempSync(path.join(scratch, "request-")), "request.json");
    writeFileSync(file, JSON.stringify({ extension: swiftPart, options: options(swiftPart, ["src/greet.ts"]), swift: request }));
    const child = spawn(process.execPath, [shipped, file], {
        cwd: swiftPart,
        stdio: "ignore",
        env: { ...process.env, ESBUILD_BINARY_PATH: esbuildBinary, FAKE_SWIFT_SLEEP: pidFile },
    });
    const exited = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
    const deadline = Date.now() + 30_000;
    while (!existsSync(pidFile) || readFileSync(pidFile, "utf8").trim() === "") {
        assert.ok(Date.now() < deadline, "swift started");
        await new Promise((resolve) => setTimeout(resolve, 50));
    }
    const swiftPid = Number(readFileSync(pidFile, "utf8").trim());
    const alive = (pid: number) => {
        try {
            process.kill(pid, 0);
            return true;
        } catch {
            return false;
        }
    };
    assert.ok(alive(swiftPid));
    // Only the script itself is signalled, not its process group, so the script must pass it on.
    child.kill("SIGTERM");
    assert.equal(await exited, 143);
    const gone = Date.now() + 10_000;
    while (alive(swiftPid) && Date.now() < gone) await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(alive(swiftPid), false, "swift was stopped");
});
