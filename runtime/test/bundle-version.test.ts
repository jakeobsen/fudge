import { test } from "node:test";
import assert from "node:assert/strict";
import { shortVersion } from "../scripts/bundle-version.ts";

test("CFBundleShortVersionString is the version tag's major, minor and patch, for every describe", () => {
    const cases: [string, string][] = [
        ["v0.3.0", "0.3.0"],
        ["v0.3.0\n", "0.3.0"],
        ["v1.2.0-rc.1", "1.2.0"],
        ["v0.3.0-14-ga539cdd", "0.3.0"],
        ["v0.3.0-14-ga539cdd-dirty", "0.3.0"],
        ["v0.3.0-dirty", "0.3.0"],
        ["v1.2.0-rc.1-3-gabc1234", "1.2.0"],
        ["v1.2.0+build.7-2-gabc1234", "1.2.0"],
        ["v10.20.30", "10.20.30"],
        // No version tag.
        ["a539cdd", "0.0.0"],
        ["a539cdd-dirty", "0.0.0"],
        ["nightly-3-gabc1234", "0.0.0"],
        ["v1.2", "0.0.0"],
        ["v01.2.3", "0.0.0"],
        ["dev", "0.0.0"],
        ["", "0.0.0"],
    ];
    for (const [describe, expected] of cases) assert.equal(shortVersion(describe), expected, JSON.stringify(describe));
});
