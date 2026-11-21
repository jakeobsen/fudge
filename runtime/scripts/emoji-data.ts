// Derives the emoji picker's data from Unicode's files in vendor/unicode/ (Emoji 16.0's emoji-test.txt and CLDR 46's
// English annotations):
//
//   emoji-extension/src/emoji.generated.json   every fully-qualified emoji, by group, with its name and keywords
//
// Run it with `npm run generate`. `npm run typecheck` runs it with --check, which fails if the file is out of date.
// Nothing is fetched: the vendored files are the input.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const vendor = (name: string) => fileURLToPath(new URL(`../vendor/unicode/${name}`, import.meta.url));
const outputPath = fileURLToPath(new URL("../emoji-extension/src/emoji.generated.json", import.meta.url));

/** One emoji of the picker. Its skin-tone variants are fields of it, not entries of their own. */
export type EmojiEntry = {
    emoji: string;
    /** CLDR's name ("tts"), else emoji-test.txt's. */
    name: string;
    /** CLDR's keywords, without the name itself. */
    keywords: string[];
    /** An index into `groups`. */
    group: number;
    subgroup: string;
    /** The Emoji version it came in (`E15.1` is 15.1). */
    version: number;
    /** Its light, medium-light, medium, medium-dark and dark variants, when it takes skin tones. */
    tones?: string[];
};

export type EmojiData = { groups: string[]; emoji: EmojiEntry[] };

/** The five skin tone modifiers, light to dark. */
const toneModifiers = [0x1f3fb, 0x1f3fc, 0x1f3fd, 0x1f3fe, 0x1f3ff];
const variationSelector = 0xfe0f;

type TestLine = { codepoints: number[]; emoji: string; version: number; name: string; group: string; subgroup: string };

/** The fully-qualified emoji of emoji-test.txt, in order, with their group and subgroup. The Component group (the
 *  skin tone and hair style pieces) isn't offered on its own. */
export function readEmojiTest(text: string): TestLine[] {
    const lines: TestLine[] = [];
    let group = "";
    let subgroup = "";
    for (const line of text.split("\n")) {
        const header = /^# (group|subgroup): (.+)$/.exec(line);
        if (header) {
            if (header[1] === "group") group = header[2]!.trim();
            else subgroup = header[2]!.trim();
            continue;
        }
        const match = /^([0-9A-F ]+?)\s*; fully-qualified\s*# (\S+) E(\d+\.\d+) (.+)$/.exec(line);
        if (!match || group === "Component") continue;
        lines.push({
            codepoints: match[1]!.split(" ").map((hex) => Number.parseInt(hex, 16)),
            emoji: match[2]!,
            version: Number(match[3]),
            name: match[4]!.trim(),
            group,
            subgroup,
        });
    }
    return lines;
}

/** CLDR's annotations, by emoji without its variation selectors: the keywords, and the name (`type="tts"`). */
export function readAnnotations(...xmls: string[]): Map<string, { name?: string; keywords?: string[] }> {
    const decode = (text: string) =>
        text
            .replaceAll("&lt;", "<")
            .replaceAll("&gt;", ">")
            .replaceAll("&quot;", '"')
            .replaceAll("&apos;", "'")
            .replaceAll("&amp;", "&");
    const annotations = new Map<string, { name?: string; keywords?: string[] }>();
    for (const xml of xmls) {
        for (const match of xml.matchAll(/<annotation cp="([^"]+)"( type="tts")?>([^<]*)<\/annotation>/g)) {
            const key = withoutVariationSelectors(decode(match[1]!));
            const entry = annotations.get(key) ?? {};
            const value = decode(match[3]!).trim();
            if (match[2]) entry.name = value;
            else entry.keywords = value.split("|").map((keyword) => keyword.trim()).filter((keyword) => keyword);
            annotations.set(key, entry);
        }
    }
    return annotations;
}

function withoutVariationSelectors(text: string): string {
    return [...text].filter((char) => char.codePointAt(0) !== variationSelector).join("");
}

/** The emoji of `lines` with their annotations: each skin-tone variant whose people all share one tone becomes a
 *  field of its base. A variant mixing tones isn't offered. */
export function emojiData(lines: TestLine[], annotations: ReturnType<typeof readAnnotations>): EmojiData {
    const groups: string[] = [];
    const entries: EmojiEntry[] = [];
    const bases = new Map<string, EmojiEntry>();
    const baseKey = (codepoints: number[]) =>
        codepoints
            .filter((cp) => cp !== variationSelector && !toneModifiers.includes(cp))
            .map((cp) => cp.toString(16))
            .join(" ");
    for (const line of lines) {
        const tones = line.codepoints.filter((cp) => toneModifiers.includes(cp));
        if (tones.length > 0) {
            const base = bases.get(baseKey(line.codepoints));
            const tone = toneModifiers.indexOf(tones[0]!);
            if (!base || tones.some((cp) => cp !== tones[0])) continue;
            base.tones ??= [];
            base.tones[tone] = line.emoji;
            continue;
        }
        if (!groups.includes(line.group)) groups.push(line.group);
        const annotation = annotations.get(withoutVariationSelectors(line.emoji));
        const name = annotation?.name ?? line.name;
        const entry: EmojiEntry = {
            emoji: line.emoji,
            name,
            keywords: (annotation?.keywords ?? []).filter((keyword) => keyword.toLowerCase() !== name.toLowerCase()),
            group: groups.indexOf(line.group),
            subgroup: line.subgroup,
            version: line.version,
        };
        entries.push(entry);
        bases.set(baseKey(line.codepoints), entry);
    }
    // A base takes skin tones only with all five of them.
    for (const entry of entries) {
        if (entry.tones && (entry.tones.length !== 5 || entry.tones.some((tone) => !tone))) delete entry.tones;
    }
    return { groups, emoji: entries };
}

/** The data as written: one emoji per line, so a new Unicode version shows as a readable diff. */
export function serialize(data: EmojiData): string {
    const lines = data.emoji.map((entry) => `    ${JSON.stringify(entry)}`);
    return `{\n  "groups": ${JSON.stringify(data.groups)},\n  "emoji": [\n${lines.join(",\n")}\n  ]\n}\n`;
}

function generate(): string {
    const lines = readEmojiTest(readFileSync(vendor("emoji-test.txt"), "utf8"));
    const annotations = readAnnotations(
        readFileSync(vendor("annotations/en.xml"), "utf8"),
        readFileSync(vendor("annotationsDerived/en.xml"), "utf8"),
    );
    return serialize(emojiData(lines, annotations));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const output = generate();
    if (process.argv.includes("--check")) {
        let current = "";
        try {
            current = readFileSync(outputPath, "utf8");
        } catch {}
        if (current !== output) {
            console.error("emoji-extension/src/emoji.generated.json is out of date: run `npm run generate`.");
            process.exit(1);
        }
    } else {
        writeFileSync(outputPath, output);
    }
}
