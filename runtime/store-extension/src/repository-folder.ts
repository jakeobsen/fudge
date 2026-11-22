// The repository folder rule (FUD-183), as the app's `ExtensionRepositoryFolder` has it: the folder a repository's
// extensions are kept in under the extensions folder, worked out from the parsed address's host, port and path
// segments, and the one sentence for each refusal. `test/fixtures/repository-folders.json` pins this and the Swift
// rule to the same cases. The shape checks are the runtime's `src/extension-id.ts`, which the id rule shares.
import {
    asciiLowercase,
    developmentFolder,
    type FolderRefusal,
    hostRefusal,
    isGitHub,
    isValidRepositoryFolder,
    maxFolderBytes,
    maxHostSegments,
    ownerRefusal,
    raycastFolder,
    segmentRefusal,
} from "../../src/extension-id.ts";

export { developmentFolder, type FolderRefusal, isValidRepositoryFolder, raycastFolder };

/** Each refusal's sentence, written here only: adding a repository says the same words. */
export const refusalSentences: Record<FolderRefusal, string> = {
    characters: "That address has characters Fudge can't use.",
    tooLong: "That address is too long for Fudge to use.",
    tooManyParts: "That address has too many parts. Use the repository's own address.",
    notARepository: "Use the repository's own address, such as https://github.com/owner/repository.",
    startsWithDot: "Fudge can't use a repository whose name starts with a dot.",
    serverWithoutDot: "Fudge can only use a server whose name has a dot in it, such as git.example.org.",
    port: "Fudge can only use a port from 1 to 65535.",
    alreadyListed: "That repository is already in the list.",
    nests: "That repository's folder would be inside another repository's, so Fudge can't keep their extensions apart.",
};

export type FolderResult = { folder: string } | { refused: FolderRefusal };

/**
 * The folder of the repository at `host`, `port` (undefined when the address has none) and the path `segments` (with
 * the trailing `/` and `.git` already dropped), or why it can't have one. On GitHub (`github.com` in any letter case,
 * with no port or port 443) it's exactly two segments, the owner and the repository, in lowercase. On any other server
 * it's the server's name in lowercase, `_` and the port when there's one other than 443, then each of one to six
 * segments in lowercase.
 */
export function repositoryFolder(host: string, port: number | undefined, segments: readonly string[]): FolderResult {
    if (port !== undefined && !(Number.isInteger(port) && port >= 1 && port <= 65535)) return { refused: "port" };
    let folder: string;
    if (isGitHub(host) && (port === undefined || port === 443)) {
        if (segments.length !== 2) return { refused: "notARepository" };
        const refused = ownerRefusal(segments[0]) ?? segmentRefusal(segments[1]);
        if (refused !== undefined) return { refused };
        folder = `${asciiLowercase(segments[0])}/${asciiLowercase(segments[1])}`;
    } else {
        const refusedHost = hostRefusal(host);
        if (refusedHost !== undefined) return { refused: refusedHost };
        if (segments.length === 0) return { refused: "notARepository" };
        if (segments.length > maxHostSegments) return { refused: "tooManyParts" };
        for (const segment of segments) {
            const refused = segmentRefusal(segment);
            if (refused !== undefined) return { refused };
        }
        const server = asciiLowercase(host) + (port === undefined || port === 443 ? "" : `_${port}`);
        folder = [server, ...segments.map(asciiLowercase)].join("/");
    }
    return Buffer.byteLength(folder, "utf8") > maxFolderBytes ? { refused: "tooLong" } : { folder };
}

/**
 * Why a repository whose folder is `folder` can't be added beside the repositories in `existing`: the same folder as
 * one of them, or a folder inside one of theirs, or holding one; letter case ignored. Undefined when it can.
 */
export function repositoryFolderConflict(folder: string, existing: readonly string[]): FolderRefusal | undefined {
    const added = asciiLowercase(folder);
    let nests = false;
    for (const other of existing.map(asciiLowercase)) {
        if (other === added) return "alreadyListed";
        if (added.startsWith(`${other}/`) || other.startsWith(`${added}/`)) nests = true;
    }
    return nests ? "nests" : undefined;
}
