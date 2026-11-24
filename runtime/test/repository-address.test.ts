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
        const result = parseRepositoryAddress(one.address, one.branch, added(one.existing ?? []));
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

test("the app's answer is checked again: every entry the same way, each that parses to its copy and folder", () => {
    const tools = parseRepositoryAddress("https://github.com/Someone/Tools", "main", []);
    const team = parseRepositoryAddress("https://git.example.org/Team/Extensions", undefined, []);
    const raycast = parseRepositoryAddress("https://github.com/raycast/extensions", undefined, []);
    assert.ok(!("refused" in tools) && !("refused" in team) && !("refused" in raycast));
    const answer = [
        { ...tools, on: true },
        // Raycast's second, named: the name the app answers isn't read here.
        { ...raycast, name: "Raycast", on: false },
        // A second Raycast's, a copy id or folder the parse doesn't give, a duplicate, a refused address.
        { ...raycast, on: true },
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
        { ...tools, on: true, label: tools.name },
        { ...raycast, on: false, label: raycast.name },
        { ...team, on: false, label: team.name },
    ]);
    assert.deepEqual(checkRepositoriesAnswer({ repositories: answer }), []);
    assert.deepEqual(checkRepositoriesAnswer(null), []);
});

test("Raycast's entry counts at any place, once, and only as its address parses (SPEC-176)", () => {
    const tools = parseRepositoryAddress("https://github.com/someone/tools", undefined, []);
    assert.ok(!("refused" in tools));
    const team = parseRepositoryAddress("https://git.example.org/team/extensions", undefined, [tools]);
    assert.ok(!("refused" in team));
    const raycast = parseRepositoryAddress("https://github.com/raycast/extensions", undefined, []);
    assert.ok(!("refused" in raycast));
    // First, second and last alike, in the list's order.
    for (const list of [
        [raycast, tools, team],
        [tools, raycast, team],
        [tools, team, raycast],
    ]) {
        const answer = list.map((entry, index) => ({ ...entry, on: index !== 1 }));
        assert.deepEqual(
            checkRepositoriesAnswer(answer),
            answer.map((entry) => ({ ...entry, label: entry.name })),
            JSON.stringify(list.map((entry) => entry.copyId)),
        );
    }
    // A second is left out, as any duplicate is, however its address is typed.
    const typed = {
        address: "https://github.com/Raycast/Extensions.git",
        copyId: "raycast",
        folder: "raycast/extensions",
        on: true,
    };
    assert.deepEqual(checkRepositoriesAnswer([{ ...tools, on: true }, { ...raycast, on: true }, typed]), [
        { ...tools, on: true, label: tools.name },
        { ...raycast, on: true, label: raycast.name },
    ]);
    assert.deepEqual(checkRepositoriesAnswer([typed, { ...raycast, on: false }]), [
        {
            address: typed.address,
            identity: RAYCAST_COPY.identity,
            copyId: "raycast",
            name: "Raycast/Extensions",
            folder: "raycast/extensions",
            on: true,
            label: "Raycast/Extensions",
        },
    ]);
    // Raycast's copy id with another folder is left out, and so is its address answered with another copy id: never a
    // second copy of Raycast's.
    assert.deepEqual(checkRepositoriesAnswer([{ ...raycast, folder: "someone/tools", on: true }, { ...tools, on: true }]), [
        { ...tools, on: true, label: tools.name },
    ]);
    assert.deepEqual(
        checkRepositoriesAnswer([
            { ...raycast, copyId: copyIdOf(RAYCAST_COPY.identity), on: true },
            { ...tools, on: true },
        ]),
        [{ ...tools, on: true, label: tools.name }],
    );
    // An entry with no address, or with a branch, is left out, Raycast's as any other.
    assert.deepEqual(checkRepositoriesAnswer([{ copyId: "raycast", folder: "raycast/extensions", on: true }]), []);
    assert.deepEqual(checkRepositoriesAnswer([{ ...raycast, branch: "main", on: true }]), []);
});

test("Raycast's copy as the store knows it: its fixed place, cloned from git.ts' address", () => {
    assert.equal(RAYCAST_COPY.name, "raycast/extensions");
    assert.equal(RAYCAST_COPY.identity, "https://github.com/raycast/extensions");
    assert.equal(RAYCAST_COPY.address, repositoryURL);
    assert.equal(RAYCAST_COPY.copyId, "raycast");
    assert.equal(RAYCAST_COPY.folder, "raycast/extensions");
});

test("Raycast's address goes through every check any address does, and gives Raycast's own entry (SPEC-176)", () => {
    const others = Array.from({ length: 12 }, (_, index) => `https://git.example.org/team-${index}/extensions`);
    const eleven = added(others.slice(0, 11));
    const twelve = added(others);
    const listed = added(["https://github.com/raycast/extensions"]);
    const raycast = {
        identity: "https://github.com/raycast/extensions",
        copyId: "raycast",
        folder: "raycast/extensions",
    };
    const refused = (reason: AddressRefusal) => ({ refused: addressRefusalSentences[reason], reason });
    for (const [address, name] of [
        ["https://github.com/Raycast/Extensions.git", "Raycast/Extensions"],
        [" https://github.com:443/raycast/extensions/ ", "raycast/extensions"],
    ] as const) {
        const label = JSON.stringify(address);
        const entry = { address: address.trim(), ...raycast, name };
        assert.deepEqual(parseRepositoryAddress(address, undefined, []), entry, `${label}: named as typed`);
        assert.deepEqual(parseRepositoryAddress(address, " \t", eleven), entry, `${label}: the twelfth; spaces are no branch`);
        assert.deepEqual(parseRepositoryAddress(address, undefined, twelve), refused("tooMany"), `${label}: counted`);
        assert.deepEqual(parseRepositoryAddress(address, undefined, listed), refused("alreadyListed"), `${label}: listed`);
        // Any branch, a name the rule refuses too, gives Raycast's sentence, before the list is looked at.
        for (const branch of ["main", " main ", "a..b"]) {
            assert.deepEqual(parseRepositoryAddress(address, branch, []), refused("raycastBranch"), `${label} ${branch}`);
            assert.deepEqual(parseRepositoryAddress(address, branch, listed), refused("raycastBranch"), `${label} ${branch}`);
        }
    }
    // Any other address is parsed as before.
    assert.deepEqual(parseRepositoryAddress("https://github.com/someone/tools", undefined, twelve), refused("tooMany"));
    assert.deepEqual(parseRepositoryAddress("https://github.com/someone/tools", "a..b", []), refused("branch"));
});

test("the answer keeps to 12 repositories, Raycast's counted, as Settings does", () => {
    const entry = (address: string) => {
        const parsed = parseRepositoryAddress(address, undefined, []);
        assert.ok(!("refused" in parsed), address);
        return { ...parsed, on: true };
    };
    const raycast = entry("https://github.com/raycast/extensions");
    const others = Array.from({ length: 12 }, (_, index) => entry(`https://git.example.org/team-${index}/extensions`));
    const copyIds = (entries: readonly { copyId: string }[]) => entries.map((one) => one.copyId);
    assert.deepEqual(copyIds(checkRepositoriesAnswer(others)), copyIds(others), "12 others");
    assert.deepEqual(
        copyIds(checkRepositoriesAnswer([raycast, ...others])),
        ["raycast", ...copyIds(others.slice(0, 11))],
        "Raycast's first and 11 others; the twelfth is left out",
    );
    assert.deepEqual(
        copyIds(checkRepositoriesAnswer([...others.slice(0, 11), raycast])),
        [...copyIds(others.slice(0, 11)), "raycast"],
        "Raycast's twelfth and last",
    );
    assert.deepEqual(copyIds(checkRepositoriesAnswer([...others, raycast])), copyIds(others), "a thirteenth is left out");
});
