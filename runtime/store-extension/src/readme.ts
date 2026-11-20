// An extension's README, made safe to show: images load only from GitHub's hosts, as the consent text says.
import { rawURL } from "./catalog.ts";

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
    const url = source.trim().replace(/^<(.*)>$/, "$1");
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
    for (const match of markdown.matchAll(/^ {0,3}\[([^\]]+)\]:\s*(<[^>]*>|\S+)/gm)) {
        references.set(match[1]!.toLowerCase(), match[2]!);
    }
    let result = markdown.replace(
        /!\[([^\]]*)\]\(\s*(<[^>]*>|[^\s)]+)(\s+"[^"]*"|\s+'[^']*')?\s*\)/g,
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
    return result;
}
