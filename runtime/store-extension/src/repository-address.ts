// Adding a repository (FUD-182), as the app's `ExtensionRepository.parse` has it: an address and a branch are checked
// by hand, the same way on both sides, never with `new URL`, which resolves `..`, turns `\` into `/`, drops tabs,
// newlines and `:443`, and converts a host that isn't ASCII. `test/fixtures/repository-addresses.json` pins this and the
// Swift rule to the same cases, in the same order of checks. The folder and its refusals are `repository-folder.ts`'s.
import { createHash } from "node:crypto";
import { asciiLowercase, isGitHub } from "../../src/extension-id.ts";
import { isValidBranch, repositoryURL } from "./git.ts";
import {
    developmentFolder,
    type FolderRefusal,
    raycastFolder,
    refusalSentences,
    repositoryFolder,
    repositoryFolderConflict,
} from "./repository-folder.ts";

/** The most repositories that can be added, Raycast's not counted. */
export const maxAddedRepositories = 10;

const raycastIdentity = "https://github.com/raycast/extensions";
/** The repository whose folder holds the extensions built on this Mac, which can't be added. */
const developmentIdentity = "https://github.com/fudgeapp/development";

/** Why an address can't be added: one of adding's own reasons, or one of the folder rule's. */
export type AddressRefusal = "https" | "credentials" | "development" | "branch" | "tooMany" | FolderRefusal;

/** Each refusal's sentence; those of the folder rule are `repository-folder.ts`'s, written there only. */
export const addressRefusalSentences: Record<AddressRefusal, string> = {
    https: "Use an https:// address, such as https://github.com/owner/repository.",
    credentials: "Leave the user name and password out of the address.",
    development: "Fudge keeps your own builds in that repository's folder, so it can't be added.",
    branch: "That branch name can't be used.",
    tooMany: "You can add up to 10 repositories.",
    ...refusalSentences,
};

/** A repository that can be added: the address without the spaces around it, and what the app works out from it. */
export type ParsedRepository = {
    address: string;
    /** `https://`, the server in lowercase (with a port other than 443), and the path without a trailing `/` and `.git`; on GitHub the path is in lowercase too. */
    identity: string;
    /** The first 16 hex digits of the identity's SHA-256, which names the Extension Store's copy. */
    copyId: string;
    /** `owner/repository` on GitHub, as typed; elsewhere the identity without `https://`. */
    name: string;
    /** The folder its extensions are installed in (`repository-folder.ts`). */
    folder: string;
    /** The branch to follow; none for the default branch. */
    branch?: string;
};

export type ParseResult = ParsedRepository | { refused: string; reason: AddressRefusal };

/** Raycast's official repository, always first in the list: it's never parsed, since parsing refuses its address. */
export const RAYCAST_COPY = Object.freeze({
    copyId: "raycast",
    folder: raycastFolder,
    identity: raycastIdentity,
    name: "Raycast",
    address: repositoryURL,
});

function refuse(reason: AddressRefusal): ParseResult {
    return { refused: addressRefusalSentences[reason], reason };
}

/** ASCII spaces, tabs and line breaks only, so both sides trim the same characters. */
function isSpace(code: number): boolean {
    return code === 32 || (code >= 9 && code <= 13);
}

function trimmed(text: string): string {
    let start = 0;
    let end = text.length;
    while (start < end && isSpace(text.charCodeAt(start))) start += 1;
    while (end > start && isSpace(text.charCodeAt(end - 1))) end -= 1;
    return text.slice(start, end);
}

function isLetterOrDigit(code: number): boolean {
    return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

/** A server and port's characters: letters, digits, `.`, `-` and `:`. */
function isAuthorityCode(code: number): boolean {
    return isLetterOrDigit(code) || code === 46 || code === 45 || code === 58;
}

/** A path's characters: letters, digits, `.`, `_`, `~`, `-` and `/`. */
function isPathCode(code: number): boolean {
    return isLetterOrDigit(code) || code === 46 || code === 95 || code === 126 || code === 45 || code === 47;
}

function every(text: string, test: (code: number) => boolean): boolean {
    for (let index = 0; index < text.length; index += 1) {
        if (!test(text.charCodeAt(index))) return false;
    }
    return true;
}

/** A port as written in an address: one to five digits with no leading zero, from 1 to 65535. */
function portNumber(text: string): number | undefined {
    if (!/^[1-9][0-9]{0,4}$/.test(text)) return undefined;
    const port = Number(text);
    return port <= 65535 ? port : undefined;
}

/** The copy id of a repository with `identity`: the first 16 hex digits of its SHA-256. */
export function copyIdOf(identity: string): string {
    return createHash("sha256").update(identity, "utf8").digest("hex").slice(0, 16);
}

/** Whether `copyId` is one Fudge gives: `raycast`, or 16 lowercase hex digits. */
export function isValidCopyId(copyId: unknown): copyId is string {
    return typeof copyId === "string" && (copyId === RAYCAST_COPY.copyId || /^[0-9a-f]{16}$/.test(copyId));
}

/**
 * The repository at `address` on `branch` (empty or undefined for the default branch), when it can be added beside
 * `list`, the repositories already added; else the refusal's sentence and reason. The checks run in the app's order, so
 * both give the same refusal for an address with more than one problem.
 */
export function parseRepositoryAddress(
    address: string,
    branch: string | undefined,
    list: readonly { identity: string; folder: string }[],
): ParseResult {
    const text = trimmed(address);
    const schemeEnd = text.indexOf("://");
    if (schemeEnd < 0 || asciiLowercase(text.slice(0, schemeEnd)) !== "https") return refuse("https");
    const rest = text.slice(schemeEnd + 3);
    const slash = rest.indexOf("/");
    const authority = slash < 0 ? rest : rest.slice(0, slash);
    let path = slash < 0 ? "" : rest.slice(slash + 1);
    if (authority.includes("@")) return refuse("credentials");
    if (!every(authority, isAuthorityCode) || !every(path, isPathCode)) return refuse("characters");
    // The server and its port, split at the first `:`.
    let host = authority;
    let port: number | undefined;
    const colon = authority.indexOf(":");
    if (colon >= 0) {
        host = authority.slice(0, colon);
        port = portNumber(authority.slice(colon + 1));
        if (port === undefined) return refuse("port");
    }
    if (host === "") return refuse("https");
    // The path without one trailing `/`, then one trailing `.git`.
    if (path.endsWith("/")) path = path.slice(0, -1);
    if (path.endsWith(".git")) path = path.slice(0, -4);
    const segments = path === "" ? [] : path.split("/");
    if (segments.some((segment) => segment === "." || segment === "..")) return refuse("characters");

    const gitHub = isGitHub(host) && (port === undefined || port === 443);
    const server = asciiLowercase(host) + (port === undefined || port === 443 ? "" : `:${port}`);
    const identity = `https://${server}${path === "" ? "" : `/${gitHub ? asciiLowercase(path) : path}`}`;
    if (identity === raycastIdentity) return refuse("alreadyListed");
    if (identity === developmentIdentity) return refuse("development");

    const found = repositoryFolder(host, port, segments);
    if ("refused" in found) return refuse(found.refused);
    const { folder } = found;
    const branchName = trimmed(branch ?? "");
    if (branchName !== "" && !isValidBranch(branchName)) return refuse("branch");
    if (list.length >= maxAddedRepositories) return refuse("tooMany");
    if (list.some((other) => other.identity === identity)) return refuse("alreadyListed");
    const conflict = repositoryFolderConflict(
        folder,
        list.map((other) => other.folder),
    );
    if (conflict !== undefined) return refuse(conflict);
    // A second guard, last: only github.com with no port or port 443 gives these folders, and the identity check above
    // already refuses those addresses, before the branch and the list are looked at.
    if (folder === raycastFolder) return refuse("alreadyListed");
    if (folder === developmentFolder) return refuse("development");
    return {
        address: text,
        identity,
        copyId: copyIdOf(identity),
        name: gitHub ? segments.join("/") : identity.slice("https://".length),
        folder,
        ...(branchName === "" ? {} : { branch: branchName }),
    };
}

/** A repository in the list the app answers `extensionRepositories()` with, checked again here. */
export type RepositoryEntry = ParsedRepository & { on: boolean };

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * The app's answer to `extensionRepositories()`, checked again with the shared rule, since the Extension Store never
 * reads `settings.json` itself: Raycast's entry first (as `RAYCAST_COPY` with its `on`, and only in first place), then
 * each added repository that parses again, beside those before it, to the copy id and folder the app answered. Anything
 * else is left out.
 */
export function checkRepositoriesAnswer(value: unknown): RepositoryEntry[] {
    if (!Array.isArray(value)) return [];
    const entries: RepositoryEntry[] = [];
    const added: ParsedRepository[] = [];
    value.forEach((entry, index) => {
        if (!isObject(entry) || typeof entry.on !== "boolean") return;
        if (index === 0) {
            if (entry.copyId === RAYCAST_COPY.copyId && entry.folder === RAYCAST_COPY.folder) {
                entries.push({ ...RAYCAST_COPY, on: entry.on });
            }
            return;
        }
        if (typeof entry.address !== "string" || (entry.branch !== undefined && typeof entry.branch !== "string")) {
            return;
        }
        const parsed = parseRepositoryAddress(entry.address, entry.branch, added);
        if ("refused" in parsed || parsed.copyId !== entry.copyId || parsed.folder !== entry.folder) return;
        added.push(parsed);
        entries.push({ ...parsed, on: entry.on });
    });
    return entries;
}
