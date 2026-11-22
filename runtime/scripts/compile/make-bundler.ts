// Bundles `fudge build`'s compile step (`bundle.ts`) into one CommonJS file, with esbuild's JavaScript inside, which
// `make app` ships as `Contents/Resources/runtime/bundle-extension.cjs`. `npm run build` writes it to
// `dist/bundle-extension.cjs`, and the tests make their own copy the same way.
//
//   node scripts/compile/make-bundler.ts <output file>

import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

/** How the compile step is bundled. CommonJS, so esbuild's own code and its `require`s run as they are. */
export const bundlerOptions = {
    entryPoints: [fileURLToPath(new URL("./bundle.ts", import.meta.url))],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node22",
    logLevel: "warning",
    // esbuild's API asks `require.resolve` for its platform package, which it never reaches here: the shipped script
    // always runs with ESBUILD_BINARY_PATH. Only that warning is silenced.
    logOverride: { "require-resolve-not-external": "silent" },
} satisfies esbuild.BuildOptions;

export async function makeBundler(outfile: string): Promise<esbuild.BuildResult> {
    return await esbuild.build({ ...bundlerOptions, outfile });
}

if (import.meta.url.endsWith("/make-bundler.ts") && process.argv[1] === fileURLToPath(import.meta.url)) {
    const outfile = process.argv[2];
    if (!outfile) throw new Error("usage: make-bundler.ts <output file>");
    await makeBundler(outfile);
}
