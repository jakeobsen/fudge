// The Extension Store's repositories (SPEC-157 C): the list the app answers, a copy of each repository that's on, where
// each copy and its status file are, what went wrong with a copy, and the copies of repositories no longer listed.
import { lstat, mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { byTitle, catalogFolders, readCatalog, type RepositoryCopy, type StoreEntry } from "./catalog.ts";
import { readRegularFile } from "./files.ts";
import { GitError, NoBranch, NoPartialClone, StoreRepository, type Run } from "./git.ts";
import { checkRepositoriesAnswer, isValidCopyId, RAYCAST_COPY, type RepositoryEntry } from "./repository-address.ts";

/** The folder in the store's support folder that holds the added repositories' copies, one folder per copy id. */
export const repositoriesFolder = "repositories";

/** The most extensions an added repository's copy may list (C.6). */
export const maxCopyExtensions = 5000;

/** Where a repository's copy is (C.2): Raycast's stays at `repo/`, so nobody's is downloaded again. */
export function copyPath(supportPath: string, copyId: string): string {
    return copyId === RAYCAST_COPY.copyId
        ? path.join(supportPath, "repo")
        : path.join(supportPath, repositoriesFolder, copyId, "repo");
}

/** Where a repository's status file is (C.2): Raycast's beside `repo/`, an added one's beside its copy. */
export function statusPath(supportPath: string, copyId: string): string {
    return copyId === RAYCAST_COPY.copyId
        ? path.join(supportPath, "repo-status.json")
        : path.join(supportPath, repositoriesFolder, copyId, "status.json");
}

/** A repository that's on, with the store's copy of it: its own git, its rows' copy and folder, and its status file. */
export type StoreCopy = {
    entry: RepositoryEntry;
    repo: StoreRepository;
    /** What its rows carry (`readCatalog`). */
    copy: RepositoryCopy;
    statusPath: string;
};

/** Tests' seams into each copy's git; the app passes none. */
export type CopyOptions = { run?: Run; git?: string; allowProtocols?: string };

/**
 * The app's answer to `extensionRepositories()`, checked again (`checkRepositoriesAnswer`): every repository listed,
 * on or off, and a copy of each one that's on, Raycast's first, then the added ones in the list's order (C.3). An added
 * copy follows its branch, and is cloned from its address as typed, which the rule has checked.
 */
export function storeCopies(
    answer: unknown,
    supportPath: string,
    options: CopyOptions = {},
): { listed: RepositoryEntry[]; copies: StoreCopy[] } {
    const listed = checkRepositoriesAnswer(answer);
    const copies = listed
        .filter((entry) => entry.on)
        .map((entry) => {
            const raycast = entry.copyId === RAYCAST_COPY.copyId;
            const repo = new StoreRepository(copyPath(supportPath, entry.copyId), {
                ...options,
                ...(raycast ? {} : { url: entry.address }),
                ...(raycast || entry.branch === undefined ? {} : { branch: entry.branch }),
            });
            return {
                entry,
                repo,
                copy: { copyId: entry.copyId, repositoryFolder: entry.folder },
                statusPath: statusPath(supportPath, entry.copyId),
            };
        });
    return { listed, copies };
}

/** Why a copy has no rows, or only those of an earlier refresh (C.6). */
export type ProblemKind =
    | "unreachable"
    | "noBranch"
    | "noExtensionsFolder"
    | "empty"
    | "tooMany"
    | "noPartialClone"
    | "failed";

export const problemKinds: readonly ProblemKind[] = Object.freeze([
    "unreachable",
    "noBranch",
    "noExtensionsFolder",
    "empty",
    "tooMany",
    "noPartialClone",
    "failed",
]);

/** A problem's sentence, the same in the store and on the Settings row; `branch` is the one the list gives. */
export function problemSentence(kind: ProblemKind, branch?: string): string {
    switch (kind) {
        case "unreachable":
            return "Couldn't reach this repository. It may be private, or the address may be wrong.";
        case "noBranch":
            return `This repository has no branch called ${branch ?? ""}.`;
        case "noExtensionsFolder":
            return "This repository has no extensions folder.";
        case "empty":
            return "This repository has no extensions Fudge can list.";
        case "tooMany":
            return "This repository has more than 5,000 extensions.";
        case "noPartialClone":
            return "This repository's server can't send only the files the Extension Store needs.";
        case "failed":
            return "Something went wrong with this repository.";
    }
}

/** A copy that was read but has a problem of its own: no extensions folder, none listed, or too many. */
export class CopyProblem extends Error {
    readonly kind: ProblemKind;

    constructor(kind: ProblemKind) {
        super(problemSentence(kind));
        this.name = "CopyProblem";
        this.kind = kind;
    }
}

/**
 * git's words for a repository it couldn't reach or wasn't let into: a private or missing one (prompts are off, so it
 * says so at once), a server it couldn't find or connect to, or one that refused it. A server's own error (5xx) isn't
 * one of them, and is `failed`.
 */
const unreachable =
    /terminal prompts disabled|Repository not found|repository '[^'\n]*' not found|Authentication failed|could not read (?:Username|Password)|Could not resolve (?:host|proxy)|Failed to connect to|Connection (?:timed out|refused|reset)|Operation timed out|SSL certificate problem|The requested URL returned error: 40[1347]\b/i;

/** The kind of a failed clone, refresh or read (C.6): its own kind, git's words for an unreachable repository, else `failed`. */
export function problemOf(error: unknown): ProblemKind {
    if (error instanceof CopyProblem) return error.kind;
    if (error instanceof NoPartialClone) return "noPartialClone";
    if (error instanceof NoBranch) return "noBranch";
    if (error instanceof GitError && unreachable.test(error.message)) return "unreachable";
    return "failed";
}

/**
 * A copy's rows (C.6): its catalog, or the problem that keeps it from having any. An added repository's copy may list
 * at most 5,000 extensions, counted from its folders before any manifest is read; Raycast's has no limit.
 */
export async function readCopy(repoPath: string, copy: RepositoryCopy): Promise<StoreEntry[]> {
    const root = await lstat(path.join(repoPath, "extensions")).catch(() => undefined);
    if (!root?.isDirectory()) throw new CopyProblem("noExtensionsFolder");
    const folders = await catalogFolders(repoPath);
    if (copy.copyId !== RAYCAST_COPY.copyId && folders.length > maxCopyExtensions) throw new CopyProblem("tooMany");
    const entries = await readCatalog(repoPath, copy, folders);
    if (entries.length === 0) throw new CopyProblem("empty");
    return entries;
}

/** What the store last found in a copy (C.6), as its status file has it: `branch` is the one the list gave. */
export type CopyStatus =
    | { checkedAt: string; branch?: string; extensions: number }
    | { checkedAt: string; branch?: string; problem: ProblemKind };

/** The most bytes a status file may hold, as Settings reads it. */
export const maxStatusBytes = 4096;

/** The status after an attempt: how many extensions the copy lists, or its problem. */
export function copyStatus(
    checkedAt: Date,
    branch: string | undefined,
    result: { extensions: number } | { problem: ProblemKind },
): CopyStatus {
    return { checkedAt: checkedAt.toISOString(), ...(branch === undefined ? {} : { branch }), ...result };
}

/** Writes a status file atomically: a file of its own beside it, then renamed over it. */
export async function writeStatus(file: string, status: CopyStatus): Promise<void> {
    await mkdir(path.dirname(file), { recursive: true });
    const temporary = `${file}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
    try {
        await writeFile(temporary, `${JSON.stringify(status)}\n`, { mode: 0o644 });
        await rename(temporary, file);
    } catch (error) {
        await rm(temporary, { force: true });
        throw error;
    }
}

/** A status file as the store wrote it, or undefined: no file, not a regular file, too big, or not a status. */
export async function readStatus(file: string): Promise<CopyStatus | undefined> {
    const text = await readRegularFile(file, maxStatusBytes).catch(() => undefined);
    if (text === undefined) return undefined;
    let value: unknown;
    try {
        value = JSON.parse(text);
    } catch {
        return undefined;
    }
    if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
    const object = value as Record<string, unknown>;
    if (typeof object.checkedAt !== "string") return undefined;
    if (object.branch !== undefined && typeof object.branch !== "string") return undefined;
    const base = {
        checkedAt: object.checkedAt,
        ...(typeof object.branch === "string" ? { branch: object.branch } : {}),
    };
    if (object.problem !== undefined) {
        return problemKinds.includes(object.problem as ProblemKind)
            ? { ...base, problem: object.problem as ProblemKind }
            : undefined;
    }
    const count = object.extensions;
    return typeof count === "number" && Number.isInteger(count) && count >= 0 ? { ...base, extensions: count } : undefined;
}

/**
 * Whether a copy waits for ⌘R (C.7): its status says the server can't do partial clones, for the branch the list gives
 * now. Such a copy isn't cloned or refreshed at open, not even a day old; a changed branch is tried again.
 */
export function waitsForRetry(status: CopyStatus | undefined, branch: string | undefined): boolean {
    return status !== undefined && "problem" in status && status.problem === "noPartialClone" && status.branch === branch;
}

/**
 * The copy ids of the folders under `repositories/` that no repository in `listed` has, on or off (C.5): a removed
 * repository's copy. Only folders named by a copy id count; anything else there is left alone, links included.
 */
export async function unlistedCopies(supportPath: string, listed: readonly RepositoryEntry[]): Promise<string[]> {
    const kept = new Set(listed.map((entry) => entry.copyId));
    const found = await readdir(path.join(supportPath, repositoriesFolder), { withFileTypes: true }).catch(() => []);
    return found
        .filter(
            (item) =>
                item.isDirectory() &&
                isValidCopyId(item.name) &&
                item.name !== RAYCAST_COPY.copyId &&
                !kept.has(item.name),
        )
        .map((item) => item.name)
        .sort();
}

/** Deletes a removed repository's copy and its status file: its folder under `repositories/`. */
export async function removeCopy(supportPath: string, copyId: string): Promise<void> {
    if (!isValidCopyId(copyId) || copyId === RAYCAST_COPY.copyId) throw new Error(`Not an added copy id: ${copyId}`);
    await rm(path.join(supportPath, repositoriesFolder, copyId), { recursive: true, force: true });
}

/**
 * Deletes every removed repository's copy (C.5), each held while a build from another session runs, under
 * `remove:<copyId>`, since such a build's source may be in it. A copy that can't be deleted stays for the next open.
 */
export async function removeUnlistedCopies(
    supportPath: string,
    listed: readonly RepositoryEntry[],
    hold: (key: string, step: () => Promise<void>) => Promise<void>,
): Promise<void> {
    const unlisted = await unlistedCopies(supportPath, listed);
    await Promise.all(
        unlisted.map((copyId) =>
            hold(`remove:${copyId}`, () => removeCopy(supportPath, copyId)).catch(() => undefined),
        ),
    );
}

/** A copy's rows as last read: its entries, each folder's tree id, and its commit. */
export type CopyRows = { entries: StoreEntry[]; trees: Map<string, string>; commit: string };

/** What the store shows for a copy: its rows from the last read, kept under a problem, and its problem (C.6). `error`
 * is what failed, none for a problem its status file gave. */
export type CopyState = { rows?: CopyRows; problem?: { kind: ProblemKind; error?: unknown } };

/** The rows of every copy that's on, by title, with each copy's trees and commit by copy id (D.1); a copy with no rows
 * yet adds none, and one no longer on adds none. */
export function shownRows(
    copies: readonly StoreCopy[],
    states: ReadonlyMap<string, CopyState>,
): { entries: StoreEntry[]; trees: Map<string, Map<string, string>>; commits: Map<string, string> } {
    const entries: StoreEntry[] = [];
    const trees = new Map<string, Map<string, string>>();
    const commits = new Map<string, string>();
    for (const copy of copies) {
        const rows = states.get(copy.entry.copyId)?.rows;
        if (!rows) continue;
        entries.push(...rows.entries);
        trees.set(copy.entry.copyId, rows.trees);
        commits.set(copy.entry.copyId, rows.commit);
    }
    return { entries: entries.sort(byTitle), trees, commits };
}

/**
 * What Raycast's load-error view shows (C.6): Raycast's copy's failure, but only when no copy that's on has rows, so
 * any copy that could be read makes every problem a row instead. None when Raycast's is off or didn't fail.
 */
export function raycastLoadFailure(
    copies: readonly StoreCopy[],
    states: ReadonlyMap<string, CopyState>,
): { error: unknown } | undefined {
    if (copies.some((copy) => states.get(copy.entry.copyId)?.rows !== undefined)) return undefined;
    const raycast = copies.find((copy) => copy.entry.copyId === RAYCAST_COPY.copyId);
    const problem = raycast ? states.get(raycast.entry.copyId)?.problem : undefined;
    return problem?.error === undefined ? undefined : { error: problem.error };
}
