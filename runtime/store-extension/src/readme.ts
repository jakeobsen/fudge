// An extension's README and details, with images from GitHub's hosts only.
import { folderURL, rawURL, type StoreEntry } from "./catalog.ts";

const githubHosts = new Set([
    "github.com",
    "raw.githubusercontent.com",
    "user-images.githubusercontent.com",
    "private-user-images.githubusercontent.com",
]);

/** Whether an image at `url` may load: https on github.com or any `*.githubusercontent.com` host. */
export function isGitHubImage(url: string): boolean {
    let parsed: URL;
    try {
        parsed = new URL(url);
    } catch {
        return false;
    }
    if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.port) return false;
    const host = parsed.hostname.toLowerCase();
    return githubHosts.has(host) || host.endsWith(".githubusercontent.com");
}

/**
 * The image source to show for `source` in the README of `name` at `commit`: GitHub's own URLs as they are, a path
 * inside the extension's folder (`media/shot.png`) as its raw file on GitHub, and nothing for anything else.
 */
export function imageSource(source: string, name: string, commit: string): string | undefined {
    const url = source.trim().replace(/^<([^<>]*)>$/, "$1");
    // A source the renderer would read differently (spaces, line breaks, `<`, `>`, `)`) is never shown.
    if (!url || /[\s<>)]/.test(url)) return undefined;
    if (/^[a-z][a-z0-9+.-]*:/i.test(url) || url.startsWith("//")) return isGitHubImage(url) ? url : undefined;
    const relative = url.replace(/^\.\//, "").split(/[?#]/)[0]!;
    if (!relative || relative.startsWith("/") || relative.split("/").includes("..")) return undefined;
    return rawURL(name, commit, relative);
}

/**
 * The README with every image that isn't on GitHub replaced by its alt text: inline images (`![alt](src "title")`),
 * reference images (`![alt][ref]` with `[ref]: src`) and HTML `<img>` tags.
 */
export function filterImages(markdown: string, name: string, commit: string): string {
    const references = new Map<string, string>();
    for (const match of markdown.matchAll(/^ {0,3}\[([^\]]+)\]:[ \t]*(<[^>\n]*>|\S+)/gm)) {
        references.set(match[1]!.toLowerCase(), match[2]!);
    }
    let result = markdown.replace(
        /!\[([^\]]*)\]\([ \t]*(<[^>\n]*>|[^\s)]+)([ \t]+"[^"\n]*"|[ \t]+'[^'\n]*')?[ \t]*\)/g,
        (_whole, alt: string, source: string, title: string | undefined) => {
            const shown = imageSource(source, name, commit);
            return shown ? `![${alt}](${shown}${title ?? ""})` : alt;
        },
    );
    result = result.replace(/!\[([^\]]*)\]\[([^\]]*)\]/g, (whole, alt: string, label: string) => {
        const source = references.get((label || alt).toLowerCase());
        const shown = source ? imageSource(source, name, commit) : undefined;
        return shown ? `![${alt}](${shown})` : alt;
    });
    result = result.replace(/<img\b[^>]*>/gi, (tag) => {
        const attribute = (key: string) =>
            new RegExp(`\\b${key}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag);
        const src = attribute("src");
        const alt = attribute("alt");
        const shown = src ? imageSource(src[2] ?? src[3] ?? src[4] ?? "", name, commit) : undefined;
        const altText = alt ? (alt[2] ?? alt[3] ?? alt[4] ?? "") : "";
        return shown ? `![${altText}](${shown})` : altText;
    });
    return rendererPass(result);
}

/** The renderer's image rule (`Markdown.image` in FudgeCore): `![alt](source "title")` alone on a line. */
const rendererImage = /^!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)$/;

/**
 * A last pass over finished markdown, with the renderer's own rule: a line it would draw as an image keeps it only
 * when the source is on GitHub, and becomes the alt text otherwise.
 */
export function rendererPass(markdown: string): string {
    return markdown
        .split("\n")
        .map((line) => {
            const match = rendererImage.exec(line.trim());
            return match && !isGitHubImage(match[2]!) ? match[1]! : line;
        })
        .join("\n");
}

/** How the detail pane names a command's manifest `mode`; an unknown mode isn't shown. */
const modeNames: Record<string, string> = { view: "view", "no-view": "no-view", "menu-bar": "menu bar" };

/**
 * The detail pane: the manifest's facts, each command with its mode, then the README once it's fetched. Everything
 * in it, the manifest's own text included, goes through `filterImages`.
 */
export function detailMarkdown(entry: StoreEntry, commit: string, readme: string | undefined): string {
    const commands = entry.commands
        .map((command) => {
            const mode = command.mode !== undefined && Object.hasOwn(modeNames, command.mode) ? modeNames[command.mode] : "";
            const description = command.description ? `: ${command.description}` : "";
            return `- **${command.title}**${mode ? ` (${mode})` : ""}${description}`;
        })
        .join("\n");
    const facts = [
        entry.author && `**Author:** ${entry.author}`,
        entry.categories.length > 0 && `**Categories:** ${entry.categories.join(", ")}`,
        entry.license && `**License:** ${entry.license}`,
        // The folder passed `isValidFolder`, so it holds nothing markdown reads; the code span keeps `_` literal.
        entry.dir !== entry.name && `In the repository as \`${entry.dir}\``,
        commit && `[Source on GitHub](${folderURL(entry.dir, commit)})`,
    ].filter(Boolean);
    const markdown = [
        `# ${entry.title}`,
        entry.description,
        `## Commands\n\n${commands}`,
        facts.join("  \n"),
        readme === undefined ? "_Loading the README…_" : readme && `---\n\n${readme}`,
    ]
        .filter(Boolean)
        .join("\n\n");
    return filterImages(markdown, entry.dir, commit);
}
