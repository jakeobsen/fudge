import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { binaryTransform } from "../scripts/compat/extension.ts";
import { toJavaScript, uses } from "../scripts/compat/scan.ts";

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
