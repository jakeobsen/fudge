// The store's local copy of github.com/raycast/extensions: a shallow, blobless, sparse clone made with the system git.
import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { longTimeout, shortTimeout } from "./timeouts.ts";

export const repositoryURL = "https://github.com/raycast/extensions.git";
/** The copy is refreshed when the store opens and it's older than this. */
export const refreshAge = 24 * 60 * 60 * 1000;

export type GitResult = { code: number; stdout: string; stderr: string };
/**
 * Runs a program with an argument array, never through a shell, writing `input` to its stdin when given. A
 * `stoppable` one ends with `stopRunningGit()`.
 */
export type Run = (
    program: string,
    args: string[],
    options: { cwd?: string; timeout: number; stoppable?: boolean; input?: string },
) => Promise<GitResult>;

/** The git processes running now, which `stopRunningGit()` ends. */
const running = new Set<ChildProcess>();

/**
 * Ends every git process the store started. The store calls it when it's unloaded, so a refresh can't go on writing
 * into `repo/` after the store is closed, or while turning the store off deletes it.
 */
export function stopRunningGit(): void {
    for (const child of running) child.kill("SIGTERM");
}

/**
 * The environment every program the store runs gets: git never asks for a password (`GIT_TERMINAL_PROMPT=0`), and
 * ignores the user's own git configuration, so it clones the repository's address exactly as given.
 */
export function storeEnvironment(base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
    return { ...base, GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" };
}

/**
 * `spawn` with no shell, a timeout that sends SIGTERM, and `storeEnvironment()`. When the timeout fired, stderr ends
 * with "<program> stopped after N s", whatever the exit: `fudge` catches SIGTERM and exits with 143.
 */
export const spawnProgram: Run = (program, args, { cwd, timeout, stoppable, input }) =>
    new Promise((resolve) => {
        const child = spawn(program, args, {
            cwd,
            stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
            env: storeEnvironment(),
        });
        let timedOut = false;
        const timer = setTimeout(() => {
            timedOut = true;
            // SIGTERM, not SIGKILL: `fudge scan` and `fudge build` pass it on to everything they started.
            child.kill("SIGTERM");
        }, timeout);
        if (stoppable) running.add(child);
        if (input !== undefined && child.stdin) {
            // A program that exits early closes its stdin; its exit status says what went wrong.
            child.stdin.on("error", () => undefined);
            child.stdin.end(input);
        }
        let stdout = "";
        let stderr = "";
        child.stdout?.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
        child.stderr?.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
        child.on("error", (error) => {
            clearTimeout(timer);
            running.delete(child);
            resolve({ code: -1, stdout, stderr: error.message });
        });
        child.on("close", (code, signal) => {
            clearTimeout(timer);
            running.delete(child);
            if (timedOut) stderr += `\n${path.basename(program)} stopped after ${timeout / 1000} s`;
            else if (code === null) stderr += `\n${path.basename(program)} stopped (${signal ?? "killed"})`;
            resolve({ code: code ?? -1, stdout, stderr });
        });
    });

/** A git command that failed; its message is git's stderr. */
export class GitError extends Error {}

/**
 * Whether `name` is a plain branch name, by `git check-ref-format --branch`'s rules and stricter: letters, digits and
 * `._/+-`, not starting with `-`, `.` or `/`, with no `..` or `//`, and no part that starts with `.`, ends with `.lock`
 * or is empty. The default branch's name comes from the remote, so it's checked before it's used in a ref.
 */
export function isValidBranch(name: string): boolean {
    return (
        /^[A-Za-z0-9_][A-Za-z0-9._/+-]*$/.test(name) &&
        !name.includes("..") &&
        !name.endsWith(".") &&
        name.split("/").every((part) => part.length > 0 && !part.startsWith(".") && !part.endsWith(".lock"))
    );
}

/**
 * Whether git can run, checked without ever triggering macOS's offer to install the Command Line Tools: `/usr/bin/git`
 * shows that offer when the tools are missing, so `xcode-select -p` is asked first.
 */
export async function gitAvailable(run: Run = spawnProgram, git = "/usr/bin/git"): Promise<boolean> {
    const tools = await run("/usr/bin/xcode-select", ["-p"], { timeout: shortTimeout });
    if (tools.code !== 0) return false;
    const version = await run(git, ["--version"], { timeout: shortTimeout });
    return version.code === 0 && !/developer tools/i.test(version.stderr);
}

/** The clone in `<supportPath>/repo`. Every path or pattern built from an extension's name is checked by the caller. */
export class StoreRepository {
    readonly path: string;
    readonly #run: Run;
    readonly #git: string;
    readonly #url: string;

    constructor(repoPath: string, options: { run?: Run; git?: string; url?: string } = {}) {
        this.path = repoPath;
        this.#run = options.run ?? spawnProgram;
        this.#git = options.git ?? "/usr/bin/git";
        this.#url = options.url ?? repositoryURL;
    }

    /** Where the time of the last clone or refresh is kept; inside `.git`, so it goes when the copy is deleted. */
    get #marker(): string {
        return path.join(this.path, ".git", "fudge-refreshed-at");
    }

    async #exec(args: string[], timeout = shortTimeout, cwd = this.path, input?: string): Promise<string> {
        const result = await this.#run(this.#git, args, { cwd, timeout, stoppable: true, input });
        if (result.code !== 0) throw new GitError(result.stderr.trim() || `git ${args[0]} failed`);
        return result.stdout;
    }

    /** Deletes the copy, to clone it again when it can't be read (a clone stopped halfway, say). */
    async remove(): Promise<void> {
        await rm(this.path, { recursive: true, force: true });
    }

    async exists(): Promise<boolean> {
        return stat(path.join(this.path, ".git")).then(
            (info) => info.isDirectory(),
            () => false,
        );
    }

    /** Clones with only `extensions/*\/package.json` checked out; blobs come on demand. */
    async clone(): Promise<void> {
        await mkdir(path.dirname(this.path), { recursive: true });
        await this.#exec(
            ["clone", "--depth", "1", "--filter=blob:none", "--sparse", "--no-checkout", this.#url, this.path],
            longTimeout,
            path.dirname(this.path),
        );
        await this.#exec(["sparse-checkout", "set", "--no-cone", "/extensions/*/package.json"]);
        // Fetches every extension's package.json.
        await this.#exec(["checkout"], longTimeout);
        await this.#markRefreshed();
    }

    /**
     * Fetches the default branch's newest commit into its remote-tracking ref, moves the branch there and checks it
     * out, then drops every other ref, the reflogs, and every object they no longer reach (`#keepOnlyReachable`).
     * `.git/shallow` then names only the new commit: the copy stays one commit deep however often it's refreshed.
     */
    async refresh(): Promise<void> {
        const branch = await this.defaultBranch();
        const local = `refs/heads/${branch}`;
        const tracking = `refs/remotes/origin/${branch}`;
        await this.#exec(
            ["fetch", "--depth", "1", "--filter=blob:none", "--no-tags", "origin", `+${local}:${tracking}`],
            longTimeout,
        );
        // Fetches the manifests that changed.
        await this.#exec(["checkout", "--quiet", "-B", branch, tracking, "--"], longTimeout);
        const kept = new Set([local, tracking, "refs/remotes/origin/HEAD"]);
        const refs = (await this.#exec(["for-each-ref", "--format=%(refname)"])).split("\n").filter(Boolean);
        for (const ref of refs.filter((ref) => !kept.has(ref))) {
            await this.#exec(["update-ref", "--no-deref", "-d", ref]);
        }
        await this.#exec(["reflog", "expire", "--expire=now", "--all"]);
        await this.#keepOnlyReachable();
        await this.#markRefreshed();
    }

    /**
     * Packs the objects the refs reach into one new pack, marked as the remote's (`.promisor`), deletes every other
     * pack, then prunes loose objects and the `.git/shallow` entries of commits that are gone. `gc` can't do this in a
     * blobless clone: it keeps every object that came from the remote, reachable or not, and its repack asks the
     * remote for the old commits `.git/shallow` still names. Nothing here downloads.
     */
    async #keepOnlyReachable(): Promise<void> {
        const objects = await this.#exec(
            ["rev-list", "--objects", "--no-object-names", "--all", "--missing=allow-promisor"],
            longTimeout,
        );
        const packs = path.join(this.path, ".git", "objects", "pack");
        const before = await readdir(packs).catch((): string[] => []);
        const hash = (
            await this.#exec(["pack-objects", "--quiet", path.join(packs, "pack")], longTimeout, this.path, objects)
        ).trim();
        if (!/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/.test(hash)) throw new GitError("git pack-objects didn't name its pack");
        await writeFile(path.join(packs, `pack-${hash}.promisor`), "");
        for (const file of before) {
            const old = /^(pack-[0-9a-f]+)\.pack$/.exec(file)?.[1];
            if (!old || old === `pack-${hash}`) continue;
            for (const suffix of [".pack", ".idx", ".rev", ".promisor", ".bitmap", ".mtimes", ".keep"]) {
                await rm(path.join(packs, `${old}${suffix}`), { force: true });
            }
        }
        // An index of several packs would still name the deleted ones.
        await rm(path.join(packs, "multi-pack-index"), { force: true });
        await this.#exec(["prune", "--expire=now", "--exclude-promisor-objects"], longTimeout);
    }

    /** `main`, from the clone's `origin/HEAD`. A name that isn't a plain branch name is refused (`isValidBranch`). */
    async defaultBranch(): Promise<string> {
        const ref = (await this.#exec(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])).trim();
        const branch = ref.replace(/^origin\//, "");
        if (!isValidBranch(branch)) {
            throw new GitError(`The store's copy names a default branch it can't use: ${JSON.stringify(branch)}`);
        }
        return branch;
    }

    /** Adds a pattern to the checkout, fetching its files. `pattern` is built from a checked name. */
    async add(pattern: string): Promise<void> {
        await this.#exec(["sparse-checkout", "add", pattern], longTimeout);
    }

    async commit(): Promise<string> {
        return (await this.#exec(["rev-parse", "HEAD"])).trim();
    }

    /** The tree id of every folder under `extensions/`, by folder: one call, and no file contents needed. */
    async trees(): Promise<Map<string, string>> {
        const output = await this.#exec(["ls-tree", "HEAD", "extensions/"]);
        const trees = new Map<string, string>();
        for (const line of output.split("\n")) {
            const match = /^\d+ tree ([0-9a-f]+)\textensions\/(.+)$/.exec(line);
            if (match) trees.set(match[2]!, match[1]!);
        }
        return trees;
    }

    /** When the copy was last cloned or refreshed; undefined when it's unknown. */
    async refreshedAt(): Promise<Date | undefined> {
        const text = await readFile(this.#marker, "utf8").catch(() => undefined);
        const date = text ? new Date(text.trim()) : undefined;
        return date && !Number.isNaN(date.getTime()) ? date : undefined;
    }

    async needsRefresh(now: Date): Promise<boolean> {
        const at = await this.refreshedAt();
        return !at || now.getTime() - at.getTime() > refreshAge;
    }

    async #markRefreshed(): Promise<void> {
        await writeFile(this.#marker, new Date().toISOString());
    }
}
