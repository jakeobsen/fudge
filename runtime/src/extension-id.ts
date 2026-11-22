// An installed extension's id and its repository folder's shape (FUD-183), as the app's `ExtensionID.isValid` and
// `ExtensionRepositoryFolder.isValid` have them. Nothing here imports anything, so the Extension Store can use it
// without the worker's code. `test/fixtures/extension-ids.json` and `test/fixtures/repository-folders.json` pin these
// and the Swift rules to the same cases.
//
// Raycast's extensions, and the bundled ones, keep their manifest name as their id. An extension from any other
// repository, the development folder included, has its repository folder's segments, then its name, joined with `+`
// (`someone+tools+github`, `fudgeapp+development+github`). Every check is in ASCII, so a letter outside ASCII is
// refused before any lowercase conversion could change it.

/**
 * `ExtensionManifest.isValidName`, the one extension name rule: lowercase letters, digits, `-` and `_`, starting with a
 * letter or digit. `test/fixtures/extension-names.json` pins this and the Swift rule to the same cases.
 */
const namePattern = /^[a-z0-9][a-z0-9_-]*$/;

export function isValidName(name: unknown): name is string {
    return typeof name === "string" && namePattern.test(name);
}

/** Raycast's official repository's folder, which holds the Extension Store's installs. */
export const raycastFolder = "raycast/extensions";
/** The development folder: extensions built here without a repository. */
export const developmentFolder = "fudgeapp/development";

export const maxSegmentLength = 100;
export const maxFolderBytes = 160;
export const maxHostSegments = 6;
export const maxIdBytes = 200;

/** Why a repository can't have a folder; the Extension Store's `repository-folder.ts` has each one's sentence. */
export type FolderRefusal =
    | "characters"
    | "tooLong"
    | "tooManyParts"
    | "notARepository"
    | "startsWithDot"
    | "serverWithoutDot"
    | "port"
    | "alreadyListed"
    | "nests";

function isLetterOrDigit(code: number): boolean {
    return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function codes(text: string): number[] {
    return Array.from({ length: text.length }, (_, index) => text.charCodeAt(index));
}

/** ASCII letters in lowercase, everything else as it is. */
export function asciiLowercase(text: string): string {
    return text.replace(/[A-Z]/g, (letter) => letter.toLowerCase());
}

export function isGitHub(host: string): boolean {
    return asciiLowercase(host) === "github.com";
}

/** A GitHub owner: letters, digits and hyphens, never starting or ending with a hyphen, and no dot. */
export function ownerRefusal(owner: string): FolderRefusal | undefined {
    if (owner === "") return "notARepository";
    const all = codes(owner);
    const hyphen = 45;
    if (!all.every((code) => isLetterOrDigit(code) || code === hyphen) || all[0] === hyphen || all.at(-1) === hyphen) {
        return "characters";
    }
    return owner.length > maxSegmentLength ? "tooLong" : undefined;
}

/** A path segment: letters, digits, `.`, `_`, `~` and `-`, never starting with `.`, at most 100 characters. */
export function segmentRefusal(segment: string): FolderRefusal | undefined {
    if (segment === "") return "notARepository";
    const allowed = new Set([46, 95, 126, 45]);
    if (!codes(segment).every((code) => isLetterOrDigit(code) || allowed.has(code))) return "characters";
    if (segment.startsWith(".")) return "startsWithDot";
    return segment.length > maxSegmentLength ? "tooLong" : undefined;
}

/**
 * A server's name: letters, digits, `-` and dots, with at least one dot, never at either end or two in a row. An IPv4
 * address has that shape; an IPv6 address and a one-word name don't.
 */
export function hostRefusal(host: string): FolderRefusal | undefined {
    if (!host.includes(".") || host.includes(":")) return "serverWithoutDot";
    const dot = 46;
    const hyphen = 45;
    if (
        !codes(host).every((code) => isLetterOrDigit(code) || code === dot || code === hyphen) ||
        host.startsWith(".") ||
        host.endsWith(".") ||
        host.includes("..")
    ) {
        return "characters";
    }
    return undefined;
}

/** A port as a folder writes it: digits with no leading zero, from 1 to 65535. */
function canonicalPort(text: string): number | undefined {
    if (!/^[1-9][0-9]{0,4}$/.test(text)) return undefined;
    const port = Number(text);
    return port <= 65535 ? port : undefined;
}

/**
 * `ExtensionRepositoryFolder.isValid`: two lowercase segments for GitHub's owner and repository, or a lowercase
 * server name with a dot (and `_<port>` for a port other than 443) and one to six lowercase segments; at most 160
 * bytes. `raycast/extensions` and `fudgeapp/development` pass.
 */
export function isValidRepositoryFolder(folder: unknown): folder is string {
    if (typeof folder !== "string" || folder === "" || Buffer.byteLength(folder, "utf8") > maxFolderBytes) return false;
    const parts = folder.split("/");
    if (!parts.every((part) => part === asciiLowercase(part))) return false;
    const first = parts[0];
    if (first.includes(".")) {
        const underscore = first.indexOf("_");
        const host = underscore === -1 ? first : first.slice(0, underscore);
        if (hostRefusal(host) !== undefined) return false;
        if (parts.length - 1 < 1 || parts.length - 1 > maxHostSegments) return false;
        if (underscore !== -1) {
            const port = canonicalPort(first.slice(underscore + 1));
            if (port === undefined || port === 443) return false;
        } else if (isGitHub(host)) {
            // GitHub's folders are `<owner>/<repository>`, never under the server's name.
            return false;
        }
        return parts.slice(1).every((segment) => segmentRefusal(segment) === undefined);
    }
    return parts.length === 2 && ownerRefusal(parts[0]) === undefined && segmentRefusal(parts[1]) === undefined;
}

/**
 * `ExtensionID.isValid`, at most 200 bytes, one of: a valid extension name; a GitHub owner, a repository and a valid
 * name (exactly three parts); a server's name, one to six path segments and a valid name (three to eight parts). The
 * parts before the name are a valid repository folder, and `raycast+extensions+<name>` is refused, since Raycast's
 * installs keep their bare names. Each part is one folder segment, so an id never holds a `/`: keys split at their
 * first `/`.
 */
export function isValidExtensionId(id: unknown): id is string {
    if (typeof id !== "string" || Buffer.byteLength(id, "utf8") > maxIdBytes || id.includes("/")) return false;
    const parts = id.split("+");
    if (!isValidName(parts.at(-1))) return false;
    if (parts.length === 1) return true;
    const folder = parts.slice(0, -1).join("/");
    return folder !== raycastFolder && isValidRepositoryFolder(folder);
}

/**
 * The id of the extension `name` installed in the repository folder `folder`: the bare name in Raycast's folder, else
 * the folder's segments and the name joined with `+`. Undefined when the name isn't valid or the id fails the rule.
 */
export function extensionId(name: string, folder: string): string | undefined {
    if (!isValidName(name)) return undefined;
    const id = folder === raycastFolder ? name : [...folder.split("/"), name].join("+");
    return isValidExtensionId(id) ? id : undefined;
}
