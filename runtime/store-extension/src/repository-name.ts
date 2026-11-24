// One name rule for the Extension Store and the app (SPEC-175): when two titles or repository names are the same name,
// and which repository names the rule refuses. Each step is written by hand, as the app's `ExtensionTitles.key` and
// `RepositoryNames.check` take it, never with a platform comparison: JavaScript's `trim()`, `toLowerCase()` and
// `Intl.Collator` each disagree with Swift on some names. `test/fixtures/repository-names.json` pins both sides.

/** The scalars trimmed from both ends of a name: exactly what Swift's `.whitespacesAndNewlines` trims on macOS 26.6. */
export const trimmedScalars: readonly number[] = Object.freeze([
    0x9, 0xa, 0xb, 0xc, 0xd, 0x20, 0x85, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
    0x2008, 0x2009, 0x200a, 0x200b, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
]);
const trimmedSet: ReadonlySet<number> = new Set(trimmedScalars);

/** Unicode's case foldings that lowercasing leaves out for letters people type: ß, ς, ſ and the Latin ligatures. */
export const nameFolds: ReadonlyMap<number, string> = new Map([
    [0xdf, "ss"],
    [0x3c2, "σ"],
    [0x17f, "s"],
    [0xfb00, "ff"],
    [0xfb01, "fi"],
    [0xfb02, "fl"],
    [0xfb03, "ffi"],
    [0xfb04, "ffl"],
    [0xfb05, "st"],
    [0xfb06, "st"],
]);

/** The development folder's label, which no repository may be called. */
export const developmentLabel = "development";
/** The label of the extensions in Fudge's own resources (D-179), which no repository may be called. */
export const coreLabel = "Core";
/** The longest repository name, in characters (grapheme clusters, as Swift counts them). */
export const maxNameLength = 40;

/** `text` without the trimmed scalars at either end. */
export function trimName(text: string): string {
    const scalars = [...text];
    let start = 0;
    let end = scalars.length;
    while (start < end && trimmedSet.has(scalars[start]!.codePointAt(0)!)) start += 1;
    while (end > start && trimmedSet.has(scalars[end - 1]!.codePointAt(0)!)) end -= 1;
    return scalars.slice(start, end).join("");
}

/**
 * A name's key: trimmed, decomposed (NFD), each scalar's full lowercase mapping with `nameFolds` applied, and
 * decomposed again. Two names are the same when their keys are.
 */
export function nameKey(text: string): string {
    let folded = "";
    for (const scalar of trimName(text).normalize("NFD")) {
        for (const lower of scalar.toLowerCase()) folded += nameFolds.get(lower.codePointAt(0)!) ?? lower;
    }
    return folded.normalize("NFD");
}

/** Whether two titles or repository names are the same name. */
export function sameName(first: string, second: string): boolean {
    return nameKey(first) === nameKey(second);
}

/** A control or format character, a line or paragraph separator, or a space other than U+0020. */
const refusedCharacter = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]|(?! )\p{Zs}/u;

const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });

export type NameRefusal = "slash" | "characters" | "tooLong" | "development" | "core" | "taken";

/**
 * The repository name in `text`, as the app's `RepositoryNames.check` has it, step for step and in its order: trimmed,
 * `undefined` when that leaves nothing; else refused for a `/` among its scalars, a refused character, more than 40
 * characters, being the same name as `development` or `Core`, or as one of `others` (`taken`, with the first such name
 * as written).
 */
export function checkRepositoryName(
    text: string,
    others: readonly string[] = [],
): string | undefined | { refused: NameRefusal; other?: string } {
    const name = trimName(text);
    if (name.length === 0) return undefined;
    if (name.includes("/")) return { refused: "slash" };
    if (refusedCharacter.test(name)) return { refused: "characters" };
    let count = 0;
    for (const _ of graphemes.segment(name)) count += 1;
    if (count > maxNameLength) return { refused: "tooLong" };
    if (sameName(name, developmentLabel)) return { refused: "development" };
    if (sameName(name, coreLabel)) return { refused: "core" };
    const other = others.find((candidate) => sameName(name, candidate));
    return other === undefined ? name : { refused: "taken", other };
}

/**
 * A label the app answered, as a row may show it: a string, trimmed, not empty, with none of the characters the name
 * rule refuses. It isn't the name rule: `Core`, `development` and folders such as `someone/tools` are labels too, two
 * installs from one repository share theirs, and the app's labels are already bounded by the name and folder rules, so
 * there's no length limit here.
 */
export function checkShownLabel(value: unknown): string | undefined {
    if (typeof value !== "string") return undefined;
    const label = trimName(value);
    return label.length > 0 && !refusedCharacter.test(label) ? label : undefined;
}
