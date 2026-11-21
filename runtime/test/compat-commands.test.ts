import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { createApiModule } from "../src/api/module.ts";
import { knownFiles, resolveImport, scanExtension } from "../scripts/compat/extension.ts";
import { imports, toJavaScript } from "../scripts/compat/scan.ts";
import { raycastDeclarations, vendoredTypes } from "../scripts/raycast-types.ts";

// SPEC-109 §1: which of an extension's commands reach Raycast AI or the Browser Extension, each from its own entry.

const options = { api: createApiModule() as Record<string, unknown>, declared: raycastDeclarations(vendoredTypes()) };
const scratch = mkdtempSync(path.join(tmpdir(), "fudge-commands-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

/** A made-up extension: its commands (names), tools, and files under its folder. */
function extension(commands: string[], files: Record<string, string>, tools: string[] = []): string {
    const folder = mkdtempSync(path.join(scratch, "extension-"));
    const manifest = {
        name: "made-up",
        title: "Made Up",
        commands: commands.map((name) => ({ name, title: name, mode: "view" })),
        tools: tools.map((name) => ({ name, title: name, description: name })),
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
    const folder = extension(["typed"], {
        "src/typed.tsx": view(
            `import type { Answer } from "./ai-types";\nimport { type Other } from "./ai-other";\nimport data from "../package.json";\nimport icons from "./icons.json";\nconst a: Answer | Other | undefined = undefined;\nconsole.log(a, data, icons);`,
        ),
        "src/ai-types.ts": `import { AI } from "@raycast/api";\nexport type Answer = string;\nexport const ask = () => AI.ask("x");\n`,
        "src/ai-other.ts": `import { AI } from "@raycast/api";\nexport type Other = number;\nexport const ask = () => AI.ask("y");\n`,
        "src/icons.json": "{}",
    });
    assert.deepEqual(await unsupportedByCommand(folder), { typed: [] });
});

test("files are found ignoring case, as APFS and the build find them", async () => {
    const folder = extension(["subscriptions"], {
        "src/Subscriptions.tsx": view(`import { ask } from "./Lib/AI";\nask();`),
        "src/lib/ai.ts": `import { AI } from "@raycast/api";\nexport const ask = () => AI.ask("x");\n`,
    });
    assert.deepEqual(await unsupportedByCommand(folder), { subscriptions: ["AI"] });
});

test("a command with an import that can't be followed counts as reaching the whole extension", async () => {
    const folder = extension(["outside", "missing", "fine"], {
        "src/outside.tsx": view(`import { x } from "../../elsewhere/thing";\nconsole.log(x);`),
        "src/fine.tsx": view(),
        "src/other.ts": `import { AI } from "@raycast/api";\nexport const ask = () => AI.ask("x");\n`,
    });
    const result = await scanExtension(folder, options);
    assert.deepEqual(
        result.commands.map((command) => [command.name, command.unsupported, command.traced]),
        [
            ["outside", ["AI"], false],
            ["missing", ["AI"], false],
            ["fine", [], true],
        ],
    );
});

test("resolveImport tells the extension's own files from packages and data", async () => {
    const known = knownFiles(["src/a.ts", "src/lib/index.tsx", "src/b.tsx"]);
    assert.equal(resolveImport("src/b.tsx", "./a", known), "src/a.ts");
    assert.equal(resolveImport("src/b.tsx", "./a.js", known), "src/a.ts");
    assert.equal(resolveImport("src/b.tsx", "./lib", known), "src/lib/index.tsx");
    assert.equal(resolveImport("src/lib/index.tsx", "..", known), undefined, "src/index.* doesn't exist");
    assert.equal(resolveImport("src/b.tsx", "~/a", known), "src/a.ts");
    assert.equal(resolveImport("src/b.tsx", "react", known), "package");
    assert.equal(resolveImport("src/b.tsx", "@scope/package", known), "package");
    assert.equal(resolveImport("src/b.tsx", "../assets/list.json", known), "data");
    assert.equal(resolveImport("src/b.tsx", "../../outside", known), undefined);
    assert.equal(resolveImport("src/b.tsx", "#internal", known), undefined);
    assert.deepEqual(
        imports(await toJavaScript(`export { a } from "./a";\nimport "./side";\nexport * as b from "./b";`, "x.ts")).sort(),
        ["./a", "./b", "./side"],
    );
});
