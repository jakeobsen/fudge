// The emoji picker's data and rules: which emoji this Mac can draw, skin tones, and Recently Used.

import data from "./emoji.generated.json" with { type: "json" };

/** One emoji, as scripts/emoji-data.ts writes it. */
export type EmojiEntry = {
    emoji: string;
    name: string;
    keywords: string[];
    group: number;
    subgroup: string;
    version: number;
    /** Light, medium-light, medium, medium-dark and dark, when it takes skin tones. */
    tones?: string[];
};

export const groups: string[] = data.groups;
export const allEmoji: EmojiEntry[] = data.emoji;

/**
 * The newest Emoji version each macOS release draws, from Apple's notes on its updates. macOS 14.0 (Sonoma) draws
 * Emoji 15.0; 14.4 added Emoji 15.1, which 15.0 to 15.3 (Sequoia) draw too; 15.4 added Emoji 16.0, which macOS 26
 * draws. A release draws its row's version until the next row: there's no gap from 14.0 up.
 */
export const emojiVersions: { macOS: [number, number]; emoji: number }[] = [
    { macOS: [14, 0], emoji: 15.0 },
    { macOS: [14, 4], emoji: 15.1 },
    { macOS: [15, 4], emoji: 16.0 },
];

/**
 * The macOS version a Darwin release (`os.release()`) is: Darwin 20 to 24 are macOS 11 to 15, and from Darwin 25
 * macOS took the next year's number (26). The minor is the point release (Darwin 24.4 is macOS 15.4). Undefined for
 * anything older than macOS 11, or that isn't a release.
 */
export function macOSVersion(darwinRelease: string): [number, number] | undefined {
    const match = /^(\d+)\.(\d+)/.exec(darwinRelease);
    if (!match) return undefined;
    const darwin = Number(match[1]);
    const minor = Number(match[2]);
    if (darwin < 20) return undefined;
    return [darwin <= 24 ? darwin - 9 : darwin + 1, minor];
}

/**
 * The newest Emoji version `macOS` draws. A release newer than the table draws the newest version it knows; one it
 * can't read, or older than the table, the oldest, so nothing shows as a box.
 */
export function newestEmojiVersion(macOS: [number, number] | undefined): number {
    let version = emojiVersions[0]!.emoji;
    if (!macOS) return version;
    for (const row of emojiVersions) {
        const [major, minor] = row.macOS;
        if (macOS[0] > major || (macOS[0] === major && macOS[1] >= minor)) version = row.emoji;
    }
    return version;
}

/** The emoji up to `version`, in Unicode's order. */
export function drawable(version: number, emoji: EmojiEntry[] = allEmoji): EmojiEntry[] {
    return emoji.filter((entry) => entry.version <= version);
}

/** The Skin Tone preference's values, as its dropdown has them. */
export const skinTones = ["default", "light", "medium-light", "medium", "medium-dark", "dark"] as const;

/** `entry` in `tone`. Emoji that don't take skin tones, and the default tone, are themselves. Two-person emoji have
 *  one variant per tone, with both people in it. */
export function toned(entry: EmojiEntry, tone: string | undefined): string {
    const index = skinTones.indexOf(tone as (typeof skinTones)[number]) - 1;
    return index >= 0 && entry.tones ? entry.tones[index]! : entry.emoji;
}

/** How many emoji Recently Used keeps. */
export const recentLimit = 16;
/** The LocalStorage key that keeps Recently Used: a JSON array of base emoji, newest first, so a new skin tone
 *  applies to them too. */
export const recentKey = "recently-used";

/** Recently Used as stored, ignoring anything that isn't an array of strings. */
export function readRecent(stored: unknown): string[] {
    if (typeof stored !== "string") return [];
    try {
        const value: unknown = JSON.parse(stored);
        return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
    } catch {
        return [];
    }
}

/** `emoji` pasted or copied: it goes first, once, and the oldest beyond `recentLimit` go. */
export function remember(recent: string[], emoji: string): string[] {
    return [emoji, ...recent.filter((other) => other !== emoji)].slice(0, recentLimit);
}

export function forget(recent: string[], emoji: string): string[] {
    return recent.filter((other) => other !== emoji);
}

/** Recently Used's entries among `available`, in its order. One that isn't drawable here is left out. */
export function recentEntries(recent: string[], available: EmojiEntry[]): EmojiEntry[] {
    const byEmoji = new Map(available.map((entry) => [entry.emoji, entry]));
    return recent.flatMap((emoji) => byEmoji.get(emoji) ?? []);
}
