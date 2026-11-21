import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// scripts/next-version.sh, which names the release a merge into mainline publishes (SPEC-128 §2), in throwaway
// repositories: the release workflow runs it only on that merge, so this is the one place it's tried before then.
const script = fileURLToPath(new URL("../../scripts/next-version.sh", import.meta.url));
// No configuration of the user's or the system's, so a signing or hook setting can't change what git does here.
const env = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };

function git(cwd: string, ...args: string[]): string {
    return execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", ...args], {
        cwd,
        env,
        encoding: "utf8",
        stdio: "pipe",
    }).trim();
}

/** A commit with `message` on top of what's there. */
function commit(cwd: string, message: string): void {
    git(cwd, "commit", "--quiet", "--allow-empty", "--message", message);
}

function nextVersion(cwd: string, ...args: string[]): { status: number | null; stdout: string; stderr: string } {
    const result = spawnSync("bash", [script, ...args], { cwd, env, encoding: "utf8" });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

/** The version the script prints, failing the test if it fails. */
function next(cwd: string, ...args: string[]): string {
    const result = nextVersion(cwd, ...args);
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
}

function withRepository(run: (cwd: string) => void): void {
    const cwd = mkdtempSync(join(tmpdir(), "fudge-next-version-"));
    try {
        git(cwd, "init", "--quiet", "--initial-branch", "mainline");
        run(cwd);
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
}

test("without a release in the history, the next is v0.1.0", () => {
    withRepository((cwd) => {
        commit(cwd, "feat: the first feature");
        commit(cwd, "feat!: and a breaking one");
        git(cwd, "tag", "not-a-release");
        git(cwd, "tag", "v0.1.0-rc.1");
        assert.equal(next(cwd), "v0.1.0\n");
    });
});

test("a feat bumps the minor version, with or without a scope, and only fixes the patch version", () => {
    const cases: [messages: string[], expected: string][] = [
        [["fix: a fix"], "v1.2.4"],
        [["docs: a page", "chore: tidy", "fix(app): a fix", "refactor: moves", "anything at all"], "v1.2.4"],
        [["fix: a fix", "feat: a feature"], "v1.3.0"],
        [["feat(app): a scoped feature"], "v1.3.0"],
        [["Feat(runtime): any case"], "v1.3.0"],
        // Not conventional for a feature: a type that only starts with feat, or feat outside the subject.
        [["feature: almost", "fix: mentions\n\nfeat: in the body"], "v1.2.4"],
    ];
    for (const [messages, expected] of cases) {
        withRepository((cwd) => {
            commit(cwd, "feat: before the release");
            git(cwd, "tag", "v1.2.3");
            for (const message of messages) commit(cwd, message);
            assert.equal(next(cwd), `${expected}\n`, messages.join(" | "));
        });
    }
});

test("a breaking change bumps the minor version below 1.0.0, and the major version from 1.0.0 on", () => {
    const breaking = [
        "feat!: a breaking feature",
        "fix(app)!: a breaking fix",
        "fix: a fix\n\nBREAKING CHANGE: the old setting is gone",
        "chore: tidy\n\nThe body.\n\nBREAKING-CHANGE: so is this",
    ];
    for (const message of breaking) {
        for (const [last, expected] of [
            ["v0.4.2", "v0.5.0"],
            ["v1.0.0", "v2.0.0"],
            ["v1.4.2", "v2.0.0"],
        ]) {
            withRepository((cwd) => {
                commit(cwd, "fix: before the release");
                git(cwd, "tag", last);
                commit(cwd, "fix: a fix");
                commit(cwd, message);
                commit(cwd, "feat: a feature");
                assert.equal(next(cwd), `${expected}\n`, `${last}: ${message}`);
            });
        }
    }
    // Only the footer's own words count, at the start of a line.
    withRepository((cwd) => {
        commit(cwd, "fix: before the release");
        git(cwd, "tag", "v1.0.0");
        commit(cwd, "fix: says breaking change: in the subject\n\nAnd mentions a BREAKING CHANGE: mid-line.");
        assert.equal(next(cwd), "v1.0.1\n");
    });
});

test("merge commits are ignored, and the commits they bring in count", () => {
    withRepository((cwd) => {
        commit(cwd, "fix: before the release");
        git(cwd, "tag", "v0.1.0");
        git(cwd, "checkout", "--quiet", "-b", "development");
        commit(cwd, "fix: on development");
        git(cwd, "checkout", "--quiet", "mainline");
        git(cwd, "merge", "--quiet", "--no-ff", "--message", "feat!: a merge's message doesn't count", "development");
        assert.equal(next(cwd), "v0.1.1\n");
    });
});

test("the last release is the highest full release in the history, not the newest tag or one on another branch", () => {
    withRepository((cwd) => {
        commit(cwd, "fix: one");
        git(cwd, "tag", "v0.9.0");
        commit(cwd, "fix: two");
        git(cwd, "tag", "v0.10.0");
        commit(cwd, "fix: three");
        // Older numbers tagged later, and a pre-release, don't count.
        git(cwd, "tag", "v0.2.0");
        git(cwd, "tag", "v0.11.0-rc.1");
        // A release on another branch isn't in this history.
        git(cwd, "checkout", "--quiet", "-b", "elsewhere");
        commit(cwd, "fix: elsewhere");
        git(cwd, "tag", "v3.0.0");
        git(cwd, "checkout", "--quiet", "mainline");
        commit(cwd, "fix: four");
        assert.equal(next(cwd), "v0.10.1\n");
    });
});

test("a tag on a release commit is found from the merge that brings it into mainline and from later development", () => {
    withRepository((cwd) => {
        commit(cwd, "feat: the start");
        git(cwd, "checkout", "--quiet", "-b", "development");
        commit(cwd, "feat: the first feature");
        // The first release: release/v0.1.0 at this development commit, merged into mainline, and its tag on the
        // release commit, the merge's second parent.
        assert.equal(next(cwd), "v0.1.0\n");
        git(cwd, "branch", "release/v0.1.0");
        git(cwd, "checkout", "--quiet", "mainline");
        git(cwd, "merge", "--quiet", "--no-ff", "--message", "Merge release/v0.1.0", "release/v0.1.0");
        git(cwd, "tag", "v0.1.0", "HEAD^2");
        assert.equal(nextVersion(cwd).status, 1, "nothing new on mainline since v0.1.0");
        // Later development has the tag in its history.
        git(cwd, "checkout", "--quiet", "development");
        commit(cwd, "fix: after the first release");
        assert.equal(next(cwd), "v0.1.1\n");
        // The next release's merge, through its second parent.
        git(cwd, "branch", "release/v0.1.1");
        git(cwd, "checkout", "--quiet", "mainline");
        git(cwd, "merge", "--quiet", "--no-ff", "--message", "Merge release/v0.1.1", "release/v0.1.1");
        assert.equal(next(cwd, "HEAD^2"), "v0.1.1\n");
        assert.equal(next(cwd), "v0.1.1\n");
        // A commit named instead of HEAD.
        git(cwd, "checkout", "--quiet", "development");
        commit(cwd, "feat: after that");
        assert.equal(next(cwd, "mainline"), "v0.1.1\n");
        assert.equal(next(cwd), "v0.2.0\n");
    });
});

test("with nothing since the last release, there's nothing to release", () => {
    withRepository((cwd) => {
        commit(cwd, "fix: a fix");
        commit(cwd, "feat: a feature");
        git(cwd, "tag", "v0.1.0");
        let result = nextVersion(cwd);
        assert.equal(result.status, 1);
        assert.equal(result.stdout, "");
        assert.match(result.stderr, /nothing to release: no commits since v0\.1\.0/);
        // Only a merge since then, of commits already released, is still nothing.
        const merge = git(cwd, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-p", "HEAD~1", "-m", "feat: Merge");
        git(cwd, "reset", "--quiet", "--hard", merge);
        result = nextVersion(cwd);
        assert.equal(result.status, 1);
        assert.equal(result.stdout, "");
        assert.match(result.stderr, /nothing to release/);
    });
});

test("a shallow clone can't see the releases, so it fails rather than guess", () => {
    withRepository((source) => {
        commit(source, "feat: a feature");
        git(source, "tag", "v0.1.0");
        commit(source, "fix: a fix");
        const clone = mkdtempSync(join(tmpdir(), "fudge-next-version-shallow-"));
        try {
            git(clone, "clone", "--quiet", "--depth", "1", `file://${source}`, ".");
            const result = nextVersion(clone);
            assert.equal(result.status, 1);
            assert.equal(result.stdout, "");
            assert.match(result.stderr, /shallow clone/);
        } finally {
            rmSync(clone, { recursive: true, force: true });
        }
    });
});

test("a commit that doesn't exist, or two of them, is refused", () => {
    withRepository((cwd) => {
        commit(cwd, "feat: a feature");
        let result = nextVersion(cwd, "no-such-commit");
        assert.equal(result.status, 1);
        assert.equal(result.stdout, "");
        assert.match(result.stderr, /no-such-commit isn't a commit/);
        result = nextVersion(cwd, "HEAD", "HEAD");
        assert.equal(result.status, 2);
        assert.equal(result.stdout, "");
    });
});
