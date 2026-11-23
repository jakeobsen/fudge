// Adding a repository (FUD-182): the address rule against the fixture the Swift tests read too, and the second check
// of the app's answer to `extensionRepositories()`.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { repositoryURL } from "../store-extension/src/git.ts";
import {
    type AddressRefusal,
    addressRefusalSentences,
    checkRepositoriesAnswer,
    copyIdOf,
    isValidCopyId,
    type ParsedRepository,
    parseRepositoryAddress,
    RAYCAST_COPY,
} from "../store-extension/src/repository-address.ts";

type AddressCase = {
    address: string;
    branch?: string;
    existing?: string[];
    raycastListed?: boolean;
    repository?: Omit<ParsedRepository, "address">;
    refused?: AddressRefusal;
};
type AddressFixture = {
    sentences: Record<string, string>;
    addresses: AddressCase[];
    copyIds: { valid: string[]; invalid: string[] };
};

async function fixture<T>(name: string): Promise<T> {
    return JSON.parse(await readFile(new URL(`./fixtures/${name}`, import.meta.url), "utf8")) as T;
}

/** The repositories in `addresses`, each added beside those before it, as Settings adds them. */
function added(addresses: readonly string[]): ParsedRepository[] {
    const list: ParsedRepository[] = [];
    for (const address of addresses) {
        const parsed = parseRepositoryAddress(address, undefined, list);
        assert.ok(!("refused" in parsed), `${address} is added first`);
        list.push(parsed);
    }
    return list;
}

test("each refusal has the fixtures' one sentence", async () => {
    const { sentences } = await fixture<AddressFixture>("repository-addresses.json");
    const folders = await fixture<{ sentences: Record<string, string> }>("repository-folders.json");
    assert.deepEqual(addressRefusalSentences, { ...sentences, ...folders.sentences });
});

test("an address gives the fixture's repository, or its refusal", async () => {
    const { addresses } = await fixture<AddressFixture>("repository-addresses.json");
    assert.ok(addresses.some((one) => one.repository) && addresses.some((one) => one.refused));
    for (const one of addresses) {
        const listed = one.raycastListed ?? true;
        const result = parseRepositoryAddress(one.address, one.branch, added(one.existing ?? []), listed);
        const label = JSON.stringify(one);
        if (one.refused === undefined) {
            assert.deepEqual(result, { address: one.address.trim(), ...one.repository }, label);
        } else {
            assert.deepEqual(result, { refused: addressRefusalSentences[one.refused], reason: one.refused }, label);
        }
    }
});

test("a copy id is the identity's SHA-256, and only Fudge's shape is valid", async () => {
    const { copyIds } = await fixture<AddressFixture>("repository-addresses.json");
    assert.equal(copyIdOf("https://github.com/someone/tools"), "8204a7a9998b0604");
    for (const copyId of copyIds.valid) assert.ok(isValidCopyId(copyId), copyId);
    for (const copyId of copyIds.invalid) assert.ok(!isValidCopyId(copyId), copyId);
    assert.ok(!isValidCopyId(undefined) && !isValidCopyId(16));
});

test("the app's answer is checked again: Raycast's first, then each added one that parses to its copy and folder", () => {
    const tools = parseRepositoryAddress("https://github.com/Someone/Tools", "main", []);
    const team = parseRepositoryAddress("https://git.example.org/Team/Extensions", undefined, []);
    assert.ok(!("refused" in tools) && !("refused" in team));
    const answer = [
        {
            copyId: "raycast",
            folder: "raycast/extensions",
            address: repositoryURL,
            name: "Raycast",
            on: false,
        },
        { ...tools, on: true },
        // Raycast's anywhere but first, a copy id or folder the parse doesn't give, a duplicate, a refused address.
        {
            copyId: "raycast",
            folder: "raycast/extensions",
            address: repositoryURL,
            on: true,
        },
        { ...team, copyId: "0123456789abcdef", on: true },
        { ...team, folder: "git.example.org/elsewhere", on: true },
        { ...tools, on: false },
        {
            copyId: "x",
            folder: "y",
            address: "http://git.example.org/team/extensions",
            on: true,
        },
        { ...team, on: "yes" },
        { ...team, branch: 7, on: true },
        "https://git.example.org/team/extensions",
        { ...team, on: false },
    ];
    assert.deepEqual(checkRepositoriesAnswer(answer), [
        { ...RAYCAST_COPY, on: false },
        { ...tools, on: true },
        { ...team, on: false },
    ]);
    assert.deepEqual(checkRepositoriesAnswer({ repositories: answer }), []);
    assert.deepEqual(checkRepositoriesAnswer(null), []);
});

test("Raycast's entry is known by its copy id, and counts only in first place (SPEC-160 point 10b)", () => {
    const tools = parseRepositoryAddress("https://github.com/someone/tools", undefined, []);
    assert.ok(!("refused" in tools));
    const team = parseRepositoryAddress("https://git.example.org/team/extensions", undefined, [tools]);
    assert.ok(!("refused" in team));
    const raycast = { copyId: "raycast", folder: "raycast/extensions", on: true };
    // With no Raycast entry, the first entry is an added one like any other.
    assert.deepEqual(
        checkRepositoriesAnswer([
            { ...tools, on: false },
            { ...team, on: true },
        ]),
        [
            { ...tools, on: false },
            { ...team, on: true },
        ],
    );
    assert.deepEqual(checkRepositoriesAnswer([raycast, { ...tools, on: true }]), [
        { ...RAYCAST_COPY, on: true },
        { ...tools, on: true },
    ]);
    // Raycast's anywhere but first is left out, never parsed as an added one.
    assert.deepEqual(checkRepositoriesAnswer([{ ...tools, on: true }, raycast]), [{ ...tools, on: true }]);
    // A duplicate goes, in first place as anywhere.
    assert.deepEqual(
        checkRepositoriesAnswer([
            { ...tools, on: false },
            { ...tools, on: true },
        ]),
        [{ ...tools, on: false }],
    );
    // Raycast's copy id with another folder is left out, and so is Raycast's address among the added ones: never a
    // second copy of Raycast's.
    assert.deepEqual(checkRepositoriesAnswer([{ ...raycast, folder: "someone/tools" }, { ...tools, on: true }]), [
        { ...tools, on: true },
    ]);
    const typed = "https://github.com/Raycast/Extensions";
    assert.deepEqual(
        checkRepositoriesAnswer([
            { address: typed, copyId: copyIdOf(RAYCAST_COPY.identity), folder: "raycast/extensions", on: true },
            { ...tools, on: true },
        ]),
        [{ ...tools, on: true }],
    );
    assert.deepEqual(checkRepositoriesAnswer([{ copyId: "raycast", folder: "raycast/extensions" }]), []);
});

test("Raycast's repository is named as any GitHub repository is, and cloned from git.ts' address (SPEC-160 point 6)", () => {
    assert.equal(RAYCAST_COPY.name, "raycast/extensions");
    assert.equal(RAYCAST_COPY.identity, "https://github.com/raycast/extensions");
    assert.equal(RAYCAST_COPY.address, repositoryURL);
    assert.equal(RAYCAST_COPY.copyId, "raycast");
    assert.equal(RAYCAST_COPY.folder, "raycast/extensions");
});

test("Raycast's address while it isn't listed gives Raycast's own entry, or the branch sentence (SPEC-160 point 9)", () => {
    const ten = added(Array.from({ length: 10 }, (_, index) => `https://git.example.org/team-${index}/extensions`));
    const raycast = {
        identity: "https://github.com/raycast/extensions",
        copyId: "raycast",
        name: "raycast/extensions",
        folder: "raycast/extensions",
    };
    const refused = (reason: AddressRefusal) => ({ refused: addressRefusalSentences[reason], reason });
    for (const address of ["https://github.com/Raycast/Extensions.git", " https://github.com:443/raycast/extensions/ "]) {
        const label = JSON.stringify(address);
        assert.deepEqual(parseRepositoryAddress(address, undefined, [], false), { address: address.trim(), ...raycast }, label);
        assert.deepEqual(
            parseRepositoryAddress(address, " \t", ten, false),
            { address: address.trim(), ...raycast },
            `${label}: 10 added don't count, and spaces are no branch`,
        );
        assert.deepEqual(parseRepositoryAddress(address, undefined, []), refused("alreadyListed"), `${label}: listed`);
        assert.deepEqual(parseRepositoryAddress(address, "main", ten, true), refused("alreadyListed"), `${label}: listed`);
        // Any branch, a name the rule refuses too, gives Raycast's sentence.
        for (const branch of ["main", " main ", "a..b"]) {
            assert.deepEqual(parseRepositoryAddress(address, branch, [], false), refused("raycastBranch"), `${label} ${branch}`);
        }
    }
    // Any other address is parsed as before.
    assert.deepEqual(parseRepositoryAddress("https://github.com/someone/tools", undefined, ten, false), refused("tooMany"));
    assert.deepEqual(parseRepositoryAddress("https://github.com/someone/tools", "a..b", [], false), refused("branch"));
});

test("the answer keeps to 10 added repositories, as Settings does", () => {
    const list = added(
        Array.from({ length: 11 }, (_, index) => `https://git.example.org/team-${index}/extensions`).slice(0, 10),
    );
    const eleventh = {
        address: "https://git.example.org/team-10/extensions",
        copyId: copyIdOf("https://git.example.org/team-10/extensions"),
        folder: "git.example.org/team-10/extensions",
        on: true,
    };
    const answer = [
        { copyId: "raycast", folder: "raycast/extensions", on: true },
        ...list.map((one) => ({ ...one, on: true })),
        eleventh,
    ];
    assert.equal(checkRepositoriesAnswer(answer).length, 11);
});
