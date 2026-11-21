import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// scripts/release.sh's --version (SPEC-128 §3): the release workflow passes the version in the tag's form (v0.2.0),
// and `make release` whatever `git describe --tags --always` says. A bare 0.2.0 is refused, since the app would call
// itself 0.0.0. Each run here stops at the signing variables, with only APPLE_ID set, which the script checks after
// --version and before it builds anything, so nothing is built and nothing is signed.
const root = fileURLToPath(new URL("../..", import.meta.url));
const script = fileURLToPath(new URL("../../scripts/release.sh", import.meta.url));

const signing = ["APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID"];

function environment(): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...process.env, APPLE_ID: "someone@example.com" };
    for (const name of signing) if (name !== "APPLE_ID") delete env[name];
    // Not a make of `make test`'s own, whose flags a nested make would inherit.
    delete env.MAKEFLAGS;
    delete env.MAKELEVEL;
    delete env.MFLAGS;
    return env;
}

function run(command: string, args: string[]): { status: number | null; stdout: string; stderr: string } {
    const result = spawnSync(command, args, { cwd: root, env: environment(), encoding: "utf8" });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

const refusedVersion = /--version takes the version in the tag's form/;
const stoppedAtSigning = /these signing variables aren't set: APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID/;

test("a bare version is refused, with the tag's form it should have", () => {
    for (const version of ["0.1.0", "10.20.30", "1.2.0-rc.1"]) {
        const result = run("bash", [script, "--version", version]);
        assert.equal(result.status, 1, version);
        assert.match(result.stderr, refusedVersion, version);
        assert.match(result.stderr, new RegExp(`v${version.replaceAll(".", "\\.")}`), version);
        assert.doesNotMatch(result.stderr, stoppedAtSigning, version);
    }
});

test("the tag's form and what git describe gives get past --version", () => {
    for (const version of ["v0.1.0", "v1.2.0-rc.1", "v0.1.0-14-ga539cdd", "9c097af", "36839cffab8269fc3e516ce137c68d5f22e8d096", "dev"]) {
        const result = run("bash", [script, "--version", version]);
        assert.equal(result.status, 1, version);
        assert.doesNotMatch(result.stderr, refusedVersion, version);
        assert.match(result.stderr, stoppedAtSigning, version);
    }
});

test("make release passes its git describe, whatever it is, and a version on the command line the same way", () => {
    for (const args of [["release"], ["release", "VERSION=9c097af"], ["release", "VERSION=v0.1.0-14-ga539cdd"]]) {
        const result = run("make", ["--no-print-directory", ...args]);
        assert.equal(result.status, 2, args.join(" "));
        assert.doesNotMatch(result.stderr, refusedVersion, args.join(" "));
        assert.match(result.stderr, stoppedAtSigning, args.join(" "));
    }
    const refused = run("make", ["--no-print-directory", "release", "VERSION=0.1.0"]);
    assert.equal(refused.status, 2);
    assert.match(refused.stderr, refusedVersion);
});
