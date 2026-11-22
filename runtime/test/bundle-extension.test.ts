import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readdirSync, symlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { before, test } from "node:test";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";
import { makeBundler } from "../scripts/compile/make-bundler.ts";
import { isInsideExtension, packageFunctions, parseFunctions, removeComments } from "../scripts/compile/rust.ts";

/** Raycast's own words for a Rust function called on a Mac, pinned here. */
const notSupportedOnMacOS = "Rust functions are not supported on macOS";

const runtime = fileURLToPath(new URL("..", import.meta.url));
const hostPath = path.join(runtime, "src/host.ts");
/** The made-up extension with a Rust part, which the Swift tests build too. */
const rustPart = path.join(runtime, "../Tests/FudgeCoreTests/Fixtures/rust-part");
const scratch = mkdtempSync(path.join(tmpdir(), "fudge-bundle-extension-"));

/** The esbuild program `make app` ships beside the tool, from esbuild's platform package. */
const esbuildBinary = (() => {
    const packages = path.join(runtime, "node_modules/@esbuild");
    const platform = readdirSync(packages).find((name) => name.startsWith("darwin-"));
    assert.ok(platform, "esbuild's macOS package is installed");
    return path.join(packages, platform, "bin/esbuild");
})();

/** The compile step as shipped: `bundle-extension.cjs`, made as `npm run build` makes it. */
const shipped = path.join(scratch, "bundle-extension.cjs");
let made: esbuild.BuildResult | undefined;
before(async () => {
    made = await makeBundler(shipped);
});

test("making the compile step warns about nothing", () => {
    // esbuild's API asks `require.resolve` for its platform package, which the shipped script never needs: that one
    // warning is silenced by name, and nothing else is.
    assert.deepEqual(made?.warnings, []);
    assert.deepEqual(made?.errors, []);
});

/** Runs the shipped compile step as `fudge build` does: in the extension's folder, driving esbuild's program. */
function compile(extension: string, options: esbuild.BuildOptions) {
    const request = path.join(mkdtempSync(path.join(scratch, "request-")), "request.json");
    writeFileSync(request, JSON.stringify({ extension, options }));
    return spawnSync(process.execPath, [shipped, request], {
        cwd: extension,
        encoding: "utf8",
        env: { ...process.env, ESBUILD_BINARY_PATH: esbuildBinary },
    });
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

/** A copy of the Rust fixture, with `files` added (path → contents), that a test may change. */
function rustPartCopy(files: Record<string, string> = {}): string {
    const copy = path.join(mkdtempSync(path.join(scratch, "extension-")), "rust-part");
    cpSync(rustPart, copy, { recursive: true });
    for (const [file, contents] of Object.entries(files)) {
        mkdirSync(path.dirname(path.join(copy, file)), { recursive: true });
        writeFileSync(path.join(copy, file), contents);
    }
    return copy;
}

test("the shipped esbuild program is the version of esbuild's JavaScript API", () => {
    // The API refuses a program of another version, so `fudge build` would stop at every build.
    assert.equal(execFileSync(esbuildBinary, ["--version"], { encoding: "utf8" }).trim(), esbuild.version);
});

test("Raycast's parser: comments stripped first, then every #[raycast] function, pub and async or not", () => {
    assert.equal(removeComments("a // b\nc /* d\ne */ f"), "a \nc  f");
    const source = `
        #[raycast]
        fn plain() {}
        #[raycast] pub fn public(name: String) -> String { name }
        #[raycast]
        async fn waits(items: Vec<String>, limits: HashMap<String, u32>) -> Result<u32, String> { Ok(0) }
        #[raycast]
        pub async fn both() -> () {}
        // #[raycast] fn line_comment() {}
        /* #[raycast] fn block_comment() {} */
        fn not_marked() {}
        #[raycast]
        fn url() -> String { "https://example.com".into() }
    `;
    // As in Raycast, the line-comment pass runs over string literals too (\`url\`'s is cut after \`https:\`).
    assert.deepEqual(parseFunctions(source), [
        { name: "plain", parameters: [] },
        { name: "public", parameters: ["name"] },
        { name: "waits", parameters: ["items", "limits"] },
        { name: "both", parameters: [] },
        { name: "url", parameters: [] },
    ]);
});

test("a Rust package's functions come from the .rs files under its src/, and no link is followed", () => {
    const folder = mkdtempSync(path.join(scratch, "rust-"));
    mkdirSync(path.join(folder, "src/nested"), { recursive: true });
    writeFileSync(path.join(folder, "src/main.rs"), "#[raycast]\nfn first() {}\n");
    writeFileSync(path.join(folder, "src/nested/more.rs"), "#[raycast]\nfn second(a: u8) {}\n");
    writeFileSync(path.join(folder, "src/notes.txt"), "#[raycast]\nfn not_rust() {}\n");
    writeFileSync(path.join(folder, "outside.rs"), "#[raycast]\nfn outside_src() {}\n");
    symlinkSync(path.join(folder, "outside.rs"), path.join(folder, "src/linked.rs"));
    symlinkSync(folder, path.join(folder, "src/loop"));
    assert.deepEqual(packageFunctions(folder).map((f) => f.name).sort(), ["first", "second"]);
    assert.deepEqual(packageFunctions(path.join(folder, "missing")), [], "no src/, no functions, as in Raycast");
});

test("a Rust package must be inside the extension's folder, links resolved", () => {
    const extension = mkdtempSync(path.join(scratch, "extension-"));
    mkdirSync(path.join(extension, "rust"));
    mkdirSync(`${extension}-sibling`);
    symlinkSync(`${extension}-sibling`, path.join(extension, "linked"));
    assert.equal(isInsideExtension(path.join(extension, "rust"), extension), true);
    assert.equal(isInsideExtension(extension, extension), true, "the extension's folder itself (`rust:..` from src/)");
    assert.equal(isInsideExtension(path.join(extension, "missing"), extension), true, "checked as written");
    assert.equal(isInsideExtension(path.join(extension, ".."), extension), false);
    assert.equal(isInsideExtension(`${extension}-sibling`, extension), false, "a name that only starts the same");
    assert.equal(isInsideExtension(path.join(extension, "linked"), extension), false, "a link that points out");
});

test("a Rust part's module exports its functions, the default and RustError, and every call refuses on a Mac", async () => {
    const extension = rustPartCopy({ "src/all.ts": 'export * from "rust:../rust";\nexport { default } from "rust:../rust";\n' });
    const build = options(extension, ["src/all.ts"]);
    const result = compile(extension, build);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "");
    const module = createRequire(import.meta.url)(path.join(build.outdir, "all.cjs"));
    assert.deepEqual(Object.keys(module).sort(), ["RustError", "count", "default", "greet"]);
    assert.deepEqual(Object.keys(module.default).sort(), ["count", "greet"]);
    assert.equal(module.greet, module.default.greet);
    for (const call of [() => module.greet("Mac"), () => module.count([], {})]) {
        await assert.rejects(call(), (error: Error) => {
            assert.equal(error.constructor, Error, "a plain Error, as Raycast's");
            assert.equal(error.message, notSupportedOnMacOS);
            return true;
        });
    }
    const error = new module.RustError("failed");
    assert.ok(error instanceof Error);
    assert.equal(error.name, "RustError");
    assert.equal(error.message, "failed");
});

test("an extension with a Rust part runs: a command that calls it only on Windows works, one that calls it gets Raycast's message", async () => {
    const build = options(rustPart, ["src/on-windows.ts", "src/direct.ts"]);
    const result = compile(rustPart, build);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(readdirSync(build.outdir).sort(), ["direct.cjs", "on-windows.cjs"]);

    const host = spawn(process.execPath, [hostPath], { stdio: ["pipe", "pipe", "pipe"] });
    const messages: Record<string, unknown>[] = [];
    const exits = new Map<string, (message: Record<string, unknown>) => void>();
    createInterface({ input: host.stdout }).on("line", (line) => {
        const message = JSON.parse(line) as Record<string, unknown>;
        messages.push(message);
        if (message.type === "exit") exits.get(String(message.session))?.(message);
    });
    const run = (session: string, file: string) =>
        new Promise<Record<string, unknown>>((resolve) => {
            exits.set(session, resolve);
            host.stdin.write(
                `${JSON.stringify({ type: "launch", session, entry: path.join(build.outdir, file), mode: "no-view" })}\n`,
            );
        });
    try {
        assert.equal((await run("w", "on-windows.cjs")).reason, "finished");
        const logs = messages.filter((m) => m.session === "w" && m.type === "log").map((m) => m.message);
        assert.deepEqual(logs, ["works without its Rust part"]);
        assert.deepEqual(
            messages.filter((m) => m.session === "w" && m.type === "error"),
            [],
        );

        await run("d", "direct.cjs");
        const errors = messages.filter((m) => m.session === "d" && m.type === "error");
        assert.deepEqual(
            errors.map((m) => m.message),
            [notSupportedOnMacOS],
        );
    } finally {
        host.kill();
    }
});

test("a rust: import is refused when its folder has no Cargo.toml or is outside the extension's folder", () => {
    const noCargo = rustPartCopy({ "src/no-cargo.ts": 'import { greet } from "rust:../src";\nvoid greet;\n' });
    let result = compile(noCargo, options(noCargo, ["src/no-cargo.ts"]));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /✘ \[ERROR\] failed to import Rust package from ".*\/src"\. Make sure you reference the folder that includes the 'Cargo\.toml' file \[plugin rust\]/);
    assert.match(result.stderr, /src\/no-cargo\.ts:1:22:/, "at the import");

    const outside = rustPartCopy({ "src/outside.ts": 'import { greet } from "rust:../../elsewhere";\nvoid greet;\n' });
    mkdirSync(path.join(outside, "../elsewhere"));
    writeFileSync(path.join(outside, "../elsewhere/Cargo.toml"), "[package]\n");
    result = compile(outside, options(outside, ["src/outside.ts"]));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\[ERROR\] the Rust package "rust:\.\.\/\.\.\/elsewhere" is outside the extension's folder \[plugin rust\]/);

    const linked = rustPartCopy({ "src/linked.ts": 'import { greet } from "rust:../linked";\nvoid greet;\n' });
    symlinkSync(path.join(outside, "../elsewhere"), path.join(linked, "linked"));
    result = compile(linked, options(linked, ["src/linked.ts"]));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\[ERROR\] the Rust package "rust:\.\.\/linked" is outside the extension's folder/);
});

test("a request the compile step can't read is an error it prints", () => {
    const result = spawnSync(process.execPath, [shipped, path.join(scratch, "missing.json")], {
        encoding: "utf8",
        env: { ...process.env, ESBUILD_BINARY_PATH: esbuildBinary },
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /ENOENT/);
});
