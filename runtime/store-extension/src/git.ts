// The store's local copy of github.com/raycast/extensions: a shallow, blobless, sparse clone made with the system git.
import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";

export const repositoryURL = "https://github.com/raycast/extensions.git";
/** Clone, fetch and fetching files on demand can take a while on a slow connection. */
export const longTimeout = 120_000;
export const shortTimeout = 30_000;
/** The copy is refreshed when the store opens and it's older than this. */
export const refreshAge = 24 * 60 * 60 * 1000;

export type GitResult = { code: number; stdout: string; stderr: string };
/** Runs a program with an argument array, never through a shell. A `stoppable` one ends with `stopRunningGit()`. */
export type Run = (
    program: string,
    args: string[],
    options: { cwd?: string; timeout: number; stoppable?: boolean },
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
 * The environment every program the store runs gets. Git never asks for a password (`GIT_TERMINAL_PROMPT=0`), and
 * ignores the user's own git configuration: a global `url.<base>.insteadOf` could send the clone to SSH, or anywhere,
 * instead of the https address the consent text names.
 */
export function storeEnvironment(base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
    return { ...base, GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" };
}

/** `spawn` with no shell, a timeout, and `storeEnvironment()`. */
export const spawnProgram: Run = (program, args, { cwd, timeout, stoppable }) =>
    new Promise((resolve) => {
        const child = spawn(program, args, { cwd, timeout, stdio: ["ignore", "pipe", "pipe"], env: storeEnvironment() });
        if (stoppable) running.add(child);
        let stdout = "";
        let stderr = "";
        child.stdout.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
        child.stderr.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
        child.on("error", (error) => {
            running.delete(child);
            resolve({ code: -1, stdout, stderr: error.message });
        });
        child.on("close", (code, signal) => {
            running.delete(child);
            if (code === null) stderr += `\n${path.basename(program)} stopped (${signal ?? "killed"}) after ${timeout / 1000} s`;
            resolve({ code: code ?? -1, stdout, stderr });
        });
    });

/** A git command that failed; its message is git's stderr. */
export class GitError extends Error {}

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

    async #exec(args: string[], timeout = shortTimeout, cwd = this.path): Promise<string> {
        const result = await this.#run(this.#git, args, { cwd, timeout, stoppable: true });
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
        await this.#exec(["checkout"]);
        await this.#markRefreshed();
    }

    /** Fetches the default branch's newest commit, checks it out, and drops what the old one left behind. */
    async refresh(): Promise<void> {
        const branch = await this.defaultBranch();
        await this.#exec(["fetch", "--depth", "1", "--filter=blob:none", "origin", branch], longTimeout);
        await this.#exec(["checkout", "--quiet", "FETCH_HEAD"]);
        await this.#exec(["reflog", "expire", "--expire=now", "--all"]);
        await this.#exec(["gc", "--prune=now", "--quiet"], longTimeout);
        await this.#markRefreshed();
    }

    /** `main`, from the clone's `origin/HEAD`. */
    async defaultBranch(): Promise<string> {
        const ref = (await this.#exec(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])).trim();
        return ref.replace(/^origin\//, "");
    }

    /** Adds a pattern to the checkout, fetching its files. `pattern` is built from a checked name. */
    async add(pattern: string): Promise<void> {
        await this.#exec(["sparse-checkout", "add", pattern], longTimeout);
    }

    async commit(): Promise<string> {
        return (await this.#exec(["rev-parse", "HEAD"])).trim();
    }

    /** The tree id of every folder under `extensions/`, by name: one call, and no file contents needed. */
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
