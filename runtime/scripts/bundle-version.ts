// The version `make app` writes into Fudge.app's CFBundleShortVersionString, from the build's
// `git describe --tags --always --dirty` (the Makefile's VERSION):
//
//   node scripts/bundle-version.ts <describe>
//
// It's the major, minor and patch of the version tag the build is at or after (`v0.3.0-14-ga539cdd` is `0.3.0`,
// `v1.2.0-rc.1` is `1.2.0`), as macOS expects that key to hold, and `0.0.0` without one. The whole describe goes into
// FudgeGitDescribe beside it, and Fudge shows its own form of that (FudgeVersion.display, core).

import { fileURLToPath } from "node:url";

const identifier = "(?:0|[1-9]\\d*|\\d*[A-Za-z-][0-9A-Za-z-]*)";
const semanticVersion = new RegExp(
    `^(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(?:-${identifier}(?:\\.${identifier})*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$`,
);

export function shortVersion(describe: string): string {
    let rest = describe.trim();
    if (rest.endsWith("-dirty")) rest = rest.slice(0, -"-dirty".length);
    rest = rest.match(/^(.+)-[0-9]+-g[0-9a-f]{4,64}$/)?.[1] ?? rest;
    const version = rest.startsWith("v") ? rest.slice(1).match(semanticVersion) : null;
    return version ? `${version[1]}.${version[2]}.${version[3]}` : "0.0.0";
}

if (import.meta.url.endsWith("/bundle-version.ts") && process.argv[1] === fileURLToPath(import.meta.url)) {
    console.log(shortVersion(process.argv[2] ?? ""));
}
