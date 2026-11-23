import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import {
    developmentBuildAccessory,
    developmentBuildFolder,
    developmentDetailMarkdown,
    developmentRowId,
    developmentRowsShown,
    installOnlyRowActions,
    installOnlyRowsReady,
    readDevelopmentBuilds,
    uninstallDevelopmentBuild,
    type DevelopmentBuild,
} from "../store-extension/src/development-builds.ts";
import { allFilter, installedFilter } from "../store-extension/src/catalog.ts";
import { maxManifestBytes } from "../store-extension/src/files.ts";
import { bundledNames } from "../store-extension/src/store.ts";

const folders: string[] = [];
after(async () => {
    for (const folder of folders) await rm(folder, { recursive: true, force: true });
});

async function temporary(): Promise<string> {
    const folder = await mkdtemp(path.join(tmpdir(), "fudge-development-"));
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

const development = "fudgeapp/development";

test("development builds: each folder in fudgeapp/development gets a row, by its folder's name", async () => {
    const extensions = await temporary();
    await install(extensions, development, "github", { name: "github", title: "GitHub", description: "Repositories" });
    // R1: a folder whose manifest names another extension, beside that extension's own folder.
    await install(extensions, development, "foo", { name: "bar", title: "Bar from foo" });
    await install(extensions, development, "bar", { name: "bar", title: "Bar" });
    await install(extensions, development, "broken", "{ not json");
    await install(extensions, development, "missing");
    await install(extensions, development, "untitled", { name: "untitled" });
    await install(extensions, development, "big", `{"name":"big","title":"Big","description":"${"x".repeat(maxManifestBytes)}"}`);
    const linkedManifest = await install(extensions, "elsewhere", "linked", { name: "linked", title: "Linked" });
    await install(extensions, development, "linked");
    await symlink(path.join(linkedManifest, "package.json"), path.join(extensions, development, "linked", "package.json"));
    // N1: a bundled extension's name gets its row too, so the build can be removed.
    await install(extensions, development, "fudge-emoji", { name: "fudge-emoji", title: "Search Emoji" });
    assert.ok(bundledNames.includes("fudge-emoji"));
    // No row: a hidden entry, a link, a file, and a folder whose name isn't an extension name.
    await install(extensions, development, ".hidden", { name: "hidden", title: "Hidden" });
    const outside = await install(extensions, "elsewhere", "outside", { name: "outside", title: "Outside" });
    await symlink(outside, path.join(extensions, development, "outside"));
    await writeFile(path.join(extensions, development, "notes"), "a file");
    await install(extensions, development, "Upper", { name: "Upper", title: "Upper" });
    await install(extensions, development, "with space", { name: "with space", title: "With Space" });

    const builds = await readDevelopmentBuilds(extensions);
    assert.deepEqual(builds, [
        { name: "bar", title: "Bar", description: "" },
        { name: "big", title: "big", description: "" },
        { name: "broken", title: "broken", description: "" },
        { name: "foo", title: "foo", description: "" },
        { name: "github", title: "GitHub", description: "Repositories" },
        { name: "linked", title: "linked", description: "" },
        { name: "missing", title: "missing", description: "" },
        { name: "fudge-emoji", title: "Search Emoji", description: "" },
        { name: "untitled", title: "untitled", description: "" },
    ]);
    const ids = builds.map((build) => developmentRowId(build.name));
    assert.equal(new Set(ids).size, ids.length, "each row has its own id");
    assert.equal(developmentRowId("foo"), "development:foo");
    assert.notEqual(developmentRowId("foo"), developmentRowId("bar"));
    assert.equal(developmentBuildAccessory, "Development build");
});

test("development builds: none without the folder, and none through a link at either level", async () => {
    const empty = await temporary();
    assert.deepEqual(await readDevelopmentBuilds(empty), []);
    await mkdir(path.join(empty, "fudgeapp"));
    assert.deepEqual(await readDevelopmentBuilds(empty), []);

    // `fudgeapp/development` a link to a folder with builds.
    const linkedFolder = await temporary();
    const real = await temporary();
    await install(real, "builds", "github", { name: "github", title: "GitHub" });
    await mkdir(path.join(linkedFolder, "fudgeapp"));
    await symlink(path.join(real, "builds"), path.join(linkedFolder, "fudgeapp", "development"));
    assert.deepEqual(await readDevelopmentBuilds(linkedFolder), []);

    // `fudgeapp` a link to a folder holding `development`.
    const linkedOwner = await temporary();
    await install(real, "owner/development", "github", { name: "github", title: "GitHub" });
    await symlink(path.join(real, "owner"), path.join(linkedOwner, "fudgeapp"));
    assert.deepEqual(await readDevelopmentBuilds(linkedOwner), []);
});

/** A store context that records what Uninstall asks and moves. */
function uninstallContext(extensionsDir: string, answer: boolean) {
    const asked: string[][] = [];
    const trashed: string[] = [];
    return {
        asked,
        trashed,
        context: {
            extensionsDir,
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

test("Uninstall on a development build's row moves only fudgeapp/development/<folder> to the Trash and writes no record", async () => {
    const extensions = await temporary();
    const support = await temporary();
    const installedJSON = `${JSON.stringify({ bar: { tree: "t", commit: "c", installedAt: "2026-11-22T00:00:00.000Z", dir: "bar" } })}\n`;
    await writeFile(path.join(support, "installed.json"), installedJSON);
    const foo = await install(extensions, development, "foo", { name: "bar", title: "Bar from foo" });
    const bar = await install(extensions, development, "bar", { name: "bar", title: "Bar" });
    const raycast = await install(extensions, "raycast/extensions", "bar", { name: "bar", title: "Bar" });
    const fooRow = (await readDevelopmentBuilds(extensions)).find((build) => build.name === "foo");
    assert.ok(fooRow);

    const cancelled = uninstallContext(extensions, false);
    assert.equal(await uninstallDevelopmentBuild(fooRow, cancelled.context), false);
    assert.deepEqual(cancelled.asked, [["Uninstall foo?", "It's moved to the Trash. Its settings and data stay.", "Uninstall"]]);
    assert.deepEqual(cancelled.trashed, []);

    const confirmed = uninstallContext(extensions, true);
    assert.equal(await uninstallDevelopmentBuild(fooRow, confirmed.context), true);
    assert.deepEqual(confirmed.trashed, [foo]);
    assert.equal(foo, developmentBuildFolder(extensions, "foo"));
    assert.deepEqual(
        (await readDevelopmentBuilds(extensions)).map((build) => build.name),
        ["bar"],
        "the build named in foo's manifest stays",
    );
    assert.ok(await readFile(path.join(bar, "package.json"), "utf8"));
    assert.ok(await readFile(path.join(raycast, "package.json"), "utf8"), "Raycast's install of that name stays");
    assert.equal(await readFile(path.join(support, "installed.json"), "utf8"), installedJSON, "no record read or written");

    // Already gone: nothing to move, and the row goes at the next read.
    const gone = uninstallContext(extensions, true);
    assert.equal(await uninstallDevelopmentBuild(fooRow, gone.context), true);
    assert.deepEqual(gone.trashed, []);
    // A name that isn't one never reaches the Trash.
    const bad: DevelopmentBuild = { name: "../raycast", title: "Bad", description: "" };
    const refused = uninstallContext(extensions, true);
    assert.equal(await uninstallDevelopmentBuild(bad, refused.context), false);
    assert.deepEqual(refused.asked, []);
    assert.deepEqual(refused.trashed, []);
});

test("rows built from an install alone wait for the first copy's rows, so the list opens on its first row", () => {
    // The installs are read before any copy, and rows read later don't move the selection.
    assert.equal(installOnlyRowsReady(0, 1), false, "the installs are read, no copy yet");
    assert.equal(installOnlyRowsReady(0, 2), false, "an open and a ⌘R, no copy yet");
    assert.equal(installOnlyRowsReady(12, 1), true, "the first copy's rows are in, others still reading");
    assert.equal(installOnlyRowsReady(0, 0), true, "reading ended with no copy's rows: every copy failed, or none is on");
    assert.equal(installOnlyRowsReady(12, 0), true, "after an install or an uninstall");
});

test("↵ on a row built from an install alone copies its name, and Uninstall comes after it", () => {
    assert.deepEqual(installOnlyRowActions, ["copyName", "uninstall"]);
});

test("development build rows show under All and Installed only, with a detail that says what they are", () => {
    assert.equal(developmentRowsShown(allFilter), true);
    assert.equal(developmentRowsShown(installedFilter), true);
    for (const filter of ["category:Productivity", "repository:raycast", "repository:0123456789abcdef", ""]) {
        assert.equal(developmentRowsShown(filter), false, filter);
    }
    assert.equal(
        developmentDetailMarkdown({ name: "my_tool", title: "My Tool", description: "Does things" }),
        "# My Tool\n\nDoes things\n\nA development build, in the development folder as `my_tool`.",
    );
    assert.equal(
        developmentDetailMarkdown({ name: "github", title: "github", description: "" }),
        "# github\n\nA development build, in the development folder as `github`.",
    );
});
