import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { createApiModule } from "../src/api/module.ts";
import { binaryTransform, describe, scanExtension, type Report } from "../scripts/compat/extension.ts";
import { maxSourceBytes, readRegularFile } from "../scripts/compat/files.ts";
import { toJavaScript, uses } from "../scripts/compat/scan.ts";
import { raycastDeclarations, vendoredTypes } from "../scripts/raycast-types.ts";

// `fudge scan <folder> --json`, run the way the fudge tool runs it: with esbuild's binary and Raycast's types given
// by the environment, never esbuild's JS API.

const runtime = fileURLToPath(new URL("..", import.meta.url));
const fixtures = path.join(runtime, "test/fixtures/scan");
const platform = readdirSync(path.join(runtime, "node_modules/@esbuild")).find((name) => name.startsWith("darwin-"));
const esbuild = path.join(runtime, "node_modules/@esbuild", platform ?? "darwin-arm64", "bin/esbuild");
const types = path.join(runtime, "vendor/raycast-api/index.d.ts");
const scratch = mkdtempSync(path.join(tmpdir(), "fudge-scan-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

function scan(script: string, folder: string): unknown {
    const output = execFileSync(process.execPath, [script, folder, "--json"], {
        cwd: scratch,
        env: { ...process.env, FUDGE_ESBUILD: esbuild, FUDGE_RAYCAST_TYPES: types },
        encoding: "utf8",
    });
    return JSON.parse(output);
}

const supported = { extension: "scan-supported", supported: true, gaps: [], unreadable: [] };
const withGaps = {
    extension: "scan-gaps",
    supported: false,
    gaps: [
        { api: "AI.ask", kind: "missing", byDesign: "AI" },
        { api: "WindowManagement.getActiveWindow", kind: "missing" },
    ],
    unreadable: [],
};

test("fudge scan reports a supported extension and one with gaps", () => {
    const script = path.join(runtime, "scripts/compat/fudge-scan.ts");
    assert.deepEqual(scan(script, path.join(fixtures, "supported")), supported);
    assert.deepEqual(scan(script, path.join(fixtures, "gaps")), withGaps);
});

test("without --json, fudge scan lists the gaps for a person, saying Fudge", () => {
    const script = path.join(runtime, "scripts/compat/fudge-scan.ts");
    const run = (folder: string) =>
        execFileSync(process.execPath, [script, folder], {
            cwd: scratch,
            env: { ...process.env, FUDGE_ESBUILD: esbuild, FUDGE_RAYCAST_TYPES: types },
            encoding: "utf8",
        }).trimEnd();
    assert.equal(run(path.join(fixtures, "supported")), "scan-supported: Fudge supports everything it uses.");
    assert.equal(
        run(path.join(fixtures, "gaps")),
        [
            "scan-gaps uses things Fudge doesn't have yet:",
            "  WindowManagement.getActiveWindow (not in Fudge)",
            "scan-gaps uses AI, which Fudge leaves out:",
            "  AI.ask",
        ].join("\n"),
    );
    const other: Report = {
        extension: "other",
        supported: false,
        gaps: [
            { api: "Action.ToggleQuickLook", kind: "render-but-fail" },
            { api: "Form.LinkAccessory", kind: "not-drawn" },
            { api: "OAuth.PKCEClient", kind: "via @raycast/utils", via: ["OAuthService"], byDesign: "OAuth" },
        ],
        unreadable: ["src/broken.ts"],
    };
    assert.equal(
        describe(other),
        [
            "other uses things Fudge doesn't have yet:",
            "  Action.ToggleQuickLook (shows, but fails when used)",
            "  Form.LinkAccessory (not drawn)",
            "other uses OAuth, which Fudge leaves out:",
            "  OAuth.PKCEClient (through @raycast/utils: OAuthService)",
            "Couldn't read: src/broken.ts",
        ].join("\n"),
    );
    const onlyByDesign: Report = {
        extension: "asks",
        supported: false,
        gaps: [
            { api: "AI.ask", kind: "missing", byDesign: "AI" },
            { api: "AI.Model", kind: "missing", byDesign: "AI" },
        ],
        unreadable: [],
    };
    assert.equal(
        describe(onlyByDesign),
        ["asks uses AI, which Fudge leaves out:", "  AI.ask", "  AI.Model"].join("\n"),
        "nothing under \"doesn't have yet\" when only by-design APIs are used",
    );
});

test("the bundled scanner gives the same reports, and writes nothing beside itself", async () => {
    const bundle = path.join(scratch, "runtime");
    await build({
        entryPoints: [path.join(runtime, "scripts/compat/fudge-scan.ts")],
        bundle: true,
        platform: "node",
        format: "esm",
        target: "node22",
        outfile: path.join(bundle, "compat-scan.js"),
        external: ["esbuild"],
        logLevel: "silent",
    });
    copyFileSync(types, path.join(bundle, "raycast-api.d.ts"));
    const script = path.join(bundle, "compat-scan.js");
    assert.deepEqual(scan(script, path.join(fixtures, "supported")), supported);
    assert.deepEqual(scan(script, path.join(fixtures, "gaps")), withGaps);
    // raycast-types.ts's generator only runs as its own script, never from inside the bundle.
    assert.deepEqual(readdirSync(scratch).sort(), ["runtime"]);
    assert.deepEqual(readdirSync(bundle).sort(), ["compat-scan.js", "raycast-api.d.ts"]);
});

test("esbuild's binary and its JS API find the same uses", async () => {
    const file = path.join(fixtures, "supported/src/index.tsx");
    const source = `import { List, type LaunchProps } from "@raycast/api";\nexport default (p: LaunchProps) => <List.Item title={String(p)} />;`;
    const viaBinary = uses(await toJavaScript(source, file, binaryTransform(esbuild)));
    const viaAPI = uses(await toJavaScript(source, file));
    assert.deepEqual([...viaBinary.api].sort(), [...viaAPI.api].sort());
    assert.deepEqual([...viaBinary.api].sort(), ["List.Item"]);
});

test("a source esbuild can't read is unreadable, and the extension isn't called supported", () => {
    const broken = path.join(scratch, "broken");
    execFileSync("mkdir", ["-p", path.join(broken, "src")]);
    copyFileSync(path.join(fixtures, "supported/package.json"), path.join(broken, "package.json"));
    execFileSync("sh", ["-c", `printf 'export default (' > '${path.join(broken, "src/index.ts")}'`]);
    const report = scan(path.join(runtime, "scripts/compat/fudge-scan.ts"), broken) as Record<string, unknown>;
    assert.deepEqual(report, { extension: "scan-supported", supported: false, gaps: [], unreadable: ["src/index.ts"] });
});

// MARK: - Regular files only

/** An extension in `scratch` whose `src` holds a good source next to a link to /dev/zero, a FIFO, a folder named like
 * a source and a source over the size cap. */
function trickyExtension(): string {
    const folder = path.join(scratch, `tricky-${Date.now()}-${Math.random()}`);
    mkdirSync(path.join(folder, "src/dir.ts"), { recursive: true });
    writeFileSync(path.join(folder, "package.json"), JSON.stringify({ name: "tricky", title: "Tricky", commands: [] }));
    writeFileSync(path.join(folder, "src/ok.ts"), 'import { showHUD } from "@raycast/api";\nshowHUD("hi");\n');
    symlinkSync("/dev/zero", path.join(folder, "src/zero.ts"));
    assert.equal(spawnSync("/usr/bin/mkfifo", [path.join(folder, "src/fifo.ts")]).status, 0);
    writeFileSync(path.join(folder, "src/big.ts"), `// ${"x".repeat(maxSourceBytes)}\n`);
    return folder;
}

test("the scan reads regular files only: a link, a FIFO, a folder or a file over the cap is unreadable", async () => {
    const folder = trickyExtension();
    const started = Date.now();
    const result = await scanExtension(folder, {
        api: createApiModule() as Record<string, unknown>,
        declared: raycastDeclarations(vendoredTypes()),
    });
    assert.ok(Date.now() - started < 10_000, "nothing is waited on or read without end");
    assert.deepEqual(result.unreadable.sort(), ["src/big.ts", "src/dir.ts", "src/fifo.ts", "src/zero.ts"]);
    assert.deepEqual(result.gaps, [], "the good file is still scanned");
});

test("readRegularFile refuses links, FIFOs, folders and big files, and reads the rest", () => {
    const folder = trickyExtension();
    assert.match(readRegularFile(path.join(folder, "src/ok.ts"), maxSourceBytes), /showHUD/);
    for (const name of ["zero.ts", "fifo.ts", "dir.ts", "big.ts"]) {
        assert.throws(() => readRegularFile(path.join(folder, "src", name), maxSourceBytes), name);
    }
});

/** An extension in `scratch` with a good source, and links from its `src` to a folder outside it whose source uses
 * `AI.ask`, to `src` itself (`.`), and to that same outside folder under a name the scan skips (`__tests__`) and under
 * a source's name (`linked.ts`). */
function linkedFoldersExtension(): string {
    const outside = path.join(scratch, `outside-${Date.now()}-${Math.random()}`);
    mkdirSync(outside, { recursive: true });
    writeFileSync(path.join(outside, "ai.ts"), 'import { AI } from "@raycast/api";\nAI.ask("hi");\n');
    const folder = path.join(scratch, `linked-${Date.now()}-${Math.random()}`);
    mkdirSync(path.join(folder, "src"), { recursive: true });
    writeFileSync(path.join(folder, "package.json"), JSON.stringify({ name: "linked", title: "Linked", commands: [] }));
    writeFileSync(path.join(folder, "src/ok.ts"), 'import { showHUD } from "@raycast/api";\nshowHUD("hi");\n');
    symlinkSync(path.relative(path.join(folder, "src"), outside), path.join(folder, "src/lib"));
    symlinkSync(".", path.join(folder, "src/self"));
    symlinkSync(outside, path.join(folder, "src/__tests__"));
    symlinkSync(outside, path.join(folder, "src/linked.ts"));
    return folder;
}

test("the scan never walks into a linked folder: a link out of src/ and a link to . are unreadable", async () => {
    const folder = linkedFoldersExtension();
    const result = await scanExtension(folder, {
        api: createApiModule() as Record<string, unknown>,
        declared: raycastDeclarations(vendoredTypes()),
    });
    assert.deepEqual(
        result.unreadable.sort(),
        ["src/lib", "src/linked.ts", "src/self"],
        "each once, and a skipped name (__tests__) not at all",
    );
    assert.deepEqual(result.gaps, [], "AI.ask, outside the extension, isn't read");
    // The same through fudge scan, as the store runs it.
    const report = scan(path.join(runtime, "scripts/compat/fudge-scan.ts"), folder) as Report;
    assert.deepEqual(report.gaps, []);
    assert.deepEqual(report.unreadable.sort(), ["src/lib", "src/linked.ts", "src/self"]);
    assert.equal(report.supported, false);
});

test("scanExtension doesn't follow a src that's a link either, as make compat-scan calls it", async () => {
    const folder = path.join(scratch, `src-link-${Date.now()}-${Math.random()}`);
    mkdirSync(folder, { recursive: true });
    symlinkSync(path.join(fixtures, "gaps/src"), path.join(folder, "src"));
    const result = await scanExtension(folder, {
        api: createApiModule() as Record<string, unknown>,
        declared: raycastDeclarations(vendoredTypes()),
    });
    assert.deepEqual(result.unreadable, ["src"]);
    assert.deepEqual(result.gaps, []);
});

test("a src that's a link, a file or missing isn't an extension: exit code 2 and one clear line", () => {
    const script = path.join(runtime, "scripts/compat/fudge-scan.ts");
    const folder = path.join(scratch, "not-extensions");
    const cases: Record<string, (dir: string) => void> = {
        "src-is-a-file": (dir) => writeFileSync(path.join(dir, "src"), "not a folder"),
        "src-is-missing": () => undefined,
        "src-is-a-link": (dir) => symlinkSync(path.join(fixtures, "supported/src"), path.join(dir, "src")),
    };
    for (const [name, make] of Object.entries(cases)) {
        const dir = path.join(folder, name);
        mkdirSync(dir, { recursive: true });
        writeFileSync(path.join(dir, "package.json"), "{}");
        make(dir);
        const result = spawnSync(process.execPath, [script, dir, "--json"], {
            cwd: scratch,
            env: { ...process.env, FUDGE_ESBUILD: esbuild, FUDGE_RAYCAST_TYPES: types },
            encoding: "utf8",
        });
        assert.equal(result.status, 2, name);
        assert.equal(result.stderr.trim(), `${dir} isn't an extension: it needs a package.json file and a src folder`);
        assert.equal(result.stdout, "");
    }
});
