// The store's local copy of github.com/raycast/extensions: a shallow, blobless, sparse clone made with the system git.
import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { proxyVariables } from "./proxy.ts";
import { longTimeout, shortTimeout } from "./timeouts.ts";

export const repositoryURL = "https://github.com/raycast/extensions.git";
/** The copy is refreshed when the store opens and it's older than this. */
export const refreshAge = 24 * 60 * 60 * 1000;

export type GitResult = { code: number; stdout: string; stderr: string };
/** How long a cancelled program has to end after SIGTERM before it gets SIGKILL. */
export const cancelGrace = 1000;
/**
 * Runs a program with an argument array, never through a shell, writing `input` to its stdin when given, with `env`
 * added to `storeEnvironment()`. A `stoppable` one ends with `stopRunningGit()`. One given a `signal` runs in a process
 * group of its own and ends when it aborts, with everything it started (git's `git-remote-https`, say): SIGTERM to
 * the group, then SIGKILL if it's still running a second later. Only a step that writes nothing but new packs
 * is given one (`fetchSource`): a git that's writing the index holds `index.lock`, and ending it would leave that
 * behind, so every later checkout and install would fail.
 */
export type Run = (
    program: string,
    args: string[],
    options: {
        cwd?: string;
        timeout: number;
        stoppable?: boolean;
        input?: string;
        env?: NodeJS.ProcessEnv;
        signal?: AbortSignal;
    },
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
    return {
        ...base,
        // The Mac's proxy, where none is set (SPEC-116 §3); `fudge build` passes it on to npm.
        ...proxyVariables(base),
        GIT_TERMINAL_PROMPT: "0",
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_GLOBAL: "/dev/null",
    };
}

/**
 * `spawn` with no shell, a timeout that sends SIGTERM, and `storeEnvironment()`. When the timeout fired, stderr ends
 * with "<program> stopped after N s", whatever the exit: `fudge` catches SIGTERM and exits with 143.
 */
export const spawnProgram: Run = (program, args, { cwd, timeout, stoppable, input, env, signal }) =>
    new Promise((resolve) => {
        if (signal?.aborted) {
            resolve({ code: -1, stdout: "", stderr: `${path.basename(program)} cancelled` });
            return;
        }
        const child = spawn(program, args, {
            cwd,
            stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
            env: { ...storeEnvironment(), ...env },
            detached: signal !== undefined,
        });
        const group = (signal: NodeJS.Signals) => {
            try {
                if (child.pid !== undefined) process.kill(-child.pid, signal);
            } catch {
                // The group has ended already.
            }
        };
        let timedOut = false;
        const timer = setTimeout(() => {
            timedOut = true;
            // SIGTERM, not SIGKILL: `fudge scan` and `fudge build` pass it on to everything they started. A program in
            // a group of its own gets it with everything it started.
            if (signal) group("SIGTERM");
            else child.kill("SIGTERM");
        }, timeout);
        if (stoppable) running.add(child);
        let killTimer: NodeJS.Timeout | undefined;
        const cancel = () => {
            group("SIGTERM");
            killTimer = setTimeout(() => group("SIGKILL"), cancelGrace);
        };
        signal?.addEventListener("abort", cancel, { once: true });
        const finished = () => {
            clearTimeout(timer);
            clearTimeout(killTimer);
            signal?.removeEventListener("abort", cancel);
            running.delete(child);
        };
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
            finished();
            resolve({ code: -1, stdout, stderr: error.message });
        });
        child.on("close", (code, signal) => {
            finished();
            if (timedOut) stderr += `\n${path.basename(program)} stopped after ${timeout / 1000} s`;
            else if (code === null) stderr += `\n${path.basename(program)} stopped (${signal ?? "killed"})`;
            resolve({ code: code ?? -1, stdout, stderr });
        });
    });

/** A git command that failed; its message is git's stderr, and `command` what ran, for a failure's report. */
export class GitError extends Error {
    readonly command: string | undefined;
    constructor(message: string, command?: string) {
        super(message);
        this.command = command;
    }
}

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

/**
 * Asks macOS to install the Command Line Tools, which bring git: `xcode-select --install` shows macOS's own installer
 * and returns at once. Only ever run from the user's own action (Install Command Line Tools), never by itself.
 * Resolves undefined once the installer is up, or what `xcode-select` said when it couldn't start it (the tools are
 * installed already, say).
 */
export async function installCommandLineTools(run: Run = spawnProgram): Promise<string | undefined> {
    const result = await run("/usr/bin/xcode-select", ["--install"], { timeout: shortTimeout });
    if (result.code === 0) return undefined;
    return (result.stderr || result.stdout).trim() || `xcode-select exited with ${result.code}`;
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

    async #exec(
        args: string[],
        timeout = shortTimeout,
        cwd = this.path,
        input?: string,
        extra: { env?: NodeJS.ProcessEnv; signal?: AbortSignal } = {},
    ): Promise<string> {
        const result = await this.#run(this.#git, args, { cwd, timeout, stoppable: true, input, ...extra });
        if (result.code !== 0) {
            throw new GitError(result.stderr.trim() || `git ${args[0]} failed`, ["git", ...args].join(" "));
        }
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

    /** Adds patterns to the checkout, fetching their files. Each pattern is built from a checked name. */
    async add(...patterns: string[]): Promise<void> {
        await this.#exec(["sparse-checkout", "add", ...patterns], longTimeout);
    }

    /**
     * Adds patterns whose files are already downloaded (`fetchSource`), with git's lazy fetch off
     * (`GIT_NO_LAZY_FETCH`, git 2.44 and later), so this step only writes the checkout and never downloads.
     */
    async addFetched(...patterns: string[]): Promise<void> {
        await this.#exec(["sparse-checkout", "add", ...patterns], longTimeout, this.path, undefined, {
            env: { GIT_NO_LAZY_FETCH: "1" },
        });
    }

    /**
     * Downloads the files under `extensions/<dir>/src/` of at most `limit` bytes each, and nothing else: the folder's
     * tree fetched again (`--refetch`, since the copy has every tree already) with a `blob:limit` filter, which the
     * server applies to what it finds under the tree. Asked for by their own ids instead, git would send every blob,
     * whatever its size. It writes only new packs, never the index, the refs or `FETCH_HEAD`, and no maintenance runs
     * after it, so it's the one step a cancel ends (`signal`): that only stops a download. `dir` is a checked folder.
     */
    async fetchSource(dir: string, limit: number, signal?: AbortSignal): Promise<void> {
        const tree = (await this.#exec(["rev-parse", "--verify", `HEAD:extensions/${dir}/src`])).trim();
        await this.#exec(
            [
                "fetch",
                "--refetch",
                "--no-write-fetch-head",
                "--no-tags",
                "--no-auto-maintenance",
                "--no-auto-gc",
                `--filter=blob:limit=${limit}`,
                "origin",
                tree,
            ],
            longTimeout,
            this.path,
            undefined,
            { signal },
        );
    }

    /**
     * How many of the files under `extensions/<dir>/src/` aren't downloaded: after `fetchSource`, the ones over its
     * limit. `rev-list --missing=print` names them without fetching them, on any git. `dir` is a checked folder.
     */
    async missingSource(dir: string): Promise<number> {
        const output = await this.#exec(["rev-list", "--objects", "--missing=print", `HEAD:extensions/${dir}/src`]);
        return output.split("\n").filter((line) => line.startsWith("?")).length;
    }

    /**
     * Takes these exact patterns out of the checkout again, keeping every other, so a later refresh doesn't fetch
     * their files' changes. Their files leave the working tree, but what was downloaded stays in `.git` as long as the
     * copy's commit reaches it: a refresh keeps every object its new commit reaches (`#keepOnlyReachable`), so only a
     * file that changed or went upstream is pruned. Nothing prunes the rest: `gc` can't run in this clone, and a
     * repack that left out blobs would take the checked-out manifests with them, which the list reads.
     */
    async drop(patterns: string[]): Promise<void> {
        const current = (await this.#exec(["sparse-checkout", "list"])).split("\n").filter(Boolean);
        const kept = current.filter((line) => !patterns.includes(line));
        if (kept.length === current.length) return;
        await this.#exec(["sparse-checkout", "set", "--no-cone", "--stdin"], longTimeout, this.path, `${kept.join("\n")}\n`);
    }

    /**
     * The files under `extensions/<dir>/src/`, relative to it, read from the trees alone: a blobless clone has every
     * tree, so nothing is downloaded. `dir` is a checked folder.
     */
    async sourceFiles(dir: string): Promise<string[]> {
        const prefix = `extensions/${dir}/src/`;
        const output = await this.#exec(["ls-tree", "-r", "-z", "--name-only", "HEAD", "--", prefix]);
        return output
            .split("\0")
            .filter((name) => name.startsWith(prefix))
            .map((name) => name.slice(prefix.length));
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
