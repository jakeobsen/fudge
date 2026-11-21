// `fudge scan <folder> [--json]`: the compatibility scan of one extension. The fudge tool runs this bundled
// (`Contents/Resources/runtime/compat-scan.js`) with node, and says where esbuild's binary and Raycast's types are:
// `FUDGE_ESBUILD` and `FUDGE_RAYCAST_TYPES`. Run from a checkout without them, it uses esbuild's JS API and the
// vendored types. Nothing is built or run.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createApiModule } from "../../src/api/module.ts";
import { raycastDeclarations, vendoredTypes } from "../raycast-types.ts";
import { binaryTransform, describe, report, scanExtension } from "./extension.ts";

const args = process.argv.slice(2);
const json = args.includes("--json");
const folders = args.filter((arg) => arg !== "--json");
if (folders.length !== 1 || folders[0]!.startsWith("--")) {
    console.error("usage: fudge scan <folder> [--json]");
    process.exit(2);
}
const folder = folders[0]!;
if (!existsSync(join(folder, "package.json")) || !existsSync(join(folder, "src"))) {
    console.error(`${folder} isn't an extension: it needs a package.json and a src folder`);
    process.exit(1);
}

const types = process.env.FUDGE_RAYCAST_TYPES ? readFileSync(process.env.FUDGE_RAYCAST_TYPES, "utf8") : vendoredTypes();
const esbuild = process.env.FUDGE_ESBUILD;
const result = await scanExtension(folder, {
    api: createApiModule() as Record<string, unknown>,
    declared: raycastDeclarations(types),
    transform: esbuild ? binaryTransform(esbuild) : undefined,
});
const scanned = report(folder, result);
console.log(json ? JSON.stringify(scanned, null, 2) : describe(scanned));
