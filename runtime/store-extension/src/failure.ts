// What a failed install or update shows (SPEC-116): the likely cause in plain words, the end of the failing step's
// output, and the whole text Copy Error copies. All of the output came from npm, esbuild, git or the extension's own
// packages, so it's untrusted: it's shown in a code block nothing in it can close, and the title and cause line are
// escaped character by character, so no package can add an image (a remote load), a link or formatting.

/** How many lines of output the view shows; Copy Error copies all of it. */
export const shownLines = 40;
/** At most this much output is kept, from the end, whatever a step printed. */
export const keptOutput = 200_000;

export type FailureKind =
    | "npmMissing"
    | "registryUnreachable"
    | "githubUnreachable"
    | "gitMissing"
    | "buildFailed"
    | "refused"
    | "other";

/** A failed step: what ran, how it ended and what it printed. A `refused` failure is the store's own words. */
export type FailureDetails = { output: string; command?: string; code?: number; refused?: boolean };

export type FailureCause = { kind: FailureKind; text: string };

/** The Mac's proxy, as far as the store's steps can use it: a PAC file is one they can't. */
export type ProxyFacts = { autoConfig: boolean };

/**
 * The output as it's shown and copied: terminal colours and other control characters gone, anything that looks like a
 * credential masked, and the home folder written as `~`. Never an environment variable: nothing here adds one.
 */
export function cleanOutput(text: string, home: string): string {
    let clean = text.slice(-keptOutput);
    clean = clean
        // ANSI CSI and OSC sequences, then any other control character but newline and tab.
        .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
        .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
        .replace(/\r\n?/g, "\n")
        .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "")
        // User info in a URL (a proxy's or a registry's password), and npm's `_authToken=`.
        .replace(/\b([a-z][a-z0-9+.-]*:\/\/)[^\s/@]+@/gi, "$1***@")
        .replace(/(_auth(?:Token)?\s*[=:]\s*)\S+/gi, "$1***")
        .replace(/((?:proxy-)?authorization\s*[=:]\s*)(?:(?:bearer|basic|token)\s+)?\S+/gi, "$1***")
        .replace(/\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 ***")
        .replace(/\b((?:password|passwd|token|secret|api[_-]?key)\s*[=:]\s*)\S+/gi, "$1***")
        // Tokens by their own shape: GitHub's and npm's.
        .replace(/\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|npm_[A-Za-z0-9]{30,})\b/g, "***");
    if (home.length > 1) clean = clean.split(home.replace(/\/+$/, "")).join("~");
    return clean;
}

/** The last `count` lines, without trailing blank ones. */
export function lastLines(text: string, count = shownLines): string {
    const lines = text.replace(/\s+$/, "").split("\n");
    return lines.slice(-count).join("\n");
}

const network =
    /\b(?:ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|ECONNRESET|EHOSTUNREACH|ENETUNREACH|SELF_SIGNED_CERT_IN_CHAIN|UNABLE_TO_GET_ISSUER_CERT_LOCALLY|UNABLE_TO_VERIFY_LEAF_SIGNATURE|CERT_HAS_EXPIRED|E403|E407)\b|self[- ]signed certificate|403 Forbidden|407 Proxy|network request to https:\/\/registry\.npmjs\.org/i;
const gitNetwork =
    /Could not resolve (?:host|proxy)|Failed to connect to|Connection (?:timed out|refused|reset)|SSL certificate problem|unable to access 'https:\/\/github\.com|Proxy CONNECT aborted|The requested URL returned error: 40[37]|Operation timed out/i;

/** The likely cause of a failure, in one plain sentence, from the output's own words and the exit code. */
export function causeOf(failure: FailureDetails, proxy: ProxyFacts = { autoConfig: false }): FailureCause {
    const { output, command = "", code } = failure;
    if (failure.refused) return { kind: "refused", text: oneLine(output) };
    const pac = proxy.autoConfig
        ? " Your Mac picks its proxy with an automatic configuration file, which npm and git can't read."
        : "";
    if (/env: (?:npm|node): No such file or directory|\b(?:npm|node): command not found/.test(output) ||
        (code === 127 && /\bnpm\b/.test(command + output))) {
        return {
            kind: "npmMissing",
            text:
                "Fudge couldn't find npm, which it needs to install extensions. Opened from Finder or at login, Fudge " +
                "doesn't see your shell's PATH, so an npm from Homebrew or a version manager isn't found. Until Fudge " +
                "brings its own npm, start it from Terminal with open -n -a Fudge.",
        };
    }
    if (/invalid active developer path|no developer tools were found|xcode-select --install/i.test(output)) {
        return { kind: "gitMissing", text: "Fudge needs Git, which comes with Apple's Command Line Tools." };
    }
    const fromNpm = /\bnpm (?:ci|install|error|ERR!)|registry\.npmjs\.org/.test(command + "\n" + output);
    if (fromNpm && network.test(output)) {
        return {
            kind: "registryUnreachable",
            text: "Fudge couldn't reach the npm registry (registry.npmjs.org). A proxy or firewall may be blocking it." + pac,
        };
    }
    const fromGit = /^git\b/.test(command) || /^fatal: /m.test(output);
    if (fromGit && gitNetwork.test(output)) {
        return {
            kind: "githubUnreachable",
            text:
                "Fudge couldn't reach GitHub (github.com) for the extension's source. A proxy or firewall may be blocking it." +
                pac,
        };
    }
    const buildError = /\[ERROR\]\s*(.+)/.exec(output);
    if (buildError) {
        return { kind: "buildFailed", text: `The extension didn't build: ${oneLine(buildError[1]).slice(0, 200)}` };
    }
    return { kind: "other", text: "Something went wrong while installing." };
}

/** Text on one line, its runs of whitespace one space, so nothing in it can start a block of its own. */
function oneLine(text: string): string {
    return text.replace(/\s+/g, " ").trim();
}

/**
 * Escapes every ASCII punctuation character, code point by code point, so Markdown reads none of it: CommonMark lets
 * a backslash escape any of them. A `*` with a combining mark after it is one character to the eye but still a `*`
 * to the parser (FUD-142), which is why this goes by code point. An e-mail address may still become a link.
 */
export function escapeMarkdown(text: string): string {
    let escaped = "";
    for (const scalar of oneLine(text)) {
        escaped += /^[!-/:-@[-`{-~]$/.test(scalar) ? `\\${scalar}` : scalar;
    }
    return escaped;
}

/** A fenced code block that no line of `text` can close: the fence is longer than any run of backticks in it. */
export function codeBlock(text: string): string {
    const longest = Math.max(0, ...[...text.matchAll(/`+/g)].map((run) => run[0].length));
    const fence = "`".repeat(Math.max(3, longest + 1));
    return `${fence}text\n${text}\n${fence}`;
}

/** The failure view's Markdown: the title, the cause, then the end of the output in a code block. */
export function failureMarkdown(title: string, cause: FailureCause, output: string): string {
    const shown = lastLines(output);
    const parts = [`## ${escapeMarkdown(title)}`, escapeMarkdown(cause.text)];
    if (cause.kind !== "refused" && shown.length > 0) {
        const all = output.replace(/\s+$/, "").split("\n").length;
        if (all > shownLines) parts.push(escapeMarkdown(`The last ${shownLines} lines of ${all}. Copy Error copies them all.`));
        parts.push(codeBlock(shown));
    }
    return parts.join("\n\n");
}

/** What Copy Error copies: the title, the cause, the command and its exit, Fudge's version, then all the output. */
export function failureReport(
    title: string,
    cause: FailureCause,
    details: FailureDetails,
    output: string,
    fudgeVersion: string | undefined,
): string {
    const facts = [
        details.command ? `Command: ${details.command}` : undefined,
        details.code !== undefined ? `Exit: ${details.code}` : undefined,
        `Fudge: ${fudgeVersion ?? "unknown"}`,
    ].filter((line): line is string => line !== undefined);
    return [title, cause.text, facts.join("\n"), cause.kind === "refused" ? "" : output.replace(/\s+$/, "")]
        .filter((part) => part.length > 0)
        .join("\n\n");
}
