// `fudge build`'s compile step (`ExtensionBuilder`): esbuild's JavaScript API with the options the tool wrote, and the
// `rust:` and `swift:` plugins, which esbuild's command line can't take. Shipped as `bundle-extension.cjs`, with esbuild's
// JavaScript inside; it drives the esbuild program named by `ESBUILD_BINARY_PATH`.
//
//   node bundle-extension.cjs <request.json>     the request: { "extension": <folder>, "options": <esbuild's options> }
//
// esbuild prints its own warnings and errors, as its command line does, so a failed build adds nothing to them and
// exits 1. Anything else that goes wrong is printed.

import { readFileSync } from "node:fs";
import * as esbuild from "esbuild";
import { rustPlugin } from "./rust.ts";
import { swiftPlugin } from "./swift.ts";

export type BundleRequest = { extension: string; options: esbuild.BuildOptions };

export async function bundle(request: BundleRequest): Promise<void> {
    await esbuild.build({ ...request.options, plugins: [rustPlugin(request.extension), swiftPlugin()] });
}

/** Whether `error` is esbuild's report of a failed build, whose messages esbuild has already printed. */
function isBuildFailure(error: unknown): boolean {
    return error instanceof Error && Array.isArray((error as Partial<esbuild.BuildFailure>).errors);
}

async function main(file: string | undefined): Promise<void> {
    try {
        if (!file) throw new Error("usage: bundle-extension <request.json>");
        await bundle(JSON.parse(readFileSync(file, "utf8")) as BundleRequest);
    } catch (error) {
        if (!isBuildFailure(error)) process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
        process.exitCode = 1;
    }
}

void main(process.argv[2]);
