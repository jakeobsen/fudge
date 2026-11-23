// The store's local copy of github.com/raycast/extensions: a shallow, blobless, sparse clone made with the system git.
import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, open, readdir, readFile, rm, stat, writeFile, type FileHandle } from "node:fs/promises";
import path from "node:path";
import { proxyVariables } from "./proxy.ts";
import { longTimeout, shortTimeout } from "./timeouts.ts";

export const repositoryURL = "https://github.com/raycast/extensions.git";
/** The copy is refreshed when the store opens and it's older than this. */
export const refreshAge = 24 * 60 * 60 * 1000;

/** `stopped` is there when a run given `stopOn` saw its text, whether or not the signal ended it. */
export type GitResult = { code: number; stdout: string; stderr: string; stopped?: true };
/** How long a cancelled program has to end after SIGTERM before it gets SIGKILL. */
export const cancelGrace = 1000;
/**
 * Runs a program with an argument array, never through a shell, writing `input` to its stdin when given, with `env`
 * added to `storeEnvironment()`. A `stoppable` one ends with `stopRunningGit()`. One given a `signal` runs in a process
 * group of its own and ends when it aborts, with everything it started (git's `git-remote-https`, say): SIGTERM to
 * the group, then SIGKILL if it's still running a second later. Only a step that writes nothing but new packs
 * is given one (`fetchSource`): a git that's writing the index holds `index.lock`, and ending it would leave that
 * behind, so every later checkout and install would fail. `started` is called with the program's pid right after it
 * starts, and never for a program that couldn't start; it must not throw (the store records `fudge build` with it).
 * With `output` (two paths), the program's stdout and stderr are those files instead of pipes (SPEC-156 A.1): a program
 * that outlives the store's worker then never gets SIGPIPE, and its whole output stays.
 * With `stopOn` (SPEC-157 C.7), the program ends as an abort ends it, its group with it, as soon as that text is in the
 * stderr kept so far, so a text split across two reads still counts; it needs a `signal` for its group, and pipes.
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
        started?: (pid: number) => void;
        output?: ProgramOutput;
        stopOn?: string;
    },
) => Promise<GitResult>;

/** The files a program's stdout and stderr go to, made by the run (`wx+`, 0600, so it can read them back); the caller may rename them meanwhile. */
export type ProgramOutput = { stdout: string; stderr: string };

/** How much of each output file a run reads back: its end, which holds everything a failure keeps (`keptOutput`). */
export const maxOutputBytes = 1024 * 1024;

/**
 * The text of an output file through its descriptor, so a rename on the way doesn't matter: its last `maxOutputBytes`,
 * from the first line start inside them when the file is longer.
 */
export async function readOutputTail(handle: FileHandle, limit: number = maxOutputBytes): Promise<string> {
    const { size } = await handle.stat();
    const start = Math.max(0, size - limit);
    // One byte before the cut too: a newline there means the cut is at a line's start, and that line is kept whole.
    const from = start > 0 ? start - 1 : 0;
    const buffer = Buffer.alloc(size - from);
    let read = 0;
    while (read < buffer.length) {
        const { bytesRead } = await handle.read(buffer, read, buffer.length - read, from + read);
        if (bytesRead === 0) break;
        read += bytesRead;
    }
    let bytes = buffer.subarray(0, read);
    if (start > 0) {
        const newline = bytes.indexOf(0x0a);
        bytes = newline === -1 ? bytes.subarray(bytes.length) : bytes.subarray(newline + 1);
    }
    return bytes.toString("utf8");
}

/** Opens both output files for a run, or none: a pair that can't be made leaves nothing behind. */
async function openOutput(output: ProgramOutput): Promise<[FileHandle, FileHandle] | undefined> {
    let stdout: FileHandle | undefined;
    try {
        stdout = await open(output.stdout, "wx+", 0o600);
        const stderr = await open(output.stderr, "wx+", 0o600);
        return [stdout, stderr];
    } catch {
        if (stdout) {
            await stdout.close().catch(() => undefined);
            await rm(output.stdout, { force: true }).catch(() => undefined);
        }
        return undefined;
    }
}

/** The git processes running now, which `stopRunningGit()` ends. */
const running = new Set<ChildProcess>();

/**
 * Ends every git process the store started. The store calls it when it's unloaded, so a refresh can't go on writing
 * into `repo/` after the store is closed, or while turning the store off deletes it.
 */
export function stopRunningGit(): void {
    for (const child of running) child.kill("SIGTERM");
}

/** Whether an inherited variable adds git configuration: `GIT_CONFIG_COUNT`, its keys and values, and `-c`'s own. */
function addsGitConfig(name: string): boolean {
    return (
        name === "GIT_CONFIG_COUNT" ||
        name === "GIT_CONFIG_PARAMETERS" ||
        name.startsWith("GIT_CONFIG_KEY_") ||
        name.startsWith("GIT_CONFIG_VALUE_")
    );
}

/**
 * The environment every program the store runs gets: git never asks for a password (`GIT_TERMINAL_PROMPT=0`), and
 * ignores the user's own git configuration, so it clones the repository's address exactly as given. Configuration
 * passed down in the environment goes too (SPEC-157 C.4), so nothing adds a credential helper or a URL rewrite.
 */
export function storeEnvironment(base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
    const kept = Object.fromEntries(Object.entries(base).filter(([name]) => !addsGitConfig(name)));
    return {
        ...kept,
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
export const spawnProgram: Run = async (program, args, options) => {
    if (options.signal?.aborted) return { code: -1, stdout: "", stderr: `${path.basename(program)} cancelled` };
    // Stopping on a text ends the program's group, so it needs a group of its own, and reads stderr as it comes.
    if (options.stopOn !== undefined && (options.signal === undefined || options.output !== undefined)) {
        return { code: -1, stdout: "", stderr: `${path.basename(program)} wasn't started: stopOn needs a signal and pipes` };
    }
    // Files that can't be made fall back to pipes: the output files never stop a build (SPEC-153's rule for records).
    const files = options.output ? await openOutput(options.output) : undefined;
    try {
        return await spawnWith(program, args, options, files);
    } finally {
        for (const file of files ?? []) await file.close().catch(() => undefined);
    }
};

function spawnWith(
    program: string,
    args: string[],
    { cwd, timeout, stoppable, input, env, signal, started, stopOn }: Parameters<Run>[2],
    files: [FileHandle, FileHandle] | undefined,
): Promise<GitResult> {
    return new Promise((resolve) => {
        const child = spawn(program, args, {
            cwd,
            stdio: [input === undefined ? "ignore" : "pipe", files ? files[0].fd : "pipe", files ? files[1].fd : "pipe"],
            env: { ...storeEnvironment(), ...env },
            detached: signal !== undefined,
        });
        // A program that couldn't start has no pid (its `error` follows).
        if (child.pid !== undefined && started) {
            try {
                started(child.pid);
            } catch {
                // `started` never throws; if it did, the run goes on as it would have.
            }
        }
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
        let cancelled = false;
        const cancel = () => {
            if (cancelled) return;
            cancelled = true;
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
        // Where the next search for `stopOn` starts: the text may begin in what came before this chunk.
        let searched = 0;
        child.stdout?.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
        child.stderr?.setEncoding("utf8").on("data", (chunk: string) => {
            stderr += chunk;
            if (stopOn === undefined || cancelled) return;
            if (stderr.includes(stopOn, searched)) cancel();
            else searched = Math.max(0, stderr.length - stopOn.length + 1);
        });
        child.on("error", (error) => {
            finished();
            resolve({ code: -1, stdout, stderr: error.message });
        });
        child.on("close", async (code, signal) => {
            finished();
            if (files) {
                stdout = await readOutputTail(files[0]).catch(() => "");
                stderr = await readOutputTail(files[1]).catch(() => "");
            }
            // Seen at any point, even when the program ended by itself before the signal landed.
            const stopped = stopOn !== undefined && stderr.includes(stopOn);
            if (timedOut) stderr += `\n${path.basename(program)} stopped after ${timeout / 1000} s`;
            else if (code === null) stderr += `\n${path.basename(program)} stopped (${signal ?? "killed"})`;
            resolve({ code: code ?? -1, stdout, stderr, ...(stopped ? { stopped: true as const } : {}) });
        });
    });
}

/** A git command that failed; its message is git's stderr, and `command` what ran, for a failure's report. */
export class GitError extends Error {
    readonly command: string | undefined;
    constructor(message: string, command?: string) {
        super(message);
        this.command = command;
    }
}

/**
 * What git prints, in English under `LC_ALL=C`, when the server doesn't do partial clones and it's about to download
 * every file of the commit (SPEC-157 C.7).
 */
export const partialCloneWarning = "filtering not recognized by server";

/** The server ignored the filter, so the clone or fetch was stopped before it downloaded everything (`noPartialClone`). */
export class NoPartialClone extends GitError {}

/** git's words for a clone or fetch of a branch the remote doesn't have. */
const missingBranch = /Remote branch .* not found|couldn't find remote ref/;

/** Whether a clone or fetch failed because the remote has no such branch; one stopped by `stopOn` never did. */
function isMissingBranch(error: unknown): error is GitError {
    return error instanceof GitError && !(error instanceof NoPartialClone) && missingBranch.test(error.message);
}

/** A git run's stdout, or the error its exit means: `NoPartialClone` when `stopOn` stopped it, else any exit but 0. */
function checked(args: string[], result: GitResult): string {
    const command = ["git", ...args].join(" ");
    if (result.stopped) throw new NoPartialClone(result.stderr.trim(), command);
    if (result.code !== 0) throw new GitError(result.stderr.trim() || `git ${args[0]} failed`, command);
    return result.stdout;
}

/** The default branch's name, once `isValidBranch` takes it; it comes from the copy or the remote, so it's checked. */
function usableDefaultBranch(branch: string): string {
    if (!isValidBranch(branch)) {
        throw new GitError(`The store's copy names a default branch it can't use: ${JSON.stringify(branch)}`);
    }
    return branch;
}

/** The branch the list names isn't on the remote (`noBranch`). */
export class NoBranch extends GitError {
    readonly branch: string;
    constructor(message: string, branch: string, command?: string) {
        super(message, command);
        this.branch = branch;
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
 * shows that offer when the tools are missing, so `xcode-select -p` is asked first, and the developer folder it names
 * must hold `usr/bin/git`. That folder can outlive its tools (deleted by hand), and `xcode-select -p` still names it.
 */
export async function gitAvailable(run: Run = spawnProgram, git = "/usr/bin/git"): Promise<boolean> {
    const tools = await run("/usr/bin/xcode-select", ["-p"], { timeout: shortTimeout });
    if (tools.code !== 0) return false;
    const developer = tools.stdout.trim();
    if (!path.isAbsolute(developer) || !(await isFile(path.join(developer, "usr/bin/git")))) return false;
    const version = await run(git, ["--version"], { timeout: shortTimeout });
    return version.code === 0 && !/developer tools/i.test(version.stderr);
}

/** Whether `file` is a file, followed through links, found without running or reading it. */
async function isFile(file: string): Promise<boolean> {
    return stat(file).then(
        (info) => info.isFile(),
        () => false,
    );
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

/** Before `clone` and `fetch`: no credential helper at all, a second guard beside `storeEnvironment` (SPEC-157 C.4). */
const noCredentialHelper = ["-c", "credential.helper="];

/**
 * A repository's copy: Raycast's in `<supportPath>/repo`. Every path or pattern built from an extension's name is
 * checked by the caller. Its git reaches only https remotes and never asks for a password (SPEC-157 C.4): tests reach
 * local repositories through `allowProtocols`, which the app never sets. With `branch`, the copy follows that branch
 * instead of the remote's default.
 */
export class StoreRepository {
    readonly path: string;
    readonly branch: string | undefined;
    readonly #run: Run;
    readonly #git: string;
    readonly #url: string;
    readonly #allowProtocols: string;

    constructor(
        repoPath: string,
        options: { run?: Run; git?: string; url?: string; branch?: string; allowProtocols?: string } = {},
    ) {
        if (options.branch !== undefined && !isValidBranch(options.branch)) {
            throw new GitError(`Not a branch name: ${JSON.stringify(options.branch)}`);
        }
        this.path = repoPath;
        this.branch = options.branch;
        this.#run = options.run ?? spawnProgram;
        this.#git = options.git ?? "/usr/bin/git";
        this.#url = options.url ?? repositoryURL;
        this.#allowProtocols = options.allowProtocols ?? "https";
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
        extra: { env?: NodeJS.ProcessEnv; signal?: AbortSignal; stopOn?: string } = {},
    ): Promise<string> {
        return checked(args, await this.#start(args, timeout, cwd, input, extra));
    }

    /** Runs git as `#exec` does, and gives its result whatever the exit. */
    #start(
        args: string[],
        timeout = shortTimeout,
        cwd = this.path,
        input?: string,
        extra: { env?: NodeJS.ProcessEnv; signal?: AbortSignal; stopOn?: string } = {},
    ): Promise<GitResult> {
        const env = { GIT_ALLOW_PROTOCOL: this.#allowProtocols, GIT_ASKPASS: "", ...extra.env };
        return this.#run(this.#git, args, { cwd, timeout, stoppable: true, input, ...extra, env });
    }

    /**
     * A clone or fetch that may download the commit's files: in English (`LC_ALL=C`), so the server's warning that it
     * ignores the filter is known, and stopped the moment it shows, in a group of its own (SPEC-157 C.7). A missing
     * branch the list names is `NoBranch`.
     */
    async #download(args: string[], cwd: string): Promise<void> {
        const stopping = new AbortController();
        try {
            await this.#exec([...noCredentialHelper, ...args], longTimeout, cwd, undefined, {
                env: { LC_ALL: "C" },
                signal: stopping.signal,
                stopOn: partialCloneWarning,
            });
        } catch (error) {
            if (this.branch !== undefined && isMissingBranch(error)) {
                throw new NoBranch(error.message, this.branch, error.command);
            }
            throw error;
        }
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

    /**
     * Clones with only `extensions/*\/package.json` checked out; blobs come on demand. A clone stopped because the server
     * ignores the filter leaves no copy (`NoPartialClone`).
     */
    async clone(): Promise<void> {
        await mkdir(path.dirname(this.path), { recursive: true });
        const branch = this.branch === undefined ? [] : ["--branch", this.branch];
        try {
            await this.#download(
                ["clone", "--depth", "1", "--filter=blob:none", "--sparse", "--no-checkout", ...branch, "--", this.#url, this.path],
                path.dirname(this.path),
            );
        } catch (error) {
            if (error instanceof NoPartialClone) await this.remove();
            throw error;
        }
        await this.#exec(["sparse-checkout", "set", "--no-cone", "/extensions/*/package.json"]);
        // Fetches every extension's package.json.
        await this.#exec(["checkout"], longTimeout);
        await this.#markRefreshed();
    }

    /**
     * Fetches the branch's newest commit into its remote-tracking ref (the list's branch, else the default one), moves
     * the branch there and checks it out, then drops every other ref, the reflogs, and every object they no longer reach
     * (`#keepOnlyReachable`). `.git/shallow` then names only the new commit: the copy stays one commit deep however
     * often it's refreshed. A fetch stopped because the server ignores the filter leaves the copy as it was.
     * When the default branch's fetch finds no such branch (the remote renamed it since `origin/HEAD` was written),
     * the remote is asked for its default branch (SPEC-167 B), unless this refresh asked already, and that one is
     * fetched, once.
     */
    async refresh(): Promise<void> {
        let branch: string;
        let asked = false;
        if (this.branch !== undefined) branch = this.branch;
        else ({ branch, asked } = await this.#defaultBranch());
        try {
            await this.#fetchBranch(branch);
        } catch (error) {
            if (this.branch !== undefined || asked || !isMissingBranch(error)) throw error;
            const renamed = await this.#askDefaultBranch();
            if (renamed === branch) throw error;
            branch = renamed;
            await this.#fetchBranch(branch);
        }
        const local = `refs/heads/${branch}`;
        const tracking = `refs/remotes/origin/${branch}`;
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

    /** The branch's newest commit, one deep and without blobs, into its remote-tracking ref. */
    async #fetchBranch(branch: string): Promise<void> {
        await this.#download(
            [
                "fetch",
                "--depth",
                "1",
                "--filter=blob:none",
                "--no-tags",
                "origin",
                `+refs/heads/${branch}:refs/remotes/origin/${branch}`,
            ],
            this.path,
        );
    }

    /**
     * `main`, from the clone's `origin/HEAD`, or, when the copy has none (a clone on a named branch never gets one),
     * from the remote, kept as `origin/HEAD` so the next refresh asks nothing (`#askDefaultBranch`). A name that isn't
     * a plain branch name is refused (`isValidBranch`).
     */
    async defaultBranch(): Promise<string> {
        return (await this.#defaultBranch()).branch;
    }

    /** `defaultBranch()`, and whether it asked the remote. */
    async #defaultBranch(): Promise<{ branch: string; asked: boolean }> {
        const args = ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"];
        const result = await this.#start(args);
        // With `--quiet`, git exits 1, and says nothing, when there's no symbolic `origin/HEAD`: none, or a plain ref.
        if (result.code === 1) return { branch: await this.#askDefaultBranch(), asked: true };
        return { branch: usableDefaultBranch(checked(args, result).trim().replace(/^origin\//, "")), asked: false };
    }

    /**
     * Asks the remote for its default branch, and keeps it as `origin/HEAD` (SPEC-167): one listing of the remote's
     * refs that match `HEAD`, no objects, through the same guards as a fetch, in English (`LC_ALL=C`) so `problemOf`
     * knows an unreachable server. A remote that names no branch (an empty repository, a detached HEAD, a HEAD naming a
     * branch that isn't there) or a name `isValidBranch` refuses is a `GitError`, and nothing is written.
     */
    async #askDefaultBranch(): Promise<string> {
        const listing = await this.#exec(
            [...noCredentialHelper, "ls-remote", "--symref", "origin", "HEAD"],
            longTimeout,
            this.path,
            undefined,
            { env: { LC_ALL: "C" } },
        );
        const named = listing
            .split("\n")
            .map((line) => /^ref: refs\/heads\/([^\t]+)\tHEAD$/.exec(line)?.[1])
            .find((name) => name !== undefined);
        if (named === undefined) throw new GitError("This repository doesn't name a default branch.");
        const branch = usableDefaultBranch(named);
        // Written before the refresh's fetch: if that fetch fails, it stays, pointing at a ref that isn't there yet,
        // and the next refresh reads it and fetches that branch without asking again.
        await this.#exec(["symbolic-ref", "refs/remotes/origin/HEAD", `refs/remotes/origin/${branch}`]);
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
                ...noCredentialHelper,
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
     * The ids of the files under `extensions/<dir>/src/` that aren't downloaded: after `fetchSource`, the ones over its
     * limit. `rev-list --missing=print` names them without fetching them, on any git. `dir` is a checked folder.
     */
    async missingObjects(dir: string): Promise<Set<string>> {
        const output = await this.#exec(["rev-list", "--objects", "--missing=print", `HEAD:extensions/${dir}/src`]);
        return new Set(
            output
                .split("\n")
                .filter((line) => line.startsWith("?"))
                .map((line) => line.slice(1)),
        );
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
     * The files under `extensions/<dir>/src/` (git's blobs: a link is one too), each by its path relative to `src/` and
     * its object id, read from the trees alone: a blobless clone has every tree, so nothing is downloaded. `dir` is a
     * checked folder.
     */
    async srcFiles(dir: string): Promise<{ path: string; object: string }[]> {
        const prefix = `extensions/${dir}/src/`;
        const output = await this.#exec(["ls-tree", "-r", "-z", "HEAD", "--", prefix]);
        const files: { path: string; object: string }[] = [];
        for (const entry of output.split("\0")) {
            const match = /^\d+ blob ([0-9a-f]+)\t(.+)$/s.exec(entry);
            if (match && match[2]!.startsWith(prefix)) files.push({ path: match[2]!.slice(prefix.length), object: match[1]! });
        }
        return files;
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
