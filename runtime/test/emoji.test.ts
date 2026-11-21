import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { build } from "esbuild";
import React, { createElement, type FunctionComponent } from "react";
import * as jsxRuntime from "react/jsx-runtime";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";
import type { UINode } from "../src/renderer/serialize.ts";
import { emojiData, readAnnotations, readEmojiTest, serialize } from "../scripts/emoji-data.ts";
import {
    allEmoji,
    drawable,
    emojiVersions,
    forget,
    macOSVersion,
    newestEmojiVersion,
    readRecent,
    recentEntries,
    recentKey,
    recentLimit,
    remember,
    toned,
} from "../emoji-extension/src/emoji.ts";
import { mount, type Mounted } from "./support/mount.ts";

// The generator, on real lines of the vendored files.

const testLines = `# group: Smileys & Emotion
# subgroup: face-smiling
1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face
# subgroup: face-neutral-skeptical
1F642 200D 2194 FE0F                                   ; fully-qualified     # 🙂‍↔️ E15.1 head shaking horizontally
1F642 200D 2194                                        ; minimally-qualified # 🙂‍↔ E15.1 head shaking horizontally
# group: People & Body
# subgroup: hand-single-finger
261D FE0F                                              ; fully-qualified     # ☝️ E0.6 index pointing up
261D                                                   ; unqualified         # ☝ E0.6 index pointing up
261D 1F3FB                                             ; fully-qualified     # ☝🏻 E1.0 index pointing up: light skin tone
261D 1F3FC                                             ; fully-qualified     # ☝🏼 E1.0 index pointing up: medium-light skin tone
261D 1F3FD                                             ; fully-qualified     # ☝🏽 E1.0 index pointing up: medium skin tone
261D 1F3FE                                             ; fully-qualified     # ☝🏾 E1.0 index pointing up: medium-dark skin tone
261D 1F3FF                                             ; fully-qualified     # ☝🏿 E1.0 index pointing up: dark skin tone
# subgroup: family
1F9D1 200D 1F91D 200D 1F9D1                            ; fully-qualified     # 🧑‍🤝‍🧑 E12.0 people holding hands
1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FB                ; fully-qualified     # 🧑🏻‍🤝‍🧑🏻 E12.0 people holding hands: light skin tone
1F9D1 1F3FB 200D 1F91D 200D 1F9D1 1F3FC                ; fully-qualified     # 🧑🏻‍🤝‍🧑🏼 E12.1 people holding hands: light skin tone, medium-light skin tone
1F9D1 1F3FC 200D 1F91D 200D 1F9D1 1F3FC                ; fully-qualified     # 🧑🏼‍🤝‍🧑🏼 E12.0 people holding hands: medium-light skin tone
1F9D1 1F3FD 200D 1F91D 200D 1F9D1 1F3FD                ; fully-qualified     # 🧑🏽‍🤝‍🧑🏽 E12.0 people holding hands: medium skin tone
1F9D1 1F3FE 200D 1F91D 200D 1F9D1 1F3FE                ; fully-qualified     # 🧑🏾‍🤝‍🧑🏾 E12.0 people holding hands: medium-dark skin tone
1F9D1 1F3FF 200D 1F91D 200D 1F9D1 1F3FF                ; fully-qualified     # 🧑🏿‍🤝‍🧑🏿 E12.0 people holding hands: dark skin tone
# group: Component
# subgroup: skin-tone
1F3FB                                                  ; component           # 🏻 E1.0 light skin tone
`;
const annotationsXml = `
		<annotation cp="😀">cheerful | cheery | face | grin | grinning | happy | laugh | nice | smile | smiling | teeth</annotation>
		<annotation cp="😀" type="tts">grinning face</annotation>
		<annotation cp="☝">finger | hand | index | point | pointing | this | up</annotation>
		<annotation cp="☝" type="tts">index pointing up</annotation>`;
const derivedXml = `
		<annotation cp="🙂‍↔">head | horizontally | no | shake | shaking</annotation>
		<annotation cp="🙂‍↔" type="tts">head shaking horizontally</annotation>
		<annotation cp="🧑‍🤝‍🧑">bae | bestie | bff | couple | dating | flirt | friends | hand | hold | people | twins</annotation>
		<annotation cp="🧑‍🤝‍🧑" type="tts">people holding hands</annotation>`;

test("the generator keeps fully-qualified emoji, with CLDR's names and keywords, and folds skin tones into bases", () => {
    const data = emojiData(readEmojiTest(testLines), readAnnotations(annotationsXml, derivedXml));
    assert.deepEqual(data.groups, ["Smileys & Emotion", "People & Body"], "no Component group");
    assert.deepEqual(
        data.emoji.map((entry) => entry.emoji),
        ["😀", "🙂‍↔️", "☝️", "🧑‍🤝‍🧑"],
        "fully-qualified only, and no variant on its own",
    );
    const [grinning, shaking, pointing, holding] = data.emoji;
    assert.deepEqual(grinning, {
        emoji: "😀",
        name: "grinning face",
        keywords: ["cheerful", "cheery", "face", "grin", "grinning", "happy", "laugh", "nice", "smile", "smiling", "teeth"],
        group: 0,
        subgroup: "face-smiling",
        version: 1,
    });
    // CLDR keys sequences without their variation selectors.
    assert.equal(shaking!.name, "head shaking horizontally");
    assert.deepEqual(shaking!.keywords, ["head", "horizontally", "no", "shake", "shaking"]);
    assert.equal(shaking!.version, 15.1);
    // ☝️'s base has FE0F and its variants don't; they still fold in, light to dark.
    assert.deepEqual(pointing!.tones, ["☝🏻", "☝🏼", "☝🏽", "☝🏾", "☝🏿"]);
    assert.equal(pointing!.group, 1);
    // Two people: one variant per tone with both in it; mixed tones aren't offered.
    assert.deepEqual(holding!.tones, ["🧑🏻‍🤝‍🧑🏻", "🧑🏼‍🤝‍🧑🏼", "🧑🏽‍🤝‍🧑🏽", "🧑🏾‍🤝‍🧑🏾", "🧑🏿‍🤝‍🧑🏿"]);
    assert.equal(grinning!.tones, undefined);
});

test("the generated file is what the generator writes from the vendored files", () => {
    const vendor = (name: string) => readFileSync(path.join(import.meta.dirname, "../vendor/unicode", name), "utf8");
    const data = emojiData(
        readEmojiTest(vendor("emoji-test.txt")),
        readAnnotations(vendor("annotations/en.xml"), vendor("annotationsDerived/en.xml")),
    );
    const generated = readFileSync(path.join(import.meta.dirname, "../emoji-extension/src/emoji.generated.json"), "utf8");
    assert.equal(serialize(data), generated);
    assert.ok(data.emoji.length > 1800);
    assert.ok(data.emoji.some((entry) => entry.version === 16), "Emoji 16.0 is in");
});

// Which emoji the Mac draws.

test("os.release()'s Darwin version maps to macOS", () => {
    assert.deepEqual(macOSVersion("23.0.0"), [14, 0]);
    assert.deepEqual(macOSVersion("23.4.0"), [14, 4]);
    assert.deepEqual(macOSVersion("24.3.0"), [15, 3]);
    assert.deepEqual(macOSVersion("24.4.0"), [15, 4]);
    assert.deepEqual(macOSVersion("25.0.0"), [26, 0], "Darwin 25 is macOS 26");
    assert.deepEqual(macOSVersion("25.2.0"), [26, 2]);
    assert.deepEqual(macOSVersion("26.0.0"), [27, 0]);
    assert.deepEqual(macOSVersion("20.6.0"), [11, 6]);
    assert.equal(macOSVersion("19.6.0"), undefined);
    assert.equal(macOSVersion("junk"), undefined);
});

test("each macOS release draws the Emoji version Apple's notes give it", () => {
    const emoji = (darwin: string) => newestEmojiVersion(macOSVersion(darwin));
    assert.equal(emoji("23.0.0"), 15.0, "macOS 14.0");
    assert.equal(emoji("23.3.0"), 15.0, "macOS 14.3");
    assert.equal(emoji("23.4.0"), 15.1, "macOS 14.4 added Emoji 15.1");
    assert.equal(emoji("24.0.0"), 15.1, "macOS 15.0");
    assert.equal(emoji("24.3.0"), 15.1, "macOS 15.3");
    assert.equal(emoji("24.4.0"), 16.0, "macOS 15.4 added Emoji 16.0");
    assert.equal(emoji("25.0.0"), 16.0, "macOS 26");
    assert.equal(emoji("26.0.0"), 16.0, "newer than the table: the newest version it knows");
    assert.equal(emoji("junk"), 15.0, "unreadable: the oldest, so nothing shows as a box");
    // What that leaves out.
    const names = (version: number) => new Set(drawable(version).map((entry) => entry.name));
    assert.ok(!names(15.0).has("head shaking horizontally"), "Emoji 15.1 needs macOS 14.4");
    assert.ok(names(15.1).has("head shaking horizontally"));
    assert.ok(!names(15.1).has("face with bags under eyes"), "Emoji 16.0 needs macOS 15.4");
    assert.ok(names(16.0).has("face with bags under eyes"));
});

test("no skin tone is newer than its base on any Mac: a tone shown is always drawable", () => {
    // A base the Mac draws shows its tones too, so each tone must come in no later than its base's row of the
    // version table, or a future Unicode update could show boxes (the review of #103).
    const lines = readEmojiTest(readFileSync(path.join(import.meta.dirname, "../vendor/unicode/emoji-test.txt"), "utf8"));
    const modifiers = new Set([0x1f3fb, 0x1f3fc, 0x1f3fd, 0x1f3fe, 0x1f3ff]);
    const key = (codepoints: number[]) => codepoints.filter((cp) => cp !== 0xfe0f && !modifiers.has(cp)).join(" ");
    const bases = new Map(lines.filter((line) => !line.codepoints.some((cp) => modifiers.has(cp))).map((line) => [key(line.codepoints), line]));
    let tones = 0;
    for (const line of lines.filter((each) => each.codepoints.some((cp) => modifiers.has(cp)))) {
        const base = bases.get(key(line.codepoints));
        if (!base) continue;
        tones += 1;
        for (const { emoji: drawn } of emojiVersions) {
            assert.ok(base.version > drawn || line.version <= drawn, `${line.name} (E${line.version}) on a Mac drawing E${drawn}`);
        }
    }
    assert.ok(tones > 1000);
});

// Skin tones and Recently Used.

const thumbs = allEmoji.find((entry) => entry.name === "thumbs up")!;
const grinning = allEmoji.find((entry) => entry.name === "grinning face")!;
const holding = allEmoji.find((entry) => entry.name === "people holding hands")!;

test("a skin tone applies to the emoji that take one, both people included", () => {
    assert.equal(toned(thumbs, "default"), "👍");
    assert.equal(toned(thumbs, undefined), "👍");
    assert.equal(toned(thumbs, "medium"), "👍🏽");
    assert.equal(toned(thumbs, "dark"), "👍🏿");
    assert.equal(toned(grinning, "dark"), "😀", "no skin tone: unchanged");
    assert.equal(toned(holding, "medium-light"), "🧑🏼‍🤝‍🧑🏼");
    assert.equal(toned(thumbs, "purple"), "👍", "an unknown value is the default");
});

test("Recently Used keeps the newest first, once each, up to its cap", () => {
    let recent: string[] = [];
    for (const emoji of ["😀", "👍", "😀"]) recent = remember(recent, emoji);
    assert.deepEqual(recent, ["😀", "👍"]);
    for (const entry of allEmoji.slice(0, 30)) recent = remember(recent, entry.emoji);
    assert.equal(recent.length, recentLimit);
    assert.equal(recent[0], allEmoji[29]!.emoji);
    assert.deepEqual(forget(["😀", "👍", "❤️"], "👍"), ["😀", "❤️"]);
    assert.deepEqual(readRecent(JSON.stringify(["😀", 3, "👍"])), ["😀", "👍"]);
    assert.deepEqual(readRecent("not json"), []);
    assert.deepEqual(readRecent(undefined), []);
    // Stored as base emoji: they come back as entries, so a new skin tone applies.
    assert.deepEqual(
        recentEntries(["👍", "🫩", "😀"], drawable(15.1)).map((entry) => entry.name),
        ["thumbs up", "grinning face"],
        "one the Mac can't draw is left out",
    );
});

// The command, compiled as `fudge build` compiles it.

let folder = "";
let calls: RpcRequest[] = [];

function launch(preferences: Record<string, unknown>) {
    setLaunchContext({
        preferences,
        environment: {
            ...placeholderEnvironment,
            extensionName: "fudge-emoji",
            commandName: "search-emoji",
            commandMode: "view",
            localStoragePath: path.join(folder, "local-storage.json"),
        },
        launchProps: {},
    });
}

beforeEach(() => {
    folder = mkdtempSync(path.join(tmpdir(), "fudge-emoji-"));
    calls = [];
    launch({ skinTone: "default" });
    // A fake app: Paste's title asks for the frontmost app; everything else (the paste, the copy) just succeeds.
    connect((request) => {
        calls.push(request);
        const answer =
            request.method === "applications.frontmost"
                ? { name: "TextEdit", path: "/System/Applications/TextEdit.app", bundleId: "com.apple.TextEdit" }
                : null;
        setImmediate(() => settle(request.id, answer));
    });
});
afterEach(() => {
    connect(null);
    rmSync(folder, { recursive: true, force: true });
});

let compiled: Promise<string> | null = null;

async function loadCommand(): Promise<FunctionComponent> {
    compiled ??= build({
        entryPoints: [path.join(import.meta.dirname, "../emoji-extension/src/search-emoji.tsx")],
        bundle: true,
        platform: "node",
        format: "cjs",
        target: "node22",
        jsx: "automatic",
        external: ["@raycast/api", "react", "react/jsx-runtime"],
        write: false,
        logLevel: "silent",
    }).then((result) => result.outputFiles[0]!.text);
    const provided: Record<string, unknown> = {
        "@raycast/api": createApiModule(),
        react: React,
        "react/jsx-runtime": jsxRuntime,
    };
    const fallback = createRequire(import.meta.url);
    const require = (name: string) => (Object.hasOwn(provided, name) ? provided[name] : fallback(name));
    const module = { exports: {} as { default?: FunctionComponent } };
    new Function("module", "exports", "require", await compiled)(module, module.exports, require);
    return module.exports.default!;
}

const view = (mounted: Mounted) => mounted.snapshots.at(-1)!.view!;
const sections = (mounted: Mounted) => view(mounted).children.filter((child) => child.type === "Grid.Section");
const cell = (mounted: Mounted, name: string, section?: string) =>
    sections(mounted)
        .filter((each) => section === undefined || each.props.title === section)
        .flatMap((each) => each.children)
        .find((item) => item.props.title === name)!;

async function open(): Promise<Mounted> {
    const mounted = await mount(createElement(await loadCommand()));
    await mounted.settle();
    return mounted;
}

/** Fudge's own filtering, as `ListContent` reads it: the title and the keywords. */
const matches = (item: UINode, text: string) =>
    [item.props.title, ...((item.props.keywords as string[] | undefined) ?? [])].some((word) =>
        String(word).toLowerCase().includes(text),
    );

test("the grid: 8 columns, Unicode's groups in order, each emoji drawn as itself with its name and keywords", async () => {
    const mounted = await open();
    assert.equal(view(mounted).type, "Grid");
    assert.equal(view(mounted).props.columns, 8);
    assert.deepEqual(
        sections(mounted).map((section) => section.props.title),
        ["Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Travel & Places", "Activities", "Objects", "Symbols", "Flags"],
        "no Recently Used while it's empty",
    );
    const item = cell(mounted, "thumbs up");
    assert.equal(item.props.content, "👍");
    // Search by name or keyword finds it.
    const all = sections(mounted).flatMap((section) => section.children);
    for (const [text, name] of [
        ["thumbs", "thumbs up"],
        ["+1", "thumbs up"],
        ["heart", "red heart"],
    ]) {
        assert.ok(
            all.filter((each) => matches(each, text)).some((each) => each.props.title === name),
            `"${text}" finds ${name}`,
        );
    }
});

/** `item`'s actions, asked for as the app asks for a held-back panel. */
function actionsOf(mounted: Mounted, item: UINode): UINode[] {
    const [answer] = mounted.root.slots([item.id]);
    const panel = answer!.slots.actions as unknown as UINode;
    return panel.children.flatMap((section) => section.children);
}

test("a skin tone shows and pastes in that tone", async () => {
    launch({ skinTone: "medium-dark" });
    const mounted = await open();
    const item = cell(mounted, "thumbs up");
    assert.equal(item.props.content, "👍🏾");
    const paste = actionsOf(mounted, item).find((action) => action.props.title === "Paste Emoji")!;
    await mounted.root.dispatch(paste.id, ["onAction"], []);
    await mounted.settle();
    const pasted = calls.find((call) => call.method === "clipboard.paste");
    assert.equal((pasted?.params as { text?: string } | undefined)?.text, "👍🏾");
    assert.equal(cell(mounted, "grinning face").props.content, "😀");
    assert.equal(cell(mounted, "people holding hands").props.content, "🧑🏾‍🤝‍🧑🏾");
});

test("pasting or copying puts the emoji first in Recently Used, which is kept, and can be removed or cleared", async () => {
    const mounted = await open();
    const run = async (item: UINode, title: string) => {
        const action = actionsOf(mounted, item).find((entry) => entry.props.title === title);
        assert.ok(action, `${title} on ${String(item.props.title)}`);
        await mounted.root.dispatch(action.id, ["onAction"], []);
        await mounted.settle();
        await mounted.settle();
    };
    await run(cell(mounted, "thumbs up"), "Copy Emoji");
    await run(cell(mounted, "grinning face"), "Paste Emoji");
    assert.equal(sections(mounted)[0]!.props.title, "Recently Used");
    assert.deepEqual(
        sections(mounted)[0]!.children.map((item) => item.props.content),
        ["😀", "👍"],
        "newest first",
    );
    const stored = JSON.parse(readFileSync(path.join(folder, "local-storage.json"), "utf8")) as Record<string, string>;
    assert.deepEqual(JSON.parse(stored[recentKey]!), ["😀", "👍"]);

    // A recent item has Remove and Clear; the others don't.
    await run(cell(mounted, "thumbs up", "Recently Used"), "Remove from Recently Used");
    assert.deepEqual(sections(mounted)[0]!.children.map((item) => item.props.content), ["😀"]);
    await run(cell(mounted, "grinning face", "Recently Used"), "Clear Recently Used");
    assert.notEqual(sections(mounted)[0]!.props.title, "Recently Used");
});
