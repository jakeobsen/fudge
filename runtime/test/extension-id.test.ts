// The id rule and the repository folder rule (FUD-183), against the fixtures the Swift tests read too.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { extensionId, isValidExtensionId } from "../src/extension-id.ts";
import {
    developmentFolder,
    type FolderRefusal,
    isValidRepositoryFolder,
    raycastFolder,
    refusalSentences,
    repositoryFolder,
    repositoryFolderConflict,
} from "../store-extension/src/repository-folder.ts";

type FolderCase = { host: string; port?: number; segments: string[]; folder?: string; refused?: FolderRefusal };
type FolderFixture = {
    sentences: Record<FolderRefusal, string>;
    folders: FolderCase[];
    valid: string[];
    invalid: string[];
    conflicts: { folder: string; existing: string[]; refused: FolderRefusal | null }[];
};

async function fixture<T>(name: string): Promise<T> {
    return JSON.parse(await readFile(new URL(`./fixtures/${name}`, import.meta.url), "utf8")) as T;
}

test("each refusal has the fixture's one sentence", async () => {
    const { sentences } = await fixture<FolderFixture>("repository-folders.json");
    assert.deepEqual(refusalSentences, sentences);
});

test("a repository's folder is the fixture's, or refused with its reason", async () => {
    const { folders } = await fixture<FolderFixture>("repository-folders.json");
    assert.ok(folders.some((one) => one.folder) && folders.some((one) => one.refused));
    for (const one of folders) {
        const expected = one.folder === undefined ? { refused: one.refused } : { folder: one.folder };
        assert.deepEqual(repositoryFolder(one.host, one.port, one.segments), expected, JSON.stringify(one));
        if (one.folder !== undefined) assert.ok(isValidRepositoryFolder(one.folder), one.folder);
    }
});

test("isValid accepts exactly the folders the rule gives", async () => {
    const { valid, invalid } = await fixture<FolderFixture>("repository-folders.json");
    assert.ok(valid.includes(raycastFolder) && valid.includes(developmentFolder));
    for (const folder of valid) assert.ok(isValidRepositoryFolder(folder), folder);
    for (const folder of invalid) assert.ok(!isValidRepositoryFolder(folder), JSON.stringify(folder));
    assert.ok(!isValidRepositoryFolder(undefined) && !isValidRepositoryFolder(7));
});

test("a folder equal to another, or inside one, or holding one, is refused", async () => {
    const { conflicts } = await fixture<FolderFixture>("repository-folders.json");
    for (const one of conflicts) {
        assert.equal(repositoryFolderConflict(one.folder, one.existing), one.refused ?? undefined, JSON.stringify(one));
    }
});

test("the id rule is the app's: one fixture pins both", async () => {
    const ids = await fixture<{ valid: string[]; invalid: string[] }>("extension-ids.json");
    assert.ok(ids.valid.length > 0 && ids.invalid.length > 0);
    for (const id of ids.valid) assert.ok(isValidExtensionId(id), id);
    for (const id of ids.invalid) assert.ok(!isValidExtensionId(id), JSON.stringify(id));
    assert.ok(!isValidExtensionId(undefined) && !isValidExtensionId(null));
});

test("an install's id: the bare name in Raycast's folder, else the folder's segments and the name joined with +", () => {
    assert.equal(extensionId("github", raycastFolder), "github");
    assert.equal(extensionId("github", developmentFolder), "fudgeapp+development+github");
    assert.equal(extensionId("github", "someone/tools"), "someone+tools+github");
    assert.equal(extensionId("github", "git.example.org_8443/team/extensions"), "git.example.org_8443+team+extensions+github");
    assert.equal(extensionId("Github", "someone/tools"), undefined);
    assert.equal(extensionId("x+github", "git.example.org/team"), undefined);
    assert.equal(extensionId("github", "Someone/tools"), undefined);
});
