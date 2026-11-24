// The Extension Store names a repository only when two extensions share a name (SPEC-175): the one name rule, read
// against the fixture the app's tests read too, the labels the list reads, and which rows show them.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { developmentFolder, extensionId } from "../src/extension-id.ts";
import { rowId, type StoreEntry } from "../store-extension/src/catalog.ts";
import {
    developmentAccessories,
    developmentBuildAccessory,
    developmentRowId,
    type DevelopmentBuild,
} from "../store-extension/src/development-builds.ts";
import {
    notUpdatedAccessories,
    notUpdatedAccessory,
    notUpdatedRowId,
    type NotUpdatedInstall,
} from "../store-extension/src/not-updated.ts";
import {
    checkRepositoriesAnswer,
    parseRepositoryAddress,
    type ParsedRepository,
    type RepositoryEntry,
} from "../store-extension/src/repository-address.ts";
import {
    checkRepositoryName,
    checkShownLabel,
    nameFolds,
    nameKey,
    trimmedScalars,
} from "../store-extension/src/repository-name.ts";
import { checkSharedLabelsAnswer, rowLabels } from "../store-extension/src/row-labels.ts";

type NameCase = { text: string; others?: string[]; name?: string | null; refused?: string; other?: string };
type NamesFixture = {
    trimmed: string[];
    folds: [string, string][];
    keys: { text: string; key: string }[];
    sets: { titles: string[]; labeled: boolean[] }[];
    names: NameCase[];
};

const fixture = JSON.parse(
    await readFile(new URL("./fixtures/repository-names.json", import.meta.url), "utf8"),
) as NamesFixture;

/** The repository at `address`, parsed beside `existing`. */
function parsed(address: string, existing: ParsedRepository[] = []): ParsedRepository {
    const repository = parseRepositoryAddress(address, undefined, existing);
    assert.ok(!("refused" in repository), `${address} parses`);
    return repository;
}

/** A listed repository as `checkRepositoriesAnswer` gives it: its name as its label unless it's named. */
function listedEntry(address: string, label?: string, on = true): RepositoryEntry {
    const repository = parsed(address);
    return { ...repository, on, label: label ?? repository.name };
}

/** A row of `repository`'s list. */
function row(title: string, repository: RepositoryEntry, name = "scratch"): StoreEntry {
    return {
        name,
        dir: name,
        copyId: repository.copyId,
        repositoryFolder: repository.folder,
        title,
        description: "",
        author: "",
        keywords: [],
        categories: [],
        commands: [],
    };
}

const entryRow = (entry: StoreEntry) => rowId(entry.repositoryFolder, entry.dir);
const build = (name: string, title: string): DevelopmentBuild => ({ name, title, description: "" });
function notUpdated(name: string, repository: string, title: string): NotUpdatedInstall {
    const id = extensionId(name, repository);
    assert.ok(id !== undefined);
    return { id, name, repository, title, description: "" };
}

const none = { entries: [], development: [], notUpdated: [], listed: [], shared: new Map() };

// MARK: - The one name rule (5.2, 5.3)

test("the fixture's trim list, fold table and keys are repository-name.ts' own", () => {
    assert.deepEqual(
        trimmedScalars.map((scalar) => scalar.toString(16).toUpperCase().padStart(4, "0")),
        fixture.trimmed,
    );
    assert.deepEqual(
        [...nameFolds].map(([scalar, fold]) => [String.fromCodePoint(scalar), fold]),
        fixture.folds,
    );
    for (const { text, key } of fixture.keys) assert.equal(nameKey(text), key, JSON.stringify(text));
});

test("the fixture's sets of titles are labeled as the app labels them", () => {
    for (const { titles, labeled } of fixture.sets) {
        const listed = titles.map((_, index) => listedEntry(`https://github.com/someone/tools${index}`));
        const entries = titles.map((title, index) => row(title, listed[index]!));
        const labels = rowLabels({ ...none, entries, listed });
        assert.deepEqual(
            entries.map((entry) => labels.get(entryRow(entry))),
            labeled.map((yes, index) => (yes ? `someone/tools${index}` : undefined)),
            JSON.stringify(titles),
        );
    }
});

test("the fixture's names are checked as the app checks them, in its order", () => {
    for (const { text, others, name, refused, other } of fixture.names) {
        const expected =
            refused === undefined ? (name ?? undefined) : { refused, ...(other === undefined ? {} : { other }) };
        assert.deepEqual(checkRepositoryName(text, others ?? []), expected, JSON.stringify(text));
    }
});

// MARK: - The list's labels (5.4)

test("each entry's label is its name when the name rule keeps it, else its name as typed, Raycast's like any", () => {
    const tools = parsed("https://github.com/someone/tools");
    const jake = parsed("https://github.com/jakeobsen/raycast", [tools]);
    const street = parsed("https://github.com/someone/street", [tools, jake]);
    const raycast = parsed("https://github.com/raycast/extensions");
    const labels = (answer: unknown[]) => checkRepositoriesAnswer(answer).map((entry) => entry.label);

    // Kept, trimmed; the entry is otherwise the same.
    assert.deepEqual(checkRepositoriesAnswer([{ ...tools, on: true, label: "  Mine " }]), [
        { ...tools, on: true, label: "Mine" },
    ]);
    // Refused: each reads as its name, and the entry stays.
    for (const refused of ["a/b", "jake‮obsen", "a".repeat(41), "Core", "development", " core "]) {
        assert.deepEqual(labels([{ ...tools, on: true, label: refused }]), ["someone/tools"], JSON.stringify(refused));
    }
    // The same name as an earlier entry's reads as none.
    assert.deepEqual(
        labels([
            { ...jake, on: true, label: "jakeobsen" },
            { ...tools, on: false, label: "JakeObsen" },
        ]),
        ["jakeobsen", "someone/tools"],
    );
    assert.deepEqual(
        labels([
            { ...street, on: true, label: "Straße" },
            { ...tools, on: true, label: "STRASSE" },
        ]),
        ["Straße", "someone/tools"],
    );
    assert.deepEqual(
        labels([
            { ...raycast, on: true, label: "Raycast" },
            { ...tools, on: true, label: "raycast" },
        ]),
        ["Raycast", "someone/tools"],
    );
    // A refused one doesn't take the name from a later one.
    assert.deepEqual(
        labels([
            { ...tools, on: true, label: "Core" },
            { ...jake, on: true, label: "Mine" },
        ]),
        ["someone/tools", "Mine"],
    );
    // A label that isn't a string is none.
    for (const label of [7, null, true, ["Mine"], { name: "Mine" }]) {
        assert.deepEqual(labels([{ ...tools, on: true, label }]), ["someone/tools"], JSON.stringify(label));
    }
    // Raycast's entry, anywhere in the list, is read like any other.
    assert.deepEqual(
        labels([
            { ...tools, on: true },
            { ...raycast, on: true, label: "Raycast" },
        ]),
        ["someone/tools", "Raycast"],
    );
    assert.deepEqual(
        labels([
            { ...raycast, on: false },
            { ...tools, on: true, label: "Tools" },
        ]),
        ["raycast/extensions", "Tools"],
    );
});

// MARK: - Which rows are labeled (2, 3)

test("the list half labels each row whose name another row has, with its own label", () => {
    const raycastNamed = listedEntry("https://github.com/raycast/extensions", "Raycast");
    const raycastUnnamed = listedEntry("https://github.com/raycast/extensions");
    const tools = listedEntry("https://github.com/someone/tools", "Tools");
    const unnamed = listedEntry("https://github.com/Someone/Other");
    const off = listedEntry("https://github.com/someone/off", "Offline", false);

    // A named Raycast's and a named repository's row with one title.
    const fromRaycast = row("Scratch", raycastNamed);
    const fromTools = row("Scratch", tools);
    let labels = rowLabels({ ...none, entries: [fromRaycast, fromTools], listed: [raycastNamed, tools] });
    assert.deepEqual([labels.get(entryRow(fromRaycast)), labels.get(entryRow(fromTools))], ["Raycast", "Tools"]);

    // An unnamed Raycast's row, beside a development build of its title.
    const plain = row("Notes", raycastUnnamed, "notes");
    labels = rowLabels({ ...none, entries: [plain], development: [build("notes", "notes")], listed: [raycastUnnamed] });
    assert.equal(labels.get(entryRow(plain)), "raycast/extensions");
    assert.equal(labels.get(developmentRowId("notes")), "development");

    // An unnamed repository's row and a development build with one title.
    const other = row("Hello World", unnamed, "hello-world");
    labels = rowLabels({
        ...none,
        entries: [other],
        development: [build("hello-world", "Hello World")],
        listed: [unnamed],
    });
    assert.deepEqual(
        [labels.get(entryRow(other)), labels.get(developmentRowId("hello-world"))],
        ["Someone/Other", "development"],
    );

    // Not updated rows, each beside a listed row of its title: from a switched-off named repository, a removed one, and
    // Raycast's folder while its entry is removed.
    const switchedOff = notUpdated("timer", "someone/off", "Timer");
    const removed = notUpdated("clock", "gone/tools", "Clock");
    const raycastGone = notUpdated("stopwatch", "raycast/extensions", "Stopwatch");
    const listedRows = [
        row("Timer", tools, "timer"),
        row("Clock", tools, "clock"),
        row("Stopwatch", tools, "stopwatch"),
    ];
    labels = rowLabels({
        ...none,
        entries: listedRows,
        notUpdated: [switchedOff, removed, raycastGone],
        listed: [tools, off],
    });
    assert.deepEqual(
        [switchedOff, removed, raycastGone].map((install) => labels.get(notUpdatedRowId(install.id))),
        ["Offline", "gone/tools", "raycast/extensions"],
    );
    assert.deepEqual(
        listedRows.map((entry) => labels.get(entryRow(entry))),
        ["Tools", "Tools", "Tools"],
    );

    // Two listed rows that aren't installed are both labeled: the store is where you choose which to install.
    const first = row("Weather", tools, "weather");
    const second = row("weather ", raycastNamed, "weather");
    labels = rowLabels({ ...none, entries: [first, second], listed: [tools, raycastNamed] });
    assert.deepEqual([labels.get(entryRow(first)), labels.get(entryRow(second))], ["Tools", "Raycast"]);

    // Two rows of one repository with one title both get its label.
    const one = row("Kimai", raycastUnnamed, "kimai");
    const two = row("Kimai", raycastUnnamed, "kimai-two");
    labels = rowLabels({ ...none, entries: [one, two], listed: [raycastUnnamed] });
    assert.deepEqual(
        [labels.get(entryRow(one)), labels.get(entryRow(two))],
        ["raycast/extensions", "raycast/extensions"],
    );

    // A row alone has none.
    const alone = row("Scratch", tools);
    assert.equal(rowLabels({ ...none, entries: [alone], listed: [tools] }).size, 0);
});

test("the installed half labels a row whose install the app labels, with the app's label", () => {
    const raycast = listedEntry("https://github.com/raycast/extensions", "Raycast");
    const jake = listedEntry("https://github.com/jakeobsen/raycast", "jake");

    // Raycast's Clipboard History, installed beside the included one, which has no row.
    const clipboard = row("Clipboard History", raycast, "clipboard-history");
    const shared = new Map([["clipboard-history", "Raycast"]]);
    assert.equal(
        rowLabels({ ...none, entries: [clipboard], listed: [raycast], shared }).get(entryRow(clipboard)),
        "Raycast",
    );
    assert.equal(rowLabels({ ...none, entries: [clipboard], listed: [raycast] }).size, 0, "not installed beside it");

    // A development build alone and a Not updated row alone, each with its id in the answer.
    const developmentId = extensionId("clipboard-history", developmentFolder)!;
    const install = notUpdated("clipboard-history", "someone/tools", "Clipboard History");
    assert.equal(
        rowLabels({
            ...none,
            development: [build("clipboard-history", "Clipboard History")],
            shared: new Map([[developmentId, "development"]]),
        }).get(developmentRowId("clipboard-history")),
        "development",
    );
    assert.equal(
        rowLabels({ ...none, notUpdated: [install], shared: new Map([[install.id, "someone/tools"]]) }).get(
            notUpdatedRowId(install.id),
        ),
        "someone/tools",
    );

    // A row the list half labels too shows the app's label, so it reads as its install does in search.
    const mine = row("Scratch", jake);
    const theirs = row("Scratch", raycast);
    const labels = rowLabels({
        ...none,
        entries: [mine, theirs],
        listed: [raycast, jake],
        shared: new Map([[extensionId("scratch", jake.folder)!, "jakeobsen"]]),
    });
    assert.deepEqual([labels.get(entryRow(mine)), labels.get(entryRow(theirs))], ["jakeobsen", "Raycast"]);

    // Ids are compared exactly: another repository's install of that name labels nothing here.
    const scratch = row("Scratch", raycast);
    assert.equal(
        rowLabels({
            ...none,
            entries: [scratch],
            listed: [raycast],
            shared: new Map([["someone+tools+scratch", "someone/tools"]]),
        }).size,
        0,
    );
});

test("a development build's and a Not updated row's accessories have the label first only while it's labeled", () => {
    assert.deepEqual(developmentAccessories(), [{ text: developmentBuildAccessory }]);
    assert.deepEqual(developmentAccessories("development"), [
        { text: "development" },
        { text: developmentBuildAccessory },
    ]);
    assert.deepEqual(notUpdatedAccessories(), [{ text: notUpdatedAccessory }]);
    assert.deepEqual(notUpdatedAccessories("someone/tools"), [
        { text: "someone/tools" },
        { text: notUpdatedAccessory },
    ]);
});

// MARK: - The app's answer (2.2)

test("the app's answer keeps each id with a label a row may show, and drops the rest", () => {
    const flags = fixture.names.find((one) => one.name?.startsWith("\u{1F1E9}\u{1F1F0}"))!.name!;
    assert.equal(Buffer.byteLength(flags, "utf8"), 320);
    const kept = {
        "clipboard-history": "Raycast",
        "someone+tools+scratch": "someone/tools",
        "fudge-clipboard-history": "Core",
        x: " development ",
        y: flags,
    };
    const dropped = {
        "Some/Thing": "Raycast",
        "": "Raycast",
        numbered: 3,
        nothing: null,
        empty: "",
        spaces: "   ",
        reversed: "jake‮obsen",
        hidden: "jake​obsen",
        "next-line": "jake\u0085obsen",
        "no-break": "jake obsen",
    };
    assert.deepEqual(
        checkSharedLabelsAnswer({ ...kept, ...dropped }),
        new Map([
            ["clipboard-history", "Raycast"],
            ["someone+tools+scratch", "someone/tools"],
            ["fudge-clipboard-history", "Core"],
            ["x", "development"],
            ["y", flags],
        ]),
    );
    for (const answer of [[["clipboard-history", "Raycast"]], null, "clipboard-history", 3, undefined]) {
        assert.deepEqual(checkSharedLabelsAnswer(answer), new Map(), JSON.stringify(answer));
    }

    // `checkShownLabel` alone.
    for (const [value, label] of [
        ["Raycast", "Raycast"],
        ["someone/tools", "someone/tools"],
        ["Core", "Core"],
        [" development ", "development"],
        [flags, flags],
    ] as const) {
        assert.equal(checkShownLabel(value), label);
    }
    for (const value of [3, null, undefined, "", "   ", "jake‮obsen", "jake​obsen", "jake\u0085obsen", "jake obsen"]) {
        assert.equal(checkShownLabel(value), undefined, JSON.stringify(value));
    }
});
