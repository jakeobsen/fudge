import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { createApiModule } from "../src/api/module.ts";
import { knownFiles, packages, report, resolveImport, scanExtension } from "../scripts/compat/extension.ts";
import { hasComputedImport, imports, toJavaScript } from "../scripts/compat/scan.ts";
import { compatibilityTag, fromReport } from "../store-extension/src/compatibility.ts";
import { raycastDeclarations, vendoredTypes } from "../scripts/raycast-types.ts";

// SPEC-109 §1: which of an extension's commands reach Raycast AI or the Browser Extension, each from its own entry.

const options = { api: createApiModule() as Record<string, unknown>, declared: raycastDeclarations(vendoredTypes()) };
const scratch = mkdtempSync(path.join(tmpdir(), "fudge-commands-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

/** A made-up extension: its commands (names), tools, files under its folder, and its dependencies. */
function extension(
    commands: string[],
    files: Record<string, string>,
    tools: string[] = [],
    dependencies: string[] = ["@raycast/api", "@raycast/utils"],
): string {
    const folder = mkdtempSync(path.join(scratch, "extension-"));
    const manifest = {
        name: "made-up",
        title: "Made Up",
        commands: commands.map((name) => ({ name, title: name, mode: "view" })),
        tools: tools.map((name) => ({ name, title: name, description: name })),
        dependencies: Object.fromEntries(dependencies.map((name) => [name, "^1.0.0"])),
    };
    writeFileSync(path.join(folder, "package.json"), JSON.stringify(manifest));
    for (const [file, text] of Object.entries(files)) {
        mkdirSync(path.dirname(path.join(folder, file)), { recursive: true });
        writeFileSync(path.join(folder, file), text);
    }
    return folder;
}

async function unsupportedByCommand(folder: string): Promise<Record<string, string[]>> {
    const result = await scanExtension(folder, options);
    for (const command of result.commands) assert.equal(command.traced, true, `${command.name} was traced`);
    return Object.fromEntries(result.commands.map((command) => [command.name, command.unsupported]));
}

const view = (body = "") => `import { List } from "@raycast/api";\n${body}\nexport default () => <List />;\n`;

test("a command that reaches AI.ask through a shared helper uses Raycast AI; the others don't", async () => {
    const folder = extension(["ask", "list", "history"], {
        "src/ask.tsx": view(`import { askAbout } from "./lib/ask";\naskAbout("x");`),
        "src/list.tsx": view(`import { format } from "./lib/format";\nformat("x");`),
        "src/history.tsx": view(),
        "src/lib/ask.ts": `import { AI } from "@raycast/api";\nexport const askAbout = (q: string) => AI.ask(q);\n`,
        "src/lib/format.ts": `export const format = (s: string) => s.trim();\n`,
    });
    assert.deepEqual(await unsupportedByCommand(folder), { ask: ["AI"], list: [], history: [] });
});

test("useAI from @raycast/utils counts, and only for the command that uses it", async () => {
    const folder = extension(["emoji", "search"], {
        "src/emoji.tsx": view(`import { useAI } from "@raycast/utils";\nexport const x = () => useAI("hi");`),
        "src/search.tsx": view(`import { useFetch } from "@raycast/utils";\nexport const y = () => useFetch("https://x");`),
    });
    assert.deepEqual(await unsupportedByCommand(folder), { emoji: ["AI"], search: [] });
});

test("AI used only in a tool counts for the tool, not for any command", async () => {
    const folder = extension(
        ["meetings"],
        {
            "src/meetings.tsx": view(),
            "src/tools/summarize.ts": `import { AI } from "@raycast/api";\nexport default () => AI.ask("sum");\n`,
        },
        ["summarize"],
    );
    const result = await scanExtension(folder, options);
    assert.deepEqual(
        result.commands.map((command) => [command.name, command.unsupported]),
        [["meetings", []]],
    );
    assert.ok(result.gaps.some((gap) => gap.api.startsWith("AI")), "the whole scan still sees it");
});

test("an extension with no AI has no command that uses it, and one where every command does has all", async () => {
    const none = extension(["a", "b"], { "src/a.tsx": view(), "src/b.tsx": view() });
    assert.deepEqual(await unsupportedByCommand(none), { a: [], b: [] });
    const every = extension(["a", "b"], {
        "src/a.tsx": view(`import { AI } from "@raycast/api";\nAI.ask("a");`),
        "src/b.ts": `import { BrowserExtension, AI } from "@raycast/api";\nexport default async () => { await BrowserExtension.getTabs(); await AI.ask("b"); };\n`,
    });
    assert.deepEqual(await unsupportedByCommand(every), { a: ["AI"], b: ["AI", "Browser Extension"] });
});

test("imports are followed however they're written: barrels, dynamic imports, require, aliases, .js names, index files", async () => {
    const ai = `import { AI } from "@raycast/api";\nexport const ask = () => AI.ask("x");\nexport const other = 1;\n`;
    const folder = extension(["barrel", "dynamic", "required", "alias", "esm", "folder"], {
        "src/barrel.tsx": view(`import { other } from "./lib";\nconsole.log(other);`),
        "src/lib/index.ts": `export * from "./ai";\n`,
        "src/lib/ai.ts": ai,
        "src/dynamic.tsx": view(`export const later = () => import("./later/ai");`),
        "src/later/ai.ts": ai,
        "src/required.js": `const { ask } = require("./required-ai");\nmodule.exports = () => ask();\n`,
        "src/required-ai.js": `const { AI } = require("@raycast/api");\nexports.ask = () => AI.ask("x");\n`,
        "src/alias.tsx": view(`import { ask } from "@/shared/ai";\nask();`),
        "src/shared/ai.ts": ai,
        "src/esm.ts": `import { ask } from "./esm-ai.js";\nexport default () => ask();\n`,
        "src/esm-ai.ts": ai,
        "src/folder.tsx": view(`import { ask } from "./folder-ai";\nask();`),
        "src/folder-ai/index.ts": ai,
    });
    const byCommand = await unsupportedByCommand(folder);
    for (const command of Object.keys(byCommand)) assert.deepEqual(byCommand[command], ["AI"], command);
});

test("a type-only import isn't followed, and data files aren't code", async () => {
    // `asks` reaches both AI files for real, so the backstop (a file using AI that no entry reaches) stays out of it.
    const folder = extension(["typed", "asks"], {
        "src/asks.tsx": view(
            `import { ask } from "./ai-types";\nimport { ask as other } from "./ai-other";\nask();\nother();`,
        ),
        "src/typed.tsx": view(
            `import type { Answer } from "./ai-types";\nimport { type Other } from "./ai-other";\nimport data from "../package.json";\nimport icons from "./icons.json";\nconst a: Answer | Other | undefined = undefined;\nconsole.log(a, data, icons);`,
        ),
        "src/ai-types.ts": `import { AI } from "@raycast/api";\nexport type Answer = string;\nexport const ask = () => AI.ask("x");\n`,
        "src/ai-other.ts": `import { AI } from "@raycast/api";\nexport type Other = number;\nexport const ask = () => AI.ask("y");\n`,
        "src/icons.json": "{}",
    });
    assert.deepEqual(await unsupportedByCommand(folder), { typed: [], asks: ["AI"] });
});

test("files are found ignoring case, as APFS and the build find them", async () => {
    const folder = extension(["subscriptions"], {
        "src/Subscriptions.tsx": view(`import { ask } from "./Lib/AI";\nask();`),
        "src/lib/ai.ts": `import { AI } from "@raycast/api";\nexport const ask = () => AI.ask("x");\n`,
    });
    assert.deepEqual(await unsupportedByCommand(folder), { subscriptions: ["AI"] });
});

test("a command with an import that can't be followed counts as reaching the whole extension", async () => {
    // `asks` reaches the AI file, so the backstop (a file using AI that no entry reaches) stays out of it.
    const folder = extension(["outside", "missing", "asks", "fine"], {
        "src/outside.tsx": view(`import { x } from "../../elsewhere/thing";\nconsole.log(x);`),
        "src/asks.tsx": view(`import { ask } from "./other";\nask();`),
        "src/fine.tsx": view(),
        "src/other.ts": `import { AI } from "@raycast/api";\nexport const ask = () => AI.ask("x");\n`,
    });
    const result = await scanExtension(folder, options);
    assert.deepEqual(
        result.commands.map((command) => [command.name, command.unsupported, command.traced]),
        [
            ["outside", ["AI"], false],
            ["missing", ["AI"], false],
            ["asks", ["AI"], true],
            ["fine", [], true],
        ],
    );
});

test("resolveImport tells the extension's own files from packages and data", async () => {
    const known = knownFiles(["src/a.ts", "src/lib/index.tsx", "src/b.tsx"]);
    const listed = packages(["@scope/package", "date-fns"]);
    const resolve = (from: string, specifier: string) => resolveImport(from, specifier, known, listed);
    assert.equal(resolve("src/b.tsx", "./a"), "src/a.ts");
    assert.equal(resolve("src/b.tsx", "./a.js"), "src/a.ts");
    assert.equal(resolve("src/b.tsx", "./lib"), "src/lib/index.tsx");
    assert.equal(resolve("src/lib/index.tsx", ".."), undefined, "src/index.* doesn't exist");
    assert.equal(resolve("src/b.tsx", "~/a"), "src/a.ts");
    assert.equal(resolve("src/b.tsx", "../assets/list.json"), "data");
    assert.equal(resolve("src/b.tsx", "../../outside"), undefined);
    assert.equal(resolve("src/b.tsx", "#internal"), undefined);
    // Packages: the manifest's dependencies (with a subpath too), Node's built-ins, and what the host provides.
    for (const specifier of ["@scope/package", "@scope/package/sub", "date-fns", "date-fns/format"]) {
        assert.equal(resolve("src/b.tsx", specifier), "package", specifier);
    }
    for (const specifier of ["node:fs", "fs", "fs/promises", "path", "child_process"]) {
        assert.equal(resolve("src/b.tsx", specifier), "package", specifier);
    }
    for (const specifier of ["@raycast/api", "react", "react/jsx-runtime"]) {
        assert.equal(resolve("src/b.tsx", specifier), "package", `${specifier}, provided though not listed`);
    }
    // Any other bare import is a file of the extension's own the scan can't find: a tsconfig alias, a baseUrl import.
    for (const specifier of ["@lib/ai", "lib/ai", "@scope/other", "left-pad", "@scope"]) {
        assert.equal(resolve("src/b.tsx", specifier), undefined, specifier);
    }
    assert.deepEqual(
        imports(await toJavaScript(`export { a } from "./a";\nimport "./side";\nexport * as b from "./b";`, "x.ts")).sort(),
        ["./a", "./b", "./side"],
    );
});

const usesAI = `import { AI } from "@raycast/api";\nexport const ask = () => AI.ask("x");\n`;

test("a tsconfig alias the scan can't follow counts the whole extension: never Compatible", async () => {
    const folder = extension(
        ["ask", "summarize", "plain"],
        {
            "tsconfig.json": JSON.stringify({ compilerOptions: { baseUrl: ".", paths: { "@lib/*": ["src/lib/*"] } } }),
            "src/ask.tsx": view(`import { ask } from "@lib/ai";\nask();`),
            "src/summarize.tsx": view(`import { ask } from "@lib/ai";\nask();`),
            "src/plain.tsx": view(`import { format } from "date-fns";\nformat(new Date(), "y");`),
            "src/lib/ai.ts": usesAI,
        },
        [],
        ["@raycast/api", "date-fns"],
    );
    const result = await scanExtension(folder, options);
    assert.deepEqual(
        result.commands.map((command) => [command.name, command.unsupported, command.traced]),
        [
            ["ask", ["AI"], false],
            ["summarize", ["AI"], false],
            // Its own imports are followed, but the AI file is reached by no entry, so the backstop counts it here too.
            ["plain", ["AI"], false],
        ],
    );
    assert.equal(compatibilityTag(fromReport(report(folder, result))), "Not compatible");
});

test("a bare import the manifest doesn't list can't be followed; a listed one and Node's built-ins can", async () => {
    const folder = extension(
        ["listed", "unlisted"],
        {
            "src/listed.tsx": view(
                `import { format } from "date-fns";\nimport { join } from "node:path";\n` +
                    `import { readFileSync } from "fs";\nconsole.log(format, join, readFileSync);`,
            ),
            "src/unlisted.tsx": view(`import pad from "left-pad";\nconsole.log(pad);`),
        },
        [],
        ["@raycast/api", "date-fns"],
    );
    const result = await scanExtension(folder, options);
    assert.deepEqual(
        result.commands.map((command) => [command.name, command.traced]),
        [
            ["listed", true],
            ["unlisted", false],
        ],
    );
});

test("an import() or require() of a computed path can't be followed", async () => {
    assert.equal(hasComputedImport(await toJavaScript('export const a = () => import("./a");', "x.ts")), false);
    assert.equal(hasComputedImport(await toJavaScript('const b = require("./b");\nconsole.log(b);', "x.js")), false);
    assert.equal(hasComputedImport(await toJavaScript("console.log(import.meta.url);", "x.ts")), false);
    // esbuild writes a template with nothing in it as a plain string, which `imports` follows.
    const fixed = await toJavaScript("export const a = () => import(`./commands/fixed`);", "x.ts");
    assert.equal(hasComputedImport(fixed), false);
    assert.deepEqual(imports(fixed), ["./commands/fixed"]);
    for (const code of [
        "export const a = (name: string) => import(`./commands/${name}`);",
        "export const a = (path: string) => import(path);",
        'export const a = (name: string) => require("./commands/" + name);',
    ]) {
        assert.equal(hasComputedImport(await toJavaScript(code, "x.ts")), true, code);
    }

    const folder = extension(["template", "variable", "direct", "plain"], {
        "src/template.tsx": view("export const load = (name: string) => import(`./handlers/${name}`);"),
        "src/variable.ts": "export default (name: string) => require(name);\n",
        // Reaches the AI handler itself, so the backstop stays out of it: only the computed imports count.
        "src/direct.tsx": view(`import { ask } from "./handlers/ai";\nask();`),
        "src/plain.tsx": view(),
        "src/handlers/ai.ts": usesAI,
    });
    const result = await scanExtension(folder, options);
    assert.deepEqual(
        result.commands.map((command) => [command.name, command.unsupported, command.traced]),
        [
            ["template", ["AI"], false],
            ["variable", ["AI"], false],
            ["direct", ["AI"], true],
            ["plain", [], true],
        ],
    );
});

test("a file using AI that no command or tool reaches counts the whole extension", async () => {
    const stray = extension(["a", "b"], { "src/a.tsx": view(), "src/b.tsx": view(), "src/stray/ai.ts": usesAI });
    const result = await scanExtension(stray, options);
    assert.deepEqual(
        result.commands.map((command) => [command.name, command.unsupported, command.traced]),
        [
            ["a", ["AI"], false],
            ["b", ["AI"], false],
        ],
    );

    // A tool's entry and a command's are both entries: what one of them reaches leaves the others as traced.
    const byTool = extension(
        ["a", "b"],
        {
            "src/a.tsx": view(),
            "src/b.tsx": view(),
            "src/tools/ask.ts": `export { ask as default } from "../lib/ai";\n`,
            "src/lib/ai.ts": usesAI,
        },
        ["ask"],
    );
    assert.deepEqual(await unsupportedByCommand(byTool), { a: [], b: [] });
    const byCommand = extension(["a", "b"], {
        "src/a.tsx": view(`import { ask } from "./lib/ai";\nask();`),
        "src/b.tsx": view(),
        "src/lib/ai.ts": usesAI,
    });
    assert.deepEqual(await unsupportedByCommand(byCommand), { a: ["AI"], b: [] });

    // A file no entry reaches that uses nothing Fudge doesn't support changes nothing.
    const harmless = extension(["a"], { "src/a.tsx": view(), "src/stray/format.ts": "export const f = 1;\n" });
    assert.deepEqual(await unsupportedByCommand(harmless), { a: [] });
});
