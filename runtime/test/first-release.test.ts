import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// scripts/first-release.sh, which the release workflow runs on a tag to choose its notes (SPEC-117 §5), in throwaway
// repositories: it only runs on a real tag, so this is the one place it's tried before then.
const script = fileURLToPath(new URL("../../scripts/first-release.sh", import.meta.url));
// No configuration of the user's or the system's, so a signing or hook setting can't change what git does here.
const env = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };

function git(cwd: string, ...args: string[]): void {
    execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", ...args], { cwd, env, stdio: "pipe" });
}

/** A commit tagged `tag`, on top of what's there. */
function release(cwd: string, tag: string): void {
    git(cwd, "commit", "--quiet", "--allow-empty", "--message", tag);
    git(cwd, "tag", tag);
}

function firstRelease(cwd: string, tag: string): { status: number | null; stdout: string; stderr: string } {
    const result = spawnSync("bash", [script, tag], { cwd, env, encoding: "utf8" });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

function withRepository(run: (cwd: string) => void): void {
    const cwd = mkdtempSync(join(tmpdir(), "fudge-first-release-"));
    try {
        git(cwd, "init", "--quiet");
        run(cwd);
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
}

test("a tag is the first release until a full release is in its history, pre-releases not counting", () => {
    withRepository((cwd) => {
        const cases: [tag: string, others: string[], first: boolean][] = [
            ["v0.1.0-rc.1", [], true],
            ["v0.1.0-rc.2", [], true],
            ["v0.1.0", ["notes-unrelated"], true],
            ["v0.1.1-rc.1", [], false],
            ["v0.1.1", [], false],
        ];
        for (const [tag, others, first] of cases) {
            release(cwd, tag);
            for (const other of others) git(cwd, "tag", other);
            const result = firstRelease(cwd, tag);
            assert.equal(result.status, 0, result.stderr);
            assert.equal(result.stdout, `first=${first}\n`, tag);
        }
        // The first release's tag built again later: the later releases aren't in its history.
        git(cwd, "checkout", "--quiet", "--detach", "v0.1.0");
        assert.equal(firstRelease(cwd, "v0.1.0").stdout, "first=true\n");
    });
});

test("a shallow clone can't tell, so it fails rather than guess", () => {
    withRepository((source) => {
        release(source, "v0.1.0");
        release(source, "v0.1.1");
        const clone = mkdtempSync(join(tmpdir(), "fudge-first-release-shallow-"));
        try {
            git(clone, "clone", "--quiet", "--depth", "1", `file://${source}`, ".");
            const result = firstRelease(clone, "v0.1.1");
            assert.equal(result.status, 1);
            assert.equal(result.stdout, "");
            assert.match(result.stderr, /shallow clone/);
        } finally {
            rmSync(clone, { recursive: true, force: true });
        }
    });
});

test("a tag is required", () => {
    withRepository((cwd) => {
        const result = firstRelease(cwd, "");
        assert.notEqual(result.status, 0);
        assert.equal(result.stdout, "");
    });
});
