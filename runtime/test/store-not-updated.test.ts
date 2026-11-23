import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { extensionId, raycastFolder } from "../src/extension-id.ts";
import { allFilter, installedFilter, rowId } from "../store-extension/src/catalog.ts";
import { developmentRowId } from "../store-extension/src/development-builds.ts";
import { maxManifestBytes } from "../store-extension/src/files.ts";
import {
    notUpdatedAccessory,
    notUpdatedDetailMarkdown,
    notUpdatedRowId,
    notUpdatedRowsShown,
    readNotUpdated,
    uninstallNotUpdated,
    type NotUpdatedInstall,
} from "../store-extension/src/not-updated.ts";
import { installFolder, readInstalled, StoreError } from "../store-extension/src/store.ts";

const folders: string[] = [];
after(async () => {
    for (const folder of folders) await rm(folder, { recursive: true, force: true });
});

async function temporary(): Promise<string> {
    const folder = await mkdtemp(path.join(tmpdir(), "fudge-not-updated-"));
    folders.push(folder);
    return folder;
}

/** An install in `<extensions>/<folder>/<name>` with the given `package.json` text, or none. */
async function install(extensions: string, folder: string, name: string, manifest?: string | object): Promise<string> {
    const target = path.join(extensions, ...folder.split("/"), name);
    await mkdir(target, { recursive: true });
    if (manifest !== undefined) {
        await writeFile(path.join(target, "package.json"), typeof manifest === "string" ? manifest : JSON.stringify(manifest));
    }
    return target;
}

/** The id of `name` from `folder`, which must pass the id rule. */
function id(name: string, folder: string): string {
    const result = extensionId(name, folder);
    assert.ok(result, `${folder} ${name}`);
    return result;
}

/** A record as the store writes it: an added repository's names its folder. */
function record(dir: string, folder: string) {
    return {
        tree: `tree-${dir}`,
        commit: "c0ffee",
        installedAt: "2026-11-22T00:00:00.000Z",
        dir,
        ...(folder === raycastFolder ? {} : { repository: folder }),
    };
}

const switchedOff = "acme/tools";
const removed = "git.example.com/team/extensions";
const on = "owner/on";

/** Raycast's `jira` and `github`, `jira` from an added repository that's off, one that was removed, and one that's on. */
async function setUp() {
    const extensions = await temporary();
    const support = await temporary();
    const installed = {
        [id("jira", raycastFolder)]: record("jira", raycastFolder),
        [id("github", raycastFolder)]: record("github", raycastFolder),
        [id("jira", switchedOff)]: record("jira-cloud", switchedOff),
        [id("notes", removed)]: record("notes", removed),
        [id("linear", on)]: record("linear", on),
    };
    await writeFile(path.join(support, "installed.json"), `${JSON.stringify(installed, null, 2)}\n`);
    await install(extensions, raycastFolder, "jira", { name: "jira", title: "Jira", description: "Raycast's Jira" });
    await install(extensions, raycastFolder, "github", { name: "github", title: "GitHub", description: "Repositories" });
    await install(extensions, switchedOff, "jira", { name: "jira", title: "Jira Tools", description: "From acme" });
    // Its package.json can't be read: the row shows its name.
    await install(extensions, removed, "notes", "{ not json");
    await install(extensions, on, "linear", { name: "linear", title: "Linear", description: "Issues" });
    return { extensions, support };
}

const titles = (rows: NotUpdatedInstall[]) => rows.map((row) => [row.id, row.title, row.description, row.repository, row.name]);

test("installs from a repository that's off or removed get rows by title; one that's on gets none", async () => {
    const { extensions, support } = await setUp();
    const installed = await readInstalled(support);
    const raycastOn = await readNotUpdated(installed, new Set([raycastFolder, on]), extensions);
    assert.deepEqual(titles(raycastOn), [
        ["acme+tools+jira", "Jira Tools", "From acme", switchedOff, "jira"],
        ["git.example.com+team+extensions+notes", "notes", "", removed, "notes"],
    ]);

    // Raycast's switched off: its installs show the same way, each from its own folder, beside the added one of that name.
    const raycastOff = await readNotUpdated(installed, new Set([on]), extensions);
    assert.deepEqual(titles(raycastOff), [
        ["github", "GitHub", "Repositories", raycastFolder, "github"],
        ["jira", "Jira", "Raycast's Jira", raycastFolder, "jira"],
        ["acme+tools+jira", "Jira Tools", "From acme", switchedOff, "jira"],
        ["git.example.com+team+extensions+notes", "notes", "", removed, "notes"],
    ]);

    // Every repository on: no row of this kind.
    assert.deepEqual(await readNotUpdated(installed, new Set([raycastFolder, on, switchedOff, removed]), extensions), []);
});

test("an install whose package.json is missing, a link, too big or names another extension shows its name", async () => {
    const extensions = await temporary();
    const folder = "acme/tools";
    const installed = Object.fromEntries(
        ["missing", "linked", "other", "untitled", "big", "gone"].map((name) => [id(name, folder), { ...record(name, folder), repository: folder }]),
    );
    await install(extensions, folder, "missing");
    const elsewhere = await install(extensions, "elsewhere/place", "linked", { name: "linked", title: "Linked" });
    await install(extensions, folder, "linked");
    await symlink(path.join(elsewhere, "package.json"), path.join(extensions, ...folder.split("/"), "linked", "package.json"));
    await install(extensions, folder, "other", { name: "something-else", title: "Something Else" });
    await install(extensions, folder, "untitled", { name: "untitled" });
    await install(extensions, folder, "big", `{"name":"big","title":"Big","description":"${"x".repeat(maxManifestBytes)}"}`);
    // "gone" has a record and no folder at all.
    const rows = await readNotUpdated(installed, new Set([raycastFolder]), extensions);
    assert.deepEqual(
        rows.map((row) => [row.name, row.title, row.description]),
        ["big", "gone", "linked", "missing", "other", "untitled"].map((name) => [name, name, ""]),
    );
});

/** A store context whose confirmation answers `answer`, recording what it asked and what it moved to the Trash. */
function uninstallContext(extensions: string, support: string, answer: boolean) {
    const asked: string[][] = [];
    const trashed: string[] = [];
    return {
        asked,
        trashed,
        context: {
            supportPath: support,
            extensionsDir: extensions,
            confirm: async (title: string, message: string, primary: string) => {
                asked.push([title, message, primary]);
                return answer;
            },
            trash: async (target: string) => {
                trashed.push(target);
                await rm(target, { recursive: true });
            },
        },
    };
}

test("Uninstall on such a row moves only its install to the Trash and forgets only its record", async () => {
    const { extensions, support } = await setUp();
    const rows = await readNotUpdated(await readInstalled(support), new Set([on]), extensions);
    const acme = rows.find((row) => row.id === "acme+tools+jira");
    assert.ok(acme);
    const before = await readFile(path.join(support, "installed.json"), "utf8");

    const cancelled = uninstallContext(extensions, support, false);
    assert.equal(await uninstallNotUpdated(acme, cancelled.context), false);
    assert.deepEqual(cancelled.asked, [["Uninstall Jira Tools?", "It's moved to the Trash. Its settings and data stay.", "Uninstall"]]);
    assert.deepEqual(cancelled.trashed, []);
    assert.equal(await readFile(path.join(support, "installed.json"), "utf8"), before, "cancel changes nothing");

    const confirmed = uninstallContext(extensions, support, true);
    assert.equal(await uninstallNotUpdated(acme, confirmed.context), true);
    assert.deepEqual(confirmed.trashed, [path.join(extensions, "acme", "tools", "jira")]);
    assert.equal(installFolder(extensions, switchedOff, "jira"), confirmed.trashed[0]);
    const after = await readInstalled(support);
    assert.deepEqual(Object.keys(after).sort(), ["git.example.com+team+extensions+notes", "github", "jira", "owner+on+linear"]);
    assert.ok(await readFile(path.join(extensions, "raycast", "extensions", "jira", "package.json"), "utf8"), "Raycast's jira stays");
    assert.deepEqual(
        titles(await readNotUpdated(after, new Set([on]), extensions)).map((row) => row[0]),
        ["github", "jira", "git.example.com+team+extensions+notes"],
    );

    // Raycast's, with its repository off: its own folder and its bare-name record.
    const raycastJira = rows.find((row) => row.id === "jira");
    assert.ok(raycastJira);
    const raycast = uninstallContext(extensions, support, true);
    assert.equal(await uninstallNotUpdated(raycastJira, raycast.context), true);
    assert.deepEqual(raycast.trashed, [path.join(extensions, "raycast", "extensions", "jira")]);
    assert.deepEqual(Object.keys(await readInstalled(support)).sort(), ["git.example.com+team+extensions+notes", "github", "owner+on+linear"]);
});

test("Uninstall on such a row: a folder already gone still forgets the record; anything not recorded is refused", async () => {
    const { extensions, support } = await setUp();
    const rows = await readNotUpdated(await readInstalled(support), new Set([raycastFolder, on]), extensions);
    const notes = rows.find((row) => row.id === "git.example.com+team+extensions+notes");
    assert.ok(notes);
    await rm(installFolder(extensions, removed, "notes"), { recursive: true });
    const gone = uninstallContext(extensions, support, true);
    assert.equal(await uninstallNotUpdated(notes, gone.context), true);
    assert.deepEqual(gone.trashed, []);
    assert.equal((await readInstalled(support))[notes.id], undefined);

    // No longer recorded (just uninstalled), or a row whose id, name and repository don't agree: refused, nothing asked.
    const refusedRows: NotUpdatedInstall[] = [
        notes,
        { ...notes, id: "acme+tools+jira", name: "jira", repository: on },
        { ...notes, id: "acme+tools+jira", name: "github", repository: switchedOff },
        { ...notes, id: "jira", name: "jira", repository: switchedOff },
        { ...notes, id: "acme+tools+jira", name: "../jira", repository: switchedOff },
    ];
    for (const row of refusedRows) {
        const refused = uninstallContext(extensions, support, true);
        await assert.rejects(uninstallNotUpdated(row, refused.context), (error: unknown) => {
            assert.ok(error instanceof StoreError);
            assert.equal(error.message, `${row.title} wasn't installed by the Extension Store`);
            return true;
        });
        assert.deepEqual(refused.asked, [], JSON.stringify(row));
        assert.deepEqual(refused.trashed, [], JSON.stringify(row));
    }
    assert.ok(await readFile(path.join(extensions, "acme", "tools", "jira", "package.json"), "utf8"));
});

test("such rows show under All and Installed only, with their own ids, accessory and detail", () => {
    assert.equal(notUpdatedRowsShown(allFilter), true);
    assert.equal(notUpdatedRowsShown(installedFilter), true);
    for (const filter of ["category:Productivity", "repository:raycast", "repository:0123456789abcdef", ""]) {
        assert.equal(notUpdatedRowsShown(filter), false, filter);
    }
    assert.equal(notUpdatedAccessory, "Not updated");
    assert.equal(notUpdatedRowId("acme+tools+jira"), "installed:acme+tools+jira");
    assert.notEqual(notUpdatedRowId("jira"), developmentRowId("jira"));
    assert.notEqual(notUpdatedRowId("jira"), rowId(raycastFolder, "jira"));
    assert.equal(
        notUpdatedDetailMarkdown({ id: "jira", name: "jira", repository: raycastFolder, title: "Jira", description: "Issues" }),
        "# Jira\n\nIssues\n\nIts repository is off or was removed, so it isn't updated.",
    );
    assert.equal(
        notUpdatedDetailMarkdown({ id: "jira", name: "jira", repository: raycastFolder, title: "jira", description: "" }),
        "# jira\n\nIts repository is off or was removed, so it isn't updated.",
    );
});
