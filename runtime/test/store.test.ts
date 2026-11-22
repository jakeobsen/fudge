import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, writeFileSync } from "node:fs";
import { mkdir, mkdtemp, readdir, readFile, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import {
    accessoryTexts,
    allFilter,
    categories,
    distinctFolders,
    filterEntries,
    iconURL,
    installedFilter,
    isValidName,
    parseManifest,
    readCatalog,
    rowActions,
    searchKeywords,
    sections,
    status,
    type StoreEntry,
} from "../store-extension/src/catalog.ts";
import {
    installingFolder,
    parseProcessLine,
    readBuildRecords,
    removeBuildRecord,
    stillRunning,
    systemProbe,
    writeBuildRecord,
    type BuildRecord,
    type ProcessProbe,
    type ProcessState,
} from "../store-extension/src/build-records.ts";
import {
    heldRefresh,
    heldRefreshMessage,
    openCopy,
    OtherBuilds,
    pollInterval,
    settledToast,
    type Settled,
} from "../store-extension/src/other-builds.ts";
import {
    builtCompatibility,
    checkFolder,
    compatibilityFile,
    compatibilityTag,
    compatibilityLine,
    compatibilityText,
    CompatibilityChecks,
    fromReport,
    installNote,
    isNotCompatible,
    isPartlyCompatible,
    isRefusedWant,
    isScanned,
    maxCachedResults,
    maxScanBytes,
    maxScanFiles,
    maxSrcFiles,
    readCompatibility,
    rememberCompatibility,
    scannerIdentity,
    scanPatterns,
    writeCompatibility,
    type Compatibility,
    type ScanReport,
} from "../store-extension/src/compatibility.ts";
import { maxReadmeBytes, readRegularFile } from "../store-extension/src/files.ts";
import {
    gitAvailable,
    GitError,
    isValidBranch,
    cancelGrace,
    spawnProgram,
    stopRunningGit,
    storeEnvironment,
    StoreRepository,
    type GitResult,
    type Run,
} from "../store-extension/src/git.ts";
import {
    detailMarkdown,
    fetchReadme,
    filterImages,
    imageSource,
    isGitHubImage,
    readmeNotFetched,
    refetching,
    rendererPass,
    shownReadme,
} from "../store-extension/src/readme.ts";
import { RestingWork } from "../store-extension/src/resting.ts";
import {
    caseClash,
    lockfileProblem,
    packageJSONProblem,
    sourceProblem,
    specProblem,
} from "../store-extension/src/sources.ts";
import { isCommandName } from "../scripts/compat/source-files.ts";
import {
    AlreadyBuilding,
    alreadyBuildingStatus,
    buildArguments,
    bundledNames,
    doneToast,
    failureDetails,
    install,
    installPressed,
    InstallPresses,
    oneAtATime,
    readInstalled,
    StoreError,
    uninstall,
    writeInstalled,
    type InstallView,
    type StoreContext,
} from "../store-extension/src/store.ts";
import {
    askedForSwiftParts,
    chooseSwiftPartsMessage,
    installedWithoutSwift,
    leaveOutLine,
    swiftPartsActions,
    swiftPartsFile,
    swiftPartsMarkdown,
    swiftPartsMessage,
} from "../store-extension/src/swift-parts.ts";
import { chooseSwiftParts } from "../scripts/compile/swift.ts";
import { buildTimeout, swiftBuildTimeout } from "../store-extension/src/timeouts.ts";

const temporaries: string[] = [];
async function temporary(): Promise<string> {
    const folder = await mkdtemp(path.join(tmpdir(), "fudge-store-"));
    temporaries.push(folder);
    return folder;
}
after(async () => {
    for (const folder of temporaries) await rm(folder, { recursive: true, force: true });
});

const manifest = (name: string, extra: Record<string, unknown> = {}) => ({
    name,
    title: name.replace(/^./, (c) => c.toUpperCase()),
    description: `The ${name} extension`,
    author: "someone",
    icon: "icon.png",
    categories: ["Productivity"],
    keywords: ["word"],
    license: "MIT",
    commands: [{ name: "run", title: "Run", description: "Runs it", mode: "view" }],
    ...extra,
});

async function writeJSON(file: string, value: unknown): Promise<void> {
    await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, JSON.stringify(value));
}

// MARK: - Names and the catalog

test("the name rule is the app's: one fixture pins both", async () => {
    const names = JSON.parse(await readFile(new URL("./fixtures/extension-names.json", import.meta.url), "utf8")) as {
        valid: string[];
        invalid: string[];
    };
    assert.ok(names.valid.length > 0 && names.invalid.length > 0);
    for (const name of names.valid) assert.ok(isValidName(name), name);
    for (const name of names.invalid) assert.ok(!isValidName(name), name);
});

test("the command name rule is the app's: one fixture pins both, for the scan and the store alike", async () => {
    const names = JSON.parse(await readFile(new URL("./fixtures/command-names.json", import.meta.url), "utf8")) as {
        valid: string[];
        invalid: string[];
    };
    assert.ok(names.valid.length > 0 && names.invalid.length > 0);
    for (const name of names.valid) assert.ok(isCommandName(name), name);
    for (const name of names.invalid) assert.ok(!isCommandName(name), JSON.stringify(name));
    assert.ok(!isCommandName(1) && !isCommandName(null));
});

test("a manifest's name and its folder each pass their own rule, and may differ", () => {
    assert.equal(parseManifest("alpha", manifest("alpha"))?.name, "alpha");
    const aws = parseManifest("amazon-aws", manifest("aws"))!;
    assert.deepEqual([aws.name, aws.dir], ["aws", "amazon-aws"], "amazon-aws holds aws");
    for (const folder of ["CodeBlocks", "http.cat", "notion_researcher", "Bilibili", "transfer-sh_upload", "8ball"]) {
        assert.equal(parseManifest(folder, manifest("fine"))?.dir, folder, `folder ${folder}`);
    }
    for (const bad of ["..", ".", ".hidden", "a/b", "", "-alpha", "_alpha", "al pha", "al*pha", "al?pha", "a\\b", "[a]"]) {
        assert.equal(parseManifest(bad, manifest("fine")), undefined, `folder ${JSON.stringify(bad)}`);
    }
    for (const bad of ["Alpha", "-alpha", "_alpha", "al pha", "../alpha", "alpha/x", "al*pha", "", ".alpha", "a.b"]) {
        assert.equal(parseManifest("fine", manifest(bad)), undefined, `name ${JSON.stringify(bad)}`);
    }
    for (const name of ["notion_researcher", "solana_nodes", "liba-ro_shortener"]) {
        assert.equal(parseManifest(name, manifest(name))?.name, name, `${name} installs, as Raycast's rule allows _`);
    }
    assert.equal(parseManifest("alpha", manifest("alpha", { commands: [] })), undefined, "no commands");
    assert.equal(parseManifest("alpha", { ...manifest("alpha"), title: 5 }), undefined, "no title");
    assert.equal(parseManifest("alpha", null), undefined);
});

test("an entry has the manifest's fields, and only a plain icon file name", () => {
    const entry = parseManifest("alpha", manifest("alpha"))!;
    assert.deepEqual(entry, {
        name: "alpha",
        dir: "alpha",
        title: "Alpha",
        description: "The alpha extension",
        author: "someone",
        icon: "icon.png",
        keywords: ["word"],
        categories: ["Productivity"],
        license: "MIT",
        commands: [{ name: "run", title: "Run", description: "Runs it", mode: "view" }],
    });
    assert.equal(parseManifest("alpha", manifest("alpha", { icon: "../../x.png" }))?.icon, undefined);
    assert.equal(parseManifest("alpha", manifest("alpha", { icon: ".hidden" }))?.icon, undefined);
    assert.equal(
        iconURL(entry, "abc123"),
        "https://raw.githubusercontent.com/raycast/extensions/abc123/extensions/alpha/assets/icon.png",
    );
});

test("the catalog reads valid manifests only, sorted by title", async () => {
    const repo = await temporary();
    await writeJSON(path.join(repo, "extensions/zeta/package.json"), manifest("zeta"));
    await writeJSON(path.join(repo, "extensions/alpha/package.json"), manifest("alpha"));
    await writeJSON(path.join(repo, "extensions/amazon-aws/package.json"), manifest("aws", { title: "Amazon AWS" }));
    await writeJSON(path.join(repo, "extensions/http.cat/package.json"), manifest("http-cat", { title: "HTTP Cat" }));
    await writeJSON(path.join(repo, "extensions/Upper/package.json"), manifest("Upper"));
    await writeJSON(path.join(repo, "extensions/.hidden/package.json"), manifest("hidden"));
    await writeJSON(path.join(repo, "extensions/empty/package.json"), manifest("empty", { commands: [] }));
    await mkdir(path.join(repo, "extensions/no-manifest"), { recursive: true });
    await writeFile(path.join(repo, "extensions/broken-json"), "");
    await mkdir(path.join(repo, "extensions/broken"), { recursive: true });
    await writeFile(path.join(repo, "extensions/broken/package.json"), "{ not json");
    const entries = await readCatalog(repo);
    assert.deepEqual(
        entries.map((entry) => [entry.name, entry.dir]),
        [
            ["alpha", "alpha"],
            ["aws", "amazon-aws"],
            ["http-cat", "http.cat"],
            ["zeta", "zeta"],
        ],
        "by title; Upper's name isn't valid, and .hidden isn't a folder the store reads",
    );
    assert.deepEqual(await readCatalog(path.join(repo, "missing")), []);
});

test("folders that differ only by case are one folder, as on APFS", () => {
    assert.deepEqual(distinctFolders(["dup", "Zeta", "Dup", "alpha", "DUP"]), ["DUP", "Zeta", "alpha"]);
});

// MARK: - Rows

const alpha = parseManifest("alpha", manifest("alpha", { categories: ["Productivity", "Developer Tools"] }))!;
const beta = parseManifest("beta", manifest("beta", { author: "", commands: [{ name: "a", title: "A" }, { name: "b", title: "B" }] }))!;
const gamma = parseManifest("gamma", manifest("gamma", { categories: ["Media"] }))!;
const record = (tree: string, dir: string) => ({ tree, commit: "c1", installedAt: "2026-11-20T00:00:00.000Z", dir });

test("installed and update come from installed.json and the folder's tree id", () => {
    const trees = new Map([
        ["alpha", "t1"],
        ["beta", "t2-new"],
    ]);
    const installed = { alpha: record("t1", "alpha"), beta: record("t2", "beta") };
    assert.equal(status(alpha, installed, trees), "installed");
    assert.equal(status(beta, installed, trees), "update");
    assert.equal(status(gamma, installed, trees), "available");
});

test("two folders with one name: only the folder it was installed from is installed, and its tree is compared", () => {
    const first = parseManifest("world-clock", manifest("world-clock"))!;
    const second = parseManifest("world-clock-2", manifest("world-clock"))!;
    const installed = { "world-clock": record("t1", "world-clock") };
    const trees = new Map([
        ["world-clock", "t1"],
        ["world-clock-2", "t9"],
    ]);
    assert.equal(status(first, installed, trees), "installed");
    assert.equal(status(second, installed, trees), "available", "the other folder's newer tree isn't an update");
    assert.equal(status(first, installed, new Map([["world-clock", "t2"]])), "update");
    assert.equal(status(parseManifest("World-Clock", manifest("world-clock"))!, installed, trees), "installed", "APFS ignores case");
    assert.deepEqual(filterEntries([first, second], installedFilter, installed), [first]);
    assert.deepEqual(sections([first, second], installed).other, [second]);
});

test("rows show the author, the commands and the state; search includes keywords, author and name", () => {
    assert.deepEqual(accessoryTexts(alpha, "installed"), [{ text: "someone" }, { text: "1 command" }, { tag: "Installed" }]);
    assert.deepEqual(accessoryTexts(beta, "update"), [{ text: "2 commands" }, { tag: "Update available" }]);
    assert.deepEqual(accessoryTexts(gamma, "available"), [{ text: "someone" }, { text: "1 command" }]);
    assert.deepEqual(searchKeywords(alpha), ["word", "someone", "alpha"]);
    assert.deepEqual(searchKeywords(beta), ["word", "beta"]);
    assert.deepEqual(searchKeywords(parseManifest("amazon-aws", manifest("aws"))!), ["word", "someone", "aws", "amazon-aws"]);
});

test("the category and Installed filters, and installed ones first", () => {
    const entries: StoreEntry[] = [gamma, beta, alpha];
    const installed = { gamma: record("t", "gamma") };
    assert.deepEqual(categories(entries), ["Developer Tools", "Media", "Productivity"]);
    assert.deepEqual(filterEntries(entries, allFilter, installed), entries);
    assert.deepEqual(filterEntries(entries, installedFilter, installed), [gamma]);
    assert.deepEqual(
        filterEntries(entries, "category:Productivity", installed).map((entry) => entry.name),
        ["beta", "alpha"],
    );
    const split = sections(entries, installed);
    assert.deepEqual(
        split.installed.map((entry) => entry.name),
        ["gamma"],
    );
    assert.deepEqual(
        split.other.map((entry) => entry.name),
        ["alpha", "beta"],
    );
});

// MARK: - Package sources

test("registry versions are accepted: ranges, dist-tags and npm aliases", () => {
    for (const spec of ["^1.2.3", "~1.2", ">=1 <2", "1.x", "*", "", "1.0.0-beta.1", "1.2.3 - 2.0.0", "^1 || ^2"]) {
        assert.equal(specProblem("x", spec), undefined, spec);
    }
    for (const spec of ["latest", "next", "beta"]) assert.equal(specProblem("x", spec), undefined, spec);
    for (const spec of ["npm:react@^18", "npm:@scope/pkg@1.0.0", "npm:other", "npm:other@latest"]) {
        assert.equal(specProblem("x", spec), undefined, spec);
    }
});

test("every other source is refused", () => {
    const refused = [
        "git+https://github.com/a/b.git",
        "git://github.com/a/b",
        "git+ssh://git@github.com/a/b.git",
        "github:a/b",
        "gitlab:a/b",
        "a/b",
        "a/b#v1",
        "https://example.com/x.tgz",
        "http://example.com/x.tgz",
        "file:../x",
        "link:../x",
        "workspace:*",
        "./local",
        "../local",
        "~/local",
        "npm:x@github:a/b",
        "npm:x@file:../y",
    ];
    for (const spec of refused) assert.ok(specProblem("x", spec), spec);
    assert.ok(specProblem("x", 5));
});

test("package.json: every dependency section and overrides", () => {
    assert.equal(packageJSONProblem({ dependencies: { a: "^1" }, devDependencies: { b: "latest" } }), undefined);
    assert.match(packageJSONProblem({ devDependencies: { b: "github:a/b" } })!, /b comes from "github:a\/b"/);
    assert.ok(packageJSONProblem({ optionalDependencies: { c: "file:../c" } }));
    assert.ok(packageJSONProblem({ peerDependencies: { d: "a/b" } }));
    assert.ok(packageJSONProblem({ overrides: { e: "https://example.com/e.tgz" } }));
    assert.ok(packageJSONProblem({ overrides: { f: { g: "git+https://example.com/g.git" } } }));
    assert.equal(packageJSONProblem({ dependencies: { h: "^1" }, overrides: { h: "$h", i: { j: "1.0.0" } } }), undefined);
    assert.ok(packageJSONProblem([]) === undefined || packageJSONProblem("x"));
    assert.ok(packageJSONProblem(null));
});

const registryURL = (name: string) => `https://registry.npmjs.org/${name}/-/${name}-1.0.0.tgz`;

test("lockfiles v2/v3 list packages: resolved off the registry, link and file versions are refused", () => {
    const clean = {
        lockfileVersion: 3,
        packages: { "": { name: "ext" }, "node_modules/a": { version: "1.0.0", resolved: registryURL("a") } },
    };
    assert.equal(lockfileProblem(clean), undefined);
    const tarball = structuredClone(clean) as { packages: Record<string, unknown> };
    tarball.packages["node_modules/b"] = { version: "1.0.0", resolved: "https://example.com/b.tgz" };
    assert.match(lockfileProblem(tarball)!, /node_modules\/b is downloaded from https:\/\/example\.com\/b\.tgz/);
    const git = structuredClone(clean) as { packages: Record<string, unknown> };
    git.packages["node_modules/c"] = { version: "1.0.0", resolved: "git+ssh://git@github.com/a/c.git#abc" };
    assert.ok(lockfileProblem(git));
    const linked = structuredClone(clean) as { packages: Record<string, unknown> };
    linked.packages["node_modules/d"] = { resolved: "../d", link: true };
    assert.match(lockfileProblem(linked)!, /linked from a local folder/);
    const linkOnly = structuredClone(clean) as { packages: Record<string, unknown> };
    linkOnly.packages["node_modules/e"] = { link: true };
    assert.ok(lockfileProblem(linkOnly), "link: true without resolved");
    const file = structuredClone(clean) as { packages: Record<string, unknown> };
    file.packages["node_modules/f"] = { version: "file:../f" };
    assert.ok(lockfileProblem(file));
});

test("a lockfile entry's own dependencies must be registry versions, in both lockfile shapes", () => {
    const pulls = {
        tarball: ["https://example.com/x.tgz", /x comes from "https:\/\/example\.com\/x\.tgz"/],
        git: ["git+https://github.com/a/x.git#abc", /x comes from "git\+https:/],
        file: ["file:../x", /x comes from "file:\.\.\/x"/],
    } as const;
    for (const [kind, [spec, message]] of Object.entries(pulls)) {
        for (const section of ["dependencies", "optionalDependencies", "peerDependencies", "devDependencies"]) {
            const v3 = {
                lockfileVersion: 3,
                packages: {
                    "": { name: "ext", dependencies: { a: "^1.0.0" } },
                    "node_modules/a": { version: "1.0.0", resolved: registryURL("a"), [section]: { x: spec } },
                },
            };
            const problem = lockfileProblem(v3);
            assert.match(problem ?? "", message, `v3 ${section}, ${kind}`);
            assert.match(problem ?? "", /^node_modules\/a: /, "names the entry");
        }
        const v1 = {
            lockfileVersion: 1,
            dependencies: { a: { version: "1.0.0", resolved: registryURL("a"), requires: { x: spec } } },
        };
        assert.match(lockfileProblem(v1) ?? "", message, `v1 requires, ${kind}`);
        const v1Nested = {
            lockfileVersion: 1,
            dependencies: { a: { version: "1.0.0", resolved: registryURL("a"), dependencies: { x: spec } } },
        };
        assert.match(lockfileProblem(v1Nested) ?? "", message, `v1 dependencies as a spec, ${kind}`);
    }
    const fine = {
        lockfileVersion: 3,
        packages: {
            "node_modules/a": {
                version: "1.0.0",
                resolved: registryURL("a"),
                dependencies: { b: "^2.0.0", c: "npm:real@^1", d: "latest" },
                peerDependencies: { react: "*" },
            },
        },
    };
    assert.equal(lockfileProblem(fine), undefined, "ranges, npm aliases and dist-tags are registry versions");
});

test("lockfile v1 nests dependencies, walked recursively; npm aliases are fine", () => {
    const v1 = {
        lockfileVersion: 1,
        dependencies: {
            a: {
                version: "1.0.0",
                resolved: registryURL("a"),
                dependencies: { b: { version: "1.0.0", resolved: registryURL("b") } },
            },
            alias: { version: "npm:real@1.0.0", resolved: registryURL("real") },
        },
    };
    assert.equal(lockfileProblem(v1), undefined);
    const deep = structuredClone(v1);
    (deep.dependencies.a.dependencies.b as Record<string, unknown>).resolved = "https://evil.example/b.tgz";
    assert.match(lockfileProblem(deep)!, /b is downloaded from https:\/\/evil\.example/);
    const file = structuredClone(v1) as { dependencies: Record<string, unknown> };
    file.dependencies.c = { version: "file:../c" };
    assert.ok(lockfileProblem(file));
    const git = structuredClone(v1) as { dependencies: Record<string, unknown> };
    git.dependencies.d = { version: "github:a/d#abc", from: "github:a/d" };
    assert.ok(lockfileProblem(git));
    assert.ok(lockfileProblem("nope"));
});

test("an extension folder: an .npmrc anywhere, package.json and the lockfiles", async () => {
    const folder = await temporary();
    await writeJSON(path.join(folder, "package.json"), { dependencies: { a: "^1" } });
    await writeJSON(path.join(folder, "package-lock.json"), {
        lockfileVersion: 3,
        packages: { "node_modules/a": { resolved: registryURL("a") } },
    });
    await writeFile(path.join(folder, "README.md"), "hi");
    assert.equal(await sourceProblem(folder), undefined);

    await mkdir(path.join(folder, "src/nested"), { recursive: true });
    await writeFile(path.join(folder, "src/nested/.npmrc"), "registry=https://evil.example/");
    assert.match((await sourceProblem(folder))!, /\.npmrc \(src\/nested\/\.npmrc\)/);
    await rm(path.join(folder, "src/nested/.npmrc"));

    await writeJSON(path.join(folder, "npm-shrinkwrap.json"), {
        lockfileVersion: 3,
        packages: { "node_modules/b": { resolved: "https://evil.example/b.tgz" } },
    });
    assert.match((await sourceProblem(folder))!, /^npm-shrinkwrap\.json: /);
    await rm(path.join(folder, "npm-shrinkwrap.json"));

    await writeJSON(path.join(folder, "package.json"), { dependencies: { a: "user/repo" } });
    assert.match((await sourceProblem(folder))!, /a comes from "user\/repo"/);
});

test("file names are compared ignoring case, as APFS and the build do", async () => {
    const folder = await temporary();
    await writeJSON(path.join(folder, "package.json"), { dependencies: { a: "^1" } });
    await writeFile(path.join(folder, ".NPMRC"), "registry=https://evil.example/");
    assert.match((await sourceProblem(folder))!, /\.npmrc \(\.NPMRC\)/);
    await rm(path.join(folder, ".NPMRC"));

    await writeJSON(path.join(folder, "Package-Lock.json"), {
        lockfileVersion: 3,
        packages: { "node_modules/a": { resolved: "https://evil.example/a.tgz" } },
    });
    assert.match((await sourceProblem(folder))!, /^Package-Lock\.json: node_modules\/a is downloaded from/);

    assert.deepEqual(caseClash(["src/a.ts", "SRC/a.ts", "b.ts"]), ["src/a.ts", "SRC/a.ts"]);
    assert.deepEqual(caseClash([".npmrc", ".NPMRC"]), [".npmrc", ".NPMRC"]);
    assert.equal(caseClash(["a.ts", "b.ts", "src/a.ts"]), undefined);
});

test("tarball specs and lockfile versions that are paths or user/repo are refused", () => {
    for (const spec of ["evil.tgz", "evil.tar.gz", "pkg.TAR", "./x.tgz"]) assert.ok(specProblem("x", spec), spec);
    for (const version of ["user/repo", "/abs/x.tgz", "evil.tgz", "../x"]) {
        assert.ok(lockfileProblem({ lockfileVersion: 1, dependencies: { x: { version } } }), version);
        assert.ok(lockfileProblem({ lockfileVersion: 3, packages: { "node_modules/x": { version } } }), version);
    }
    const scopedAlias = { version: "npm:@scope/real@1.0.0", resolved: registryURL("real") };
    assert.equal(lockfileProblem({ lockfileVersion: 1, dependencies: { x: scopedAlias } }), undefined);
});

// MARK: - README images

test("only images on GitHub's hosts are shown", () => {
    for (const url of [
        "https://github.com/a/b/raw/main/x.png",
        "https://raw.githubusercontent.com/a/b/main/x.png",
        "https://user-images.githubusercontent.com/1/x.png",
        "https://private-user-images.githubusercontent.com/1/x.png",
        "https://avatars.githubusercontent.com/u/1",
    ]) {
        assert.ok(isGitHubImage(url), url);
    }
    for (const url of [
        "http://raw.githubusercontent.com/x.png",
        "https://example.com/x.png",
        "https://githubusercontent.com.evil.example/x.png",
        "https://evil.example/github.com/x.png",
        "https://user:pass@github.com/x.png",
        "https://github.com:8443/x.png",
        "data:image/png;base64,AAAA",
        "not a url",
    ]) {
        assert.equal(isGitHubImage(url), false, url);
    }
});

test("other images become their alt text; paths in the folder become GitHub's raw files", () => {
    const readme = [
        "![Shot](media/shot.png)",
        '![Hosted](https://raw.githubusercontent.com/a/b/main/x.png "A title")',
        "![Tracker](https://evil.example/pixel.gif)",
        "![Up](../../secret.png)",
        "![Ref][logo] and ![Bad][bad]",
        '<img src="https://evil.example/x.png" alt="HTML image" width="200">',
        "<img alt='Kept' src='./media/kept.png'>",
        "",
        "[logo]: https://user-images.githubusercontent.com/1/logo.png",
        "[bad]: https://evil.example/bad.png",
    ].join("\n");
    const raw = "https://raw.githubusercontent.com/raycast/extensions/c0ffee/extensions/alpha";
    assert.equal(
        filterImages(readme, "alpha", "c0ffee"),
        [
            `![Shot](${raw}/media/shot.png)`,
            '![Hosted](https://raw.githubusercontent.com/a/b/main/x.png "A title")',
            "Tracker",
            "Up",
            "![Ref](https://user-images.githubusercontent.com/1/logo.png) and Bad",
            "HTML image",
            `![Kept](${raw}/media/kept.png)`,
            "",
            "[logo]: https://user-images.githubusercontent.com/1/logo.png",
            "[bad]: https://evil.example/bad.png",
        ].join("\n"),
    );
});

test("a source the renderer would read differently is never shown", () => {
    for (const source of ["a b", "x)", "<x", "x>", "media/a.png\n![y](https://evil.example/p.png", ""]) {
        assert.equal(imageSource(source, "alpha", "c0ffee"), undefined, JSON.stringify(source));
    }
    const vector = "![a](<x)\n![y](https://evil.example/two.png>)";
    const filtered = filterImages(vector, "alpha", "c0ffee");
    assert.ok(!filtered.includes("evil.example/two.png)"), filtered);
    assert.ok(!/!\[[^\]]*\]\(https:\/\/evil/.test(filtered), filtered);
});

test("the last pass uses the renderer's rule: an image line off GitHub becomes its alt text", () => {
    assert.equal(rendererPass("![t](https://evil.example/p.png)"), "t");
    assert.equal(rendererPass('  ![t](<https://evil.example/p.png> "title")  '), "t");
    const kept = "![t](https://raw.githubusercontent.com/a/b/c/x.png)";
    assert.equal(rendererPass(`intro\n${kept}\nend`), `intro\n${kept}\nend`);
});

test("everything in the detail goes through the filter, the manifest's text included", () => {
    const evil = "![p](https://evil.example/p.png)";
    const entry = parseManifest(
        "alpha",
        manifest("alpha", {
            description: `Nice ${evil}`,
            author: evil,
            commands: [{ name: "run", title: "Run", description: evil }],
        }),
    )!;
    const detail = detailMarkdown(entry, "c0ffee", `# Readme\n\n${evil}\n\n![shot](media/shot.png)`);
    assert.ok(!detail.includes("evil.example"), detail);
    assert.match(detail, /^# Alpha/);
    assert.ok(detail.includes("raw.githubusercontent.com/raycast/extensions/c0ffee/extensions/alpha/media/shot.png"));
    assert.match(detailMarkdown(entry, "c0ffee", undefined), /Loading the README/);
    assert.match(detailMarkdown(entry, "c0ffee", readmeNotFetched), /couldn't fetch the README\. ⌘R tries again/);
    const none = detailMarkdown(entry, "c0ffee", "");
    assert.ok(!/README|---/.test(none), `a folder with no README shows the manifest alone: ${none}`);
});

test("the detail's Compatibility line comes first among the facts", () => {
    const entry = parseManifest("alpha", manifest("alpha"))!;
    const markdown = detailMarkdown(entry, "c0ffee", "", "Not compatible: Raycast AI. Missing: `Clipboard.read`");
    assert.match(markdown, /\n\n\*\*Compatibility:\*\* Not compatible: Raycast AI\. Missing: `Clipboard\.read`  \n\*\*Author:\*\* someone/);
    assert.doesNotMatch(detailMarkdown(entry, "c0ffee", ""), /Compatibility/, "no line without a state");
});

test("the detail names the repository folder when it differs from the name, and links to the folder", () => {
    const aws = parseManifest("amazon-aws", manifest("aws", { title: "Amazon AWS" }))!;
    const detail = detailMarkdown(aws, "abc123", "");
    assert.ok(detail.includes("In the repository as `amazon-aws`"), detail);
    assert.ok(detail.includes("https://github.com/raycast/extensions/tree/abc123/extensions/amazon-aws"), detail);
    assert.ok(!detailMarkdown(alpha, "abc123", "").includes("In the repository as"), "not when they're the same");
});

test("the detail lists each command with its mode", () => {
    const entry = parseManifest(
        "alpha",
        manifest("alpha", {
            commands: [
                { name: "search", title: "Search Issues", description: "Find issues", mode: "view" },
                { name: "create", title: "Create Issue", mode: "no-view" },
                { name: "menu", title: "My Issues", description: "In the menu bar", mode: "menu-bar" },
                { name: "odd", title: "Odd", mode: "something-else" },
                { name: "none", title: "No Mode" },
            ],
        }),
    )!;
    const commands = detailMarkdown(entry, "c0ffee", undefined).split("## Commands\n\n")[1]!.split("\n\n")[0];
    assert.equal(
        commands,
        [
            "- **Search Issues** (view): Find issues",
            "- **Create Issue** (no-view)",
            "- **My Issues** (menu bar): In the menu bar",
            "- **Odd**",
            "- **No Mode**",
        ].join("\n"),
    );
});

test("every git operation of the store's waits its turn", async () => {
    const order: string[] = [];
    const slow = oneAtATime(async () => {
        order.push("refresh starts");
        await new Promise((resolve) => setTimeout(resolve, 50));
        order.push("refresh ends");
    });
    const next = oneAtATime(async () => {
        order.push("install starts");
    });
    const failing = oneAtATime(async () => {
        throw new Error("boom");
    });
    const after = oneAtATime(async () => {
        order.push("readme starts");
    });
    await Promise.all([slow, next, failing.catch(() => undefined), after]);
    assert.deepEqual(order, ["refresh starts", "refresh ends", "install starts", "readme starts"]);
});

// MARK: - Git

/** A fake runner: records each call and answers from `reply`. */
function fakeRun(reply: (program: string, args: string[]) => Partial<GitResult> = () => ({})) {
    const calls: {
        program: string;
        args: string[];
        cwd?: string;
        timeout: number;
        stoppable?: boolean;
        input?: string;
        env?: NodeJS.ProcessEnv;
    }[] = [];
    const run: Run = async (program, args, options) => {
        calls.push({ program, args, ...options });
        return { code: 0, stdout: "", stderr: "", ...reply(program, args) };
    };
    return { run, calls };
}

test("the exact git calls: clone, refresh keeping only what it reaches, add, commit and trees", async () => {
    const support = await temporary();
    const repoPath = path.join(support, "repo");
    const { run, calls } = fakeRun((_program, args) => {
        if (args[0] === "clone") return {};
        if (args[0] === "symbolic-ref") return { stdout: "origin/main\n" };
        if (args[0] === "for-each-ref")
            return { stdout: "refs/heads/main\nrefs/remotes/origin/HEAD\nrefs/remotes/origin/main\nrefs/tags/v1\n" };
        if (args[0] === "ls-tree")
            return { stdout: "040000 tree aaa\textensions/alpha\n040000 tree bbb\textensions/beta\n100644 blob ccc\textensions/README.md\n" };
        if (args[0] === "rev-parse") return { stdout: "c0ffee\n" };
        if (args[0] === "rev-list") return { stdout: "1111111111111111111111111111111111111111\n" };
        if (args[0] === "pack-objects") return { stdout: "2222222222222222222222222222222222222222\n" };
        return {};
    });
    const repo = new StoreRepository(repoPath, { run, url: "https://example.invalid/repo.git" });
    const packs = path.join(repoPath, ".git/objects/pack");
    await mkdir(packs, { recursive: true });
    for (const file of ["pack-aaaa.pack", "pack-aaaa.idx", "pack-aaaa.promisor", "pack-bbbb.pack", "pack-bbbb.idx"]) {
        await writeFile(path.join(packs, file), "");
    }
    await repo.clone();
    await repo.refresh();
    await repo.add("/extensions/alpha/");
    assert.equal(await repo.commit(), "c0ffee");
    assert.deepEqual(
        [...(await repo.trees())],
        [
            ["alpha", "aaa"],
            ["beta", "bbb"],
        ],
    );
    assert.deepEqual(
        calls.map((call) => call.args),
        [
            ["clone", "--depth", "1", "--filter=blob:none", "--sparse", "--no-checkout", "https://example.invalid/repo.git", repoPath],
            ["sparse-checkout", "set", "--no-cone", "/extensions/*/package.json"],
            ["checkout"],
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            ["fetch", "--depth", "1", "--filter=blob:none", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main"],
            ["checkout", "--quiet", "-B", "main", "refs/remotes/origin/main", "--"],
            ["for-each-ref", "--format=%(refname)"],
            ["update-ref", "--no-deref", "-d", "refs/tags/v1"],
            ["reflog", "expire", "--expire=now", "--all"],
            ["rev-list", "--objects", "--no-object-names", "--all", "--missing=allow-promisor"],
            ["pack-objects", "--quiet", path.join(packs, "pack")],
            ["prune", "--expire=now", "--exclude-promisor-objects"],
            ["sparse-checkout", "add", "/extensions/alpha/"],
            ["rev-parse", "HEAD"],
            ["ls-tree", "HEAD", "extensions/"],
        ],
    );
    assert.equal(
        calls.find((call) => call.args[0] === "pack-objects")?.input,
        "1111111111111111111111111111111111111111\n",
        "pack-objects gets what rev-list found",
    );
    assert.deepEqual(
        (await readdir(packs)).sort(),
        ["pack-2222222222222222222222222222222222222222.promisor"],
        "the old packs are gone, and the new one is the remote's",
    );
    assert.ok(calls.every((call) => call.program === "/usr/bin/git"));
    assert.equal(calls[0]!.cwd, support, "the clone runs beside the repo folder");
    assert.deepEqual(
        calls.map((call) => call.timeout),
        // Downloads, checkouts that fetch files, and gc get the long timeout; local commands the short one.
        [120_000, 30_000, 120_000, 30_000, 120_000, 120_000, 30_000, 30_000, 30_000, 120_000, 120_000, 120_000, 120_000, 30_000, 30_000],
    );
    assert.ok(!(await repo.needsRefresh(new Date())), "just refreshed");
    assert.ok(await repo.needsRefresh(new Date(Date.now() + 25 * 60 * 60 * 1000)), "a day later");
});

test("git ignores the user's own configuration and never prompts", () => {
    const environment = storeEnvironment({ HOME: "/Users/someone", PATH: "/usr/bin", GIT_CONFIG_GLOBAL: "/Users/someone/.gitconfig" });
    assert.equal(environment.GIT_TERMINAL_PROMPT, "0");
    assert.equal(environment.GIT_CONFIG_NOSYSTEM, "1");
    assert.equal(environment.GIT_CONFIG_GLOBAL, "/dev/null", "an insteadOf rule can't redirect the clone");
    assert.equal(environment.HOME, "/Users/someone");
    assert.equal(environment.PATH, "/usr/bin");
});

test("unloading the store stops its running git, and only that", async () => {
    const started = Date.now();
    const git = spawnProgram("/bin/sleep", ["5"], { timeout: 30_000, stoppable: true });
    const other = spawnProgram("/bin/sleep", ["0.2"], { timeout: 30_000 });
    stopRunningGit();
    const result = await git;
    assert.notEqual(result.code, 0);
    assert.ok(Date.now() - started < 4000, "stopped, not run to the end");
    assert.match(result.stderr, /\nsleep stopped \(SIGTERM\)$/, "stopped, but not said to have timed out");
    assert.equal((await other).code, 0, "the CLI's build isn't stoppable");
});

test("a timeout says so whatever the exit, as when fudge catches SIGTERM and exits 143", async () => {
    // Like fudge: it catches SIGTERM, ends what it started, and exits with 128 + 15.
    const fudgeLike = 'trap "exit 143" TERM; while :; do sleep 0.05; done';
    const result = await spawnProgram("/bin/sh", ["-c", fudgeLike], { timeout: 1000 });
    assert.equal(result.code, 143);
    assert.match(result.stderr, /\nsh stopped after 1 s$/);
    const failed = await spawnProgram("/bin/sh", ["-c", "echo nope >&2; exit 3"], { timeout: 30_000 });
    assert.equal(failed.code, 3);
    assert.equal(failed.stderr, "nope\n", "a program that fails by itself gets no note");
});

test("every git call of the repository is stoppable, and a copy can be removed", async () => {
    const root = await temporary();
    const { run, calls } = fakeRun();
    const repo = new StoreRepository(path.join(root, "repo"), { run });
    await repo.commit().catch(() => undefined);
    assert.ok(calls.every((call) => (call as { stoppable?: boolean }).stoppable === true));
    await mkdir(path.join(root, "repo/.git"), { recursive: true });
    assert.ok(await repo.exists());
    await repo.remove();
    assert.equal(await repo.exists(), false);
});

test("a failing git call surfaces its stderr", async () => {
    const { run } = fakeRun(() => ({ code: 128, stderr: "fatal: unable to access\n" }));
    const repo = new StoreRepository(await temporary(), { run });
    await assert.rejects(repo.commit(), /fatal: unable to access/);
});

test("without the Command Line Tools, git itself is never run", async () => {
    const missing = fakeRun((program) => (program.endsWith("xcode-select") ? { code: 2 } : {}));
    assert.equal(await gitAvailable(missing.run), false);
    assert.deepEqual(
        missing.calls.map((call) => call.program),
        ["/usr/bin/xcode-select"],
    );
    // A developer folder `xcode-select -p` still names, whose tools are gone: `/usr/bin/git` would offer the
    // installer, so it isn't run either.
    const developer = await temporary();
    const naming = (folder: string) => (program: string) => (program.endsWith("xcode-select") ? { stdout: `${folder}\n` } : {});
    for (const [why, folder] of [
        ["a folder without git", developer],
        ["a folder that isn't there", path.join(developer, "gone")],
        ["no folder", ""],
        ["a relative path", "Developer"],
    ] as const) {
        const emptied = fakeRun(naming(folder));
        assert.equal(await gitAvailable(emptied.run), false, why);
        assert.deepEqual(emptied.calls.map((call) => call.program), ["/usr/bin/xcode-select"], `${why}: git isn't run`);
    }
    await mkdir(path.join(developer, "usr/bin/git"), { recursive: true });
    const aFolder = fakeRun(naming(developer));
    assert.equal(await gitAvailable(aFolder.run), false, "usr/bin/git must be a file");
    assert.deepEqual(aFolder.calls.map((call) => call.program), ["/usr/bin/xcode-select"]);

    const tools = await temporary();
    await mkdir(path.join(tools, "usr/bin"), { recursive: true });
    await writeFile(path.join(tools, "usr/bin/git"), "");
    const present = fakeRun(naming(tools));
    assert.equal(await gitAvailable(present.run), true);
    assert.deepEqual(
        present.calls.map((call) => [call.program, ...call.args]),
        [
            ["/usr/bin/xcode-select", "-p"],
            ["/usr/bin/git", "--version"],
        ],
    );
    const broken = fakeRun((program) =>
        program.endsWith("git") ? { code: 1, stderr: "xcrun: error: invalid active developer path" } : naming(tools)(program),
    );
    assert.equal(await gitAvailable(broken.run), false);
    assert.equal(broken.calls.length, 2, "git ran, and said it can't");
});

// MARK: - Install, update and uninstall

const supportedScan = { extension: "alpha", supported: true, gaps: [], unreadable: [] };

async function storeContext(
    options: {
        confirm?: boolean;
        cliCode?: number;
        tree?: string;
        scan?: { code?: number; stdout?: string };
        /** More folders in the repository: each with its manifest's name and its tree id. */
        folders?: { dir: string; name: string; tree: string }[];
        /** The files under each folder's `src/`, as `ls-tree -r` lists them, by folder. */
        sources?: Record<string, string[]>;
        /** What the build writes as the install's `compatibility.json`; nothing when its own scan failed. */
        built?: unknown;
        /** Answers a build itself, by its arguments, instead of `cliCode`. */
        build?: (args: string[]) => { code: number; stderr?: string };
    } = {},
) {
    const root = await temporary();
    const supportPath = path.join(root, "support");
    const extensionsDir = path.join(root, "extensions");
    const repoPath = path.join(supportPath, "repo");
    await mkdir(extensionsDir, { recursive: true });
    await writeJSON(path.join(repoPath, "extensions/alpha/package.json"), manifest("alpha", { dependencies: { a: "^1" } }));
    for (const folder of options.folders ?? []) {
        await writeJSON(path.join(repoPath, "extensions", folder.dir, "package.json"), manifest(folder.name));
    }
    // The sparse-checkout patterns, as `add`, `list` and `set --stdin` see them.
    const sparse = ["/extensions/*/package.json"];
    // A folder's source is missing until a fetch of its `src/` tree (named by the `rev-parse` before it) brings it.
    // The nth file under a folder's `src/` has the object id n.
    const objectOf = (n: number) => String(n).padStart(40, "0");
    const fetched = new Set<string>();
    let parsedFolder = "";
    const git = fakeRun((_program, args) => {
        const folderOf = (spec: string | undefined) => /^HEAD:extensions\/([^/]+)\/src$/.exec(spec ?? "")?.[1];
        if (args[0] === "rev-parse") {
            parsedFolder = folderOf(args.at(-1)) ?? parsedFolder;
            return { stdout: "c0ffee1234\n" };
        }
        if (args[0] === "fetch") fetched.add(parsedFolder);
        if (args[0] === "rev-list" && args.includes("--missing=print")) {
            const dir = folderOf(args.at(-1))!;
            if (fetched.has(dir)) return {};
            return { stdout: (options.sources?.[dir] ?? []).map((_file, n) => `?${objectOf(n)}\n`).join("") };
        }
        if (args[0] === "ls-tree" && args.includes("-r")) {
            const prefix = args.at(-1)!;
            const dir = /^extensions\/([^/]+)\/src\/$/.exec(prefix)![1]!;
            return {
                stdout: (options.sources?.[dir] ?? []).map((file, n) => `100644 blob ${objectOf(n)}\t${prefix}${file}\0`).join(""),
            };
        }
        if (args[0] === "sparse-checkout" && args[1] === "add") sparse.push(...args.slice(2));
        if (args[0] === "sparse-checkout" && args[1] === "list") return { stdout: `${sparse.join("\n")}\n` };
        if (args[0] === "ls-tree") {
            const lines = [`040000 tree ${options.tree ?? "aaa1"}\textensions/alpha`];
            for (const folder of options.folders ?? []) lines.push(`040000 tree ${folder.tree}\textensions/${folder.dir}`);
            return { stdout: `${lines.join("\n")}\n` };
        }
        return {};
    });
    const cli = fakeRun((_program, args) => {
        if (args[0] === "scan") return { code: 0, stdout: JSON.stringify(supportedScan), ...options.scan };
        if (args[0] === "build" && options.build) return options.build(args);
        if (args[0] === "build" && options.built !== undefined && !options.cliCode) {
            const installed = path.join(args[3]!, path.basename(args[1]!));
            mkdirSync(installed, { recursive: true });
            writeFileSync(path.join(installed, "compatibility.json"), JSON.stringify(options.built));
        }
        return { code: options.cliCode ?? 0, stderr: options.cliCode ? "error: esbuild failed" : "" };
    });
    const asked: { title: string; message: string; primary: string }[] = [];
    const trashed: string[] = [];
    const context: StoreContext = {
        repo: new StoreRepository(repoPath, { run: git.run }),
        supportPath,
        cli: "/Applications/Fudge.app/Contents/Helpers/fudge",
        extensionsDir,
        confirm: async (title, message, primary) => {
            asked.push({ title, message, primary });
            return options.confirm ?? true;
        },
        trash: async (target) => {
            trashed.push(target);
        },
        run: cli.run,
        now: () => new Date("2026-11-20T12:00:00.000Z"),
    };
    return { context, git, cli, asked, trashed, extensionsDir, supportPath, repoPath, sparse };
}
const alphaEntry = parseManifest("alpha", manifest("alpha"))!;

test("install fetches the source, checks it, asks, builds into FUDGE_EXTENSIONS_DIR and records it", async () => {
    const { context, git, cli, asked, extensionsDir, supportPath, repoPath } = await storeContext();
    assert.deepEqual(await install(alphaEntry, context), {});
    assert.deepEqual(git.calls[0]!.args, ["sparse-checkout", "add", "/extensions/alpha/"]);
    assert.deepEqual(asked, [
        {
            title: "Install Alpha?",
            message:
                "From github.com/raycast/extensions at c0ffee1. It runs its own code on your Mac, like any app you install.\n\n" +
                "Fudge supports everything this extension uses.",
            primary: "Install",
        },
    ]);
    assert.deepEqual(cli.calls.map((call) => [call.program, ...call.args]), [
        ["/Applications/Fudge.app/Contents/Helpers/fudge", "scan", path.join(repoPath, "extensions/alpha"), "--json"],
        ["/Applications/Fudge.app/Contents/Helpers/fudge", "build", path.join(repoPath, "extensions/alpha"), "--into", extensionsDir],
    ]);
    assert.deepEqual(buildArguments("/src", "/dest"), ["build", "/src", "--into", "/dest"]);
    assert.deepEqual(await readInstalled(supportPath), {
        alpha: { tree: "aaa1", commit: "c0ffee1234", installedAt: "2026-11-20T12:00:00.000Z", dir: "alpha" },
    });
});

// MARK: - Parts written in Swift (SPEC-145 §3)

/** A scan that found a `swift:` import. */
const swiftScan = JSON.stringify({ ...supportedScan, swiftParts: ["swift:../swift"] });

test("with the Command Line Tools set up, an extension with a Swift part installs as any other, building it (D-118)", async () => {
    const { context, cli, asked, extensionsDir, repoPath } = await storeContext({ scan: { stdout: swiftScan } });
    let readyAsked = 0;
    const chosen: string[] = [];
    context.commandLineToolsReady = async () => {
        readyAsked++;
        return true;
    };
    context.chooseSwiftParts = async (title) => {
        chosen.push(title);
        return "dont-install";
    };
    assert.deepEqual(await install(alphaEntry, context), {});
    assert.deepEqual(chosen, [], "no view");
    assert.equal(asked.length, 1, "only the install's own confirmation");
    assert.equal(asked[0]!.message.includes("Swift"), false, "and nothing in it about Swift");
    assert.deepEqual(cli.calls.at(-1)!.args, [
        "build", path.join(repoPath, "extensions/alpha"), "--into", extensionsDir, "--swift-parts", "build",
    ]);
    assert.equal(cli.calls.at(-1)!.timeout, swiftBuildTimeout, "a first Swift build fetches and compiles its packages");
    // Asked again at the next install, never cached: an extension without one gets build too, which changes nothing.
    const plain = await storeContext();
    plain.context.commandLineToolsReady = context.commandLineToolsReady;
    assert.deepEqual(await install(alphaEntry, plain.context), {});
    assert.deepEqual(plain.cli.calls.at(-1)!.args.slice(-2), ["--swift-parts", "build"]);
    assert.equal(plain.cli.calls.at(-1)!.timeout, buildTimeout, "with no Swift part, the usual time");
    assert.equal(readyAsked, 2);
    // When the check didn't answer (install always scans, so that's a scan that failed), the build may have a Swift
    // part, so it gets that time too.
    for (const scan of [{ code: 1, stdout: "" }, { stdout: "not json" }, { stdout: "{}" }]) {
        const unchecked = await storeContext({ scan });
        unchecked.context.commandLineToolsReady = context.commandLineToolsReady;
        assert.deepEqual(await install(alphaEntry, unchecked.context), {}, JSON.stringify(scan));
        assert.deepEqual(unchecked.cli.calls.at(-1)!.args.slice(-2), ["--swift-parts", "build"], JSON.stringify(scan));
        assert.equal(unchecked.cli.calls.at(-1)!.timeout, swiftBuildTimeout, JSON.stringify(scan));
    }
});

test("without the tools, the view comes first, and its choice is what the build is told", async () => {
    for (const [choice, flag] of [
        ["dont-install", undefined],
        ["leave-out", "leave-out"],
        ["build", "build"],
    ] as const) {
        const { context, cli, asked } = await storeContext({ scan: { stdout: swiftScan } });
        const order: string[] = [];
        context.commandLineToolsReady = async () => false;
        context.chooseSwiftParts = async (title) => {
            order.push(`view: ${title}`);
            return choice;
        };
        const confirm = context.confirm;
        context.confirm = async (...args) => {
            order.push("confirm");
            return confirm(...args);
        };
        const done = await install(alphaEntry, context);
        const builds = cli.calls.filter((call) => call.args[0] === "build");
        if (flag === undefined) {
            assert.equal(done, false, "Don't Install changes nothing");
            assert.deepEqual(order, ["view: Alpha"]);
            assert.deepEqual(builds, []);
            assert.deepEqual(asked, []);
        } else {
            assert.deepEqual(done, {});
            assert.deepEqual(order, ["view: Alpha", "confirm"], "before anything is installed");
            assert.deepEqual(builds.map((call) => call.args.slice(-2)), [["--swift-parts", flag]]);
        }
    }
});

test("without the tools, an extension with no Swift part shows no view and the build is told nothing", async () => {
    const { context, cli } = await storeContext();
    context.commandLineToolsReady = async () => false;
    context.chooseSwiftParts = async () => assert.fail("no view");
    assert.deepEqual(await install(alphaEntry, context), {});
    assert.equal(cli.calls.at(-1)!.args.includes("--swift-parts"), false);
});

test("a swift: import the check missed: without the tools, the build's question becomes the view", async () => {
    for (const choice of ["dont-install", "leave-out"] as const) {
        const { context, cli } = await storeContext({
            build: (args) =>
                args.includes("--swift-parts")
                    ? { code: 0 }
                    : { code: 1, stderr: `✘ [ERROR] ${chooseSwiftPartsMessage} [plugin swift]\n\n    src/index.ts:1:20:` },
        });
        context.commandLineToolsReady = async () => false;
        const views: string[] = [];
        context.chooseSwiftParts = async (title) => {
            views.push(title);
            return choice;
        };
        const done = await install(alphaEntry, context);
        const builds = cli.calls.filter((call) => call.args[0] === "build").map((call) => call.args.slice(4));
        assert.deepEqual(views, ["Alpha"]);
        if (choice === "dont-install") {
            assert.equal(done, false);
            assert.deepEqual(builds, [[]]);
        } else {
            assert.deepEqual(done, {});
            assert.deepEqual(builds, [[], ["--swift-parts", "leave-out"]]);
        }
    }
    // Any other failure is still a failure.
    const { context } = await storeContext({ build: () => ({ code: 1, stderr: "error: esbuild failed" }) });
    context.commandLineToolsReady = async () => false;
    context.chooseSwiftParts = async () => assert.fail("no view");
    await assert.rejects(install(alphaEntry, context), /esbuild failed|didn't/);
});

test("the store's no-flag message is the bundling script's, word for word", () => {
    assert.equal(chooseSwiftPartsMessage, chooseSwiftParts);
    assert.equal(askedForSwiftParts(`✘ [ERROR] ${chooseSwiftParts} [plugin swift]`), true);
    assert.equal(askedForSwiftParts("✘ [ERROR] Could not resolve"), false);
});

test("the view: its words, its three actions in order, the line beside the second", () => {
    assert.equal(
        swiftPartsMessage("Say"),
        "Say has a part written in Swift, and building it needs Apple's Command Line Tools, which aren't set up. " +
            "To install it with that part, set them up in Settings → Development.",
    );
    assert.deepEqual(Object.values(swiftPartsActions), [
        "Don't Install",
        "Install Without the Swift Part",
        "Install with Command Line Tools",
    ]);
    assert.equal(leaveOutLine, "Some commands might not work, or the extension may crash.");
    assert.equal(
        swiftPartsMarkdown("Say"),
        `${swiftPartsMessage("Say")}\n\n- **Don't Install**\n- **Install Without the Swift Part**: ${leaveOutLine}\n- **Install with Command Line Tools**`,
    );
});

test("an extension installed without its Swift part says so on its detail page, and no other does", async () => {
    const folder = await temporary();
    assert.equal(await installedWithoutSwift(folder), false, "no record");
    await writeFile(path.join(folder, swiftPartsFile), JSON.stringify({ swiftParts: "build" }));
    assert.equal(await installedWithoutSwift(folder), false);
    await writeFile(path.join(folder, swiftPartsFile), JSON.stringify({ swiftParts: "leave-out" }));
    assert.equal(await installedWithoutSwift(folder), true);
    await writeFile(path.join(folder, swiftPartsFile), "not json");
    assert.equal(await installedWithoutSwift(folder), false);
    const markdown = detailMarkdown(alphaEntry, "c0ffee1234", "", undefined, true);
    assert.ok(markdown.includes("Installed without its part written in Swift."), markdown);
    assert.equal(detailMarkdown(alphaEntry, "c0ffee1234", "", undefined).includes("Swift"), false);
});

test("a scan's swift: imports become the store's swiftPart, kept in the cache", () => {
    assert.equal((fromReport(JSON.parse(swiftScan)) as { swiftPart?: boolean }).swiftPart, true);
    assert.equal("swiftPart" in fromReport(supportedScan), false, "none, from a scanner that names none too");
});

test("a folder whose manifest has another name installs from the folder, under the name, and records both", async () => {
    const { context, git, cli, supportPath, extensionsDir, repoPath } = await storeContext({
        folders: [{ dir: "amazon-aws", name: "aws", tree: "a5a1" }],
    });
    const aws = parseManifest("amazon-aws", manifest("aws", { title: "Amazon AWS" }))!;
    assert.deepEqual(await install(aws, context), {});
    assert.deepEqual(git.calls[0]!.args, ["sparse-checkout", "add", "/extensions/amazon-aws/"]);
    assert.deepEqual(cli.calls.at(-1)!.args, ["build", path.join(repoPath, "extensions/amazon-aws"), "--into", extensionsDir]);
    assert.deepEqual((await readInstalled(supportPath)).aws, {
        tree: "a5a1",
        commit: "c0ffee1234",
        installedAt: "2026-11-20T12:00:00.000Z",
        dir: "amazon-aws",
    });
    // fudge build installs under the manifest's name, so `<extensions>/aws` is what's checked and trashed.
    await mkdir(path.join(extensionsDir, "aws"));
    assert.equal(await uninstall(aws, context), true);
});

test("two folders with one name: the second can't install over the first, and updates follow the first's folder", async () => {
    const { context, supportPath, extensionsDir, asked } = await storeContext({
        folders: [
            { dir: "world-clock", name: "world-clock", tree: "c10c1" },
            { dir: "world-clock-2", name: "world-clock", tree: "c10c2" },
        ],
    });
    const first = parseManifest("world-clock", manifest("world-clock"))!;
    const second = parseManifest("world-clock-2", manifest("world-clock"))!;
    assert.deepEqual(await install(first, context), {});
    await mkdir(path.join(extensionsDir, "world-clock"));
    await assert.rejects(install(second, context), (error: unknown) => {
        assert.ok(error instanceof StoreError);
        assert.equal(error.message, "Another extension called world-clock is installed. Uninstall it first.");
        return true;
    });
    await assert.rejects(uninstall(second, context), /wasn't installed by the store/, "nor removed through the other row");
    assert.deepEqual(await install(first, context), {}, "updating the first one");
    assert.equal(asked.at(-1)!.title, "Update World-clock?");
    assert.equal((await readInstalled(supportPath))["world-clock"]?.dir, "world-clock");
});

test("the bundled names are the Makefile's bundled extensions' own names", async () => {
    const runtime = new URL("..", import.meta.url);
    const makefile = await readFile(new URL("../Makefile", runtime), "utf8");
    const folders = /^BUNDLED_EXTENSIONS\s*:=\s*(.+)$/m.exec(makefile)![1]!.trim().split(/\s+/);
    const names = await Promise.all(
        folders.map(async (folder) => (JSON.parse(await readFile(new URL(`${folder}/package.json`, runtime), "utf8")) as { name: string }).name),
    );
    assert.deepEqual([...bundledNames].sort(), names.sort());
});

test("an extension Fudge bundles is never installed from the store", async () => {
    const { context, git } = await storeContext();
    for (const name of bundledNames) {
        const bundled = parseManifest(name, manifest(name))!;
        await assert.rejects(install(bundled, context), new RegExp(`${name} is part of Fudge`));
    }
    assert.equal(git.calls.length, 0);
});

test("a manifest whose name changed since the list loaded is refused before anything is built", async () => {
    const { context, cli, repoPath } = await storeContext();
    await writeJSON(path.join(repoPath, "extensions/alpha/package.json"), manifest("renamed"));
    await assert.rejects(install(alphaEntry, context), /Alpha has changed in the store's copy\. Refresh the list/);
    assert.equal(cli.calls.length, 0);
});

test("cancelling builds nothing and records nothing", async () => {
    const { context, cli, supportPath } = await storeContext({ confirm: false });
    assert.equal(await install(alphaEntry, context), false);
    assert.deepEqual(cli.calls.map((call) => call.args[0]), ["scan"], "scanned, never built");
    assert.deepEqual(await readInstalled(supportPath), {});
});

test("a name clash with an extension the store didn't install is refused before anything else", async () => {
    const { context, git, cli, extensionsDir } = await storeContext();
    await mkdir(path.join(extensionsDir, "alpha"));
    await assert.rejects(install(alphaEntry, context), (error: unknown) => {
        assert.ok(error instanceof StoreError);
        assert.equal(error.message, "Another extension called alpha is installed. Uninstall it first.");
        return true;
    });
    assert.equal(git.calls.length, 0);
    assert.equal(cli.calls.length, 0);
});

test("an extension with another package source is refused before asking", async () => {
    const { context, asked, cli, repoPath } = await storeContext();
    await writeFile(path.join(repoPath, "extensions/alpha/.npmrc"), "registry=https://evil.example/");
    await assert.rejects(install(alphaEntry, context), /Alpha can't be installed\. It has an \.npmrc/);
    assert.equal(asked.length, 0);
    assert.equal(cli.calls.length, 0);
});

test("a failed build shows the CLI's message and records nothing", async () => {
    const { context, supportPath, repoPath, extensionsDir } = await storeContext({ cliCode: 1 });
    let thrown: unknown;
    await assert.rejects(install(alphaEntry, context), (error: unknown) => {
        thrown = error;
        return /esbuild failed/.test(String(error));
    });
    assert.deepEqual(await readInstalled(supportPath), {});
    // The failure view gets the whole output, the command and its exit (SPEC-116).
    assert.deepEqual(failureDetails(thrown), {
        output: "error: esbuild failed",
        command: `fudge build ${path.join(repoPath, "extensions/alpha")} --into ${extensionsDir}`,
        code: 1,
    });
});

test("a failure's details say what failed: a build, a git step, or one of the store's own refusals", () => {
    assert.deepEqual(failureDetails(new GitError("fatal: unable to access", "git sparse-checkout add /extensions/a/")), {
        output: "fatal: unable to access",
        command: "git sparse-checkout add /extensions/a/",
    });
    assert.deepEqual(failureDetails(new StoreError("Another extension called a is installed. Uninstall it first.")), {
        output: "Another extension called a is installed. Uninstall it first.",
        refused: true,
    });
    assert.deepEqual(failureDetails(new Error("boom")), { output: "boom" });
    assert.deepEqual(failureDetails("text"), { output: "text" });
});

test("updating an installed extension asks to update and records the new tree", async () => {
    const { context, asked, supportPath, extensionsDir } = await storeContext({ tree: "bbb2" });
    await writeInstalled(supportPath, { alpha: { tree: "aaa1", commit: "old", installedAt: "x", dir: "alpha" } });
    await mkdir(path.join(extensionsDir, "alpha"));
    assert.deepEqual(await install(alphaEntry, context), {}, "its own folder isn't a clash");
    assert.equal(asked[0]!.title, "Update Alpha?");
    assert.equal((await readInstalled(supportPath)).alpha?.tree, "bbb2");
});

test("uninstall trashes only what the store installed, and forgets it", async () => {
    const { context, trashed, supportPath, extensionsDir } = await storeContext();
    await assert.rejects(uninstall(alphaEntry, context), /wasn't installed by the store/);
    await mkdir(path.join(extensionsDir, "alpha"));
    await writeInstalled(supportPath, { alpha: { tree: "t", commit: "c", installedAt: "x", dir: "alpha" } });
    assert.equal(await uninstall(alphaEntry, context), true);
    assert.deepEqual(trashed, [path.join(extensionsDir, "alpha")]);
    assert.deepEqual(await readInstalled(supportPath), {});
});

/** The install confirmation's line for a scan report. */
const line = (report: ScanReport | undefined) => compatibilityLine(report && fromReport(report));

test("the confirmation says what the scan found: up to five APIs, and how many more", async () => {
    const gaps = (...apis: string[]) => ({ supported: false, gaps: apis.map((api) => ({ api })), unreadable: [] });
    assert.equal(line(supportedScan), "Fudge supports everything this extension uses.");
    assert.equal(
        line(gaps("MenuBarExtra", "MenuBarExtra.Item", "MenuBarExtra")),
        "This extension uses things Fudge doesn't have yet: MenuBarExtra, MenuBarExtra.Item. Some of its commands may not work.",
    );
    assert.equal(
        line(gaps("A", "B", "C", "D", "E", "F", "G")),
        "This extension uses things Fudge doesn't have yet: A, B, C, D, E, and 2 more. Some of its commands may not work.",
    );
    assert.equal(
        line(gaps("A", "B", "C", "D", "E")),
        "This extension uses things Fudge doesn't have yet: A, B, C, D, E. Some of its commands may not work.",
        "exactly five: all named",
    );
    assert.equal(
        line(gaps("A", "B", "C", "D", "E", "F")),
        "This extension uses things Fudge doesn't have yet: A, B, C, D, E, and 1 more. Some of its commands may not work.",
        "six: five and one more",
    );
    assert.equal(
        line({ supported: false, gaps: [], unreadable: ["src/a.ts"] }),
        "Fudge couldn't read all of this extension's source, so some of it may not work.",
    );
    assert.equal(line(undefined), "Fudge couldn't check what this extension uses.");
    assert.equal(compatibilityLine({ notChecked: true }), "Fudge couldn't check what this extension uses.");
});

test("Raycast AI and the Browser Extension make an extension not compatible; OAuth doesn't (FUD-118)", () => {
    const report = (...gaps: { api: string; byDesign?: string }[]) => ({ supported: false, gaps, unreadable: [] });
    const ai = { api: "AI.ask", byDesign: "AI" };
    const browser = { api: "BrowserExtension.getTabs", byDesign: "Browser Extension" };
    const oauth = { api: "OAuth.PKCEClient", byDesign: "OAuth" };
    assert.equal(
        line(report(ai, { api: "AI.Model", byDesign: "AI" })),
        "Not compatible with Fudge: this extension uses Raycast AI, which Fudge doesn't support. Commands that use it won't work.",
    );
    assert.equal(
        line(report(browser)),
        "Not compatible with Fudge: this extension uses the Raycast Browser Extension, which Fudge doesn't support. Commands that use it won't work.",
    );
    assert.equal(
        line(report(browser, ai)),
        "Not compatible with Fudge: this extension uses Raycast AI and the Raycast Browser Extension, which Fudge doesn't support. Commands that use them won't work.",
        "both, AI first whatever the scan's order",
    );
    assert.equal(
        line(report(ai, { api: "WindowManagement.getActiveWindow" })),
        "Not compatible with Fudge: this extension uses Raycast AI, which Fudge doesn't support. Commands that use it won't work. It also uses things Fudge doesn't have yet: WindowManagement.getActiveWindow. Some of its commands may not work.",
    );
    assert.equal(
        line(report(oauth)),
        "This extension signs in with OAuth, which works if the sign-in server chosen in Settings → Sign-in supports its provider.",
        "OAuth is never called not compatible",
    );
    assert.equal(
        line(report({ api: "Clipboard.read" }, oauth, ai)),
        "Not compatible with Fudge: this extension uses Raycast AI, which Fudge doesn't support. Commands that use it won't work. It also uses things Fudge doesn't have yet: Clipboard.read. Some of its commands may not work. It signs in with OAuth, which works if the sign-in server chosen in Settings → Sign-in supports its provider.",
    );
    const sixAndAI = report(...["A", "B", "C", "D", "E", "F"].map((api) => ({ api })), ai);
    assert.match(line(sixAndAI), /A, B, C, D, E, and 1 more\./, "categories don't count toward the five");
    assert.match(line(report({ api: "Telepathy.read", byDesign: "Telepathy" })), /doesn't have yet: Telepathy\.read\./, "an unknown category reads as its APIs");
});

test("the detail's Compatibility line: checking, then compatible, not compatible, missing or signing in", () => {
    const result = (report: ScanReport) => compatibilityText(fromReport(report));
    const report = (...gaps: { api: string; byDesign?: string }[]) => ({ supported: false, gaps, unreadable: [] });
    assert.equal(compatibilityText("checking"), "Checking…");
    assert.equal(compatibilityText("failed"), "Couldn't check");
    assert.equal(compatibilityText({ notChecked: true }), "Not checked: installing checks it");
    assert.equal(result(supportedScan), "Compatible");
    assert.equal(result(report({ api: "AI.ask", byDesign: "AI" })), "Not compatible: Raycast AI");
    assert.equal(
        result(report({ api: "BrowserExtension.getTabs", byDesign: "Browser Extension" }, { api: "AI.ask", byDesign: "AI" })),
        "Not compatible: Raycast AI and Raycast Browser Extension",
    );
    assert.equal(
        result(report(...["A", "B", "C", "D", "E", "F_G"].map((api) => ({ api })))),
        "Missing: `A`, `B`, `C`, `D`, `E`, and 1 more",
        "API names are code spans, so markdown never reads an underscore",
    );
    assert.equal(result(report({ api: "OAuth", byDesign: "OAuth" })), "Signs in with OAuth (Settings → Sign-in)");
    assert.equal(
        result(report({ api: "AI.ask", byDesign: "AI" }, { api: "Clipboard.read" })),
        "Not compatible: Raycast AI. Missing: `Clipboard.read`",
    );
    assert.equal(result({ supported: false, gaps: [], unreadable: ["src/big.ts"] }), "Partly checked: some of its source couldn't be read");
});

test("the list's Not compatible tag comes only from a cached result that says so", () => {
    assert.deepEqual(accessoryTexts(gamma, "installed", "Not compatible"), [
        { text: "someone" },
        { text: "1 command" },
        { tag: "Not compatible" },
        { tag: "Installed" },
    ]);
    assert.equal(isNotCompatible(undefined), false, "nothing cached: no tag, and the list never scans");
    assert.equal(isNotCompatible({ notChecked: true }), false);
    assert.equal(isNotCompatible(fromReport({ supported: false, gaps: [{ api: "AI.ask", byDesign: "AI" }], unreadable: [] })), true);
    assert.equal(isNotCompatible(fromReport({ supported: false, gaps: [{ api: "OAuth", byDesign: "OAuth" }], unreadable: [] })), false);
    assert.equal(isNotCompatible(fromReport({ supported: false, gaps: [{ api: "Clipboard.read" }], unreadable: [] })), false);
});

// SPEC-109 §2: with each command's result, an extension where only some commands use Raycast AI is Partly compatible.

/** A scan report whose commands each reach what's given (Raycast AI by default). */
const perCommand = (using: Record<string, string[]>, gaps = [{ api: "AI.ask", byDesign: "AI" }]): ScanReport => ({
    supported: false,
    gaps,
    unreadable: [],
    commands: Object.entries(using).map(([name, unsupported]) => ({ name, unsupported })),
});
const slackLike = perCommand({ search: [], "send-message": [], "search-emojis": ["AI"], "set-status": ["AI"] });
const titles = (name: string) =>
    ({ search: "Search", "send-message": "Send Message", "search-emojis": "Search Emojis", "set-status": "Set Status" })[
        name
    ] ?? name;

test("some commands using Raycast AI is Partly compatible, orange; every command is Not compatible, as before", () => {
    const partly = fromReport(slackLike);
    assert.deepEqual(partly, {
        byCommand: { count: 4, using: ["search-emojis", "set-status"] },
        notSupported: ["AI"],
        missing: [],
        signsIn: false,
        signsInThroughRaycast: false,
        unreadable: false,
    });
    assert.equal(compatibilityTag(partly), "Partly compatible");
    assert.equal(isNotCompatible(partly), false);
    assert.equal(isPartlyCompatible(partly), true);
    const every = fromReport(perCommand({ ask: ["AI"], chat: ["AI", "Browser Extension"] }));
    assert.equal(compatibilityTag(every), "Not compatible");
    assert.equal(compatibilityTag(fromReport(perCommand({ a: [], b: [] }, []))), undefined);
    // An AI tool's use isn't a command's: no AI label at all.
    const toolsOnly = fromReport(perCommand({ meetings: [] }));
    assert.deepEqual(toolsOnly.notChecked ? undefined : toolsOnly.notSupported, []);
    assert.equal(compatibilityTag(toolsOnly), undefined);
    assert.equal(compatibilityText(toolsOnly), "Compatible");
    // A scanner from before SPEC-109 says nothing per command: Not compatible, as before.
    assert.equal(compatibilityTag(fromReport({ supported: false, gaps: [{ api: "AI.ask", byDesign: "AI" }], unreadable: [] })), "Not compatible");
    assert.deepEqual(accessoryTexts(gamma, "available", "Partly compatible"), [
        { text: "someone" },
        { text: "1 command" },
        { tag: "Partly compatible" },
    ]);
});

test("the detail and the confirmation name the commands, and the confirmation says they won't be enabled", () => {
    assert.equal(
        compatibilityText(fromReport(slackLike), titles),
        "Partly compatible: 2 of 4 commands use Raycast AI: Search Emojis, Set Status",
    );
    assert.equal(
        compatibilityText(fromReport(perCommand({ a: ["AI"], b: [], c: [] }))),
        "Partly compatible: 1 of 3 commands uses Raycast AI: a",
    );
    assert.equal(
        compatibilityLine(fromReport(slackLike), titles),
        "Partly compatible with Fudge: Search Emojis and Set Status use Raycast AI, which Fudge doesn't support. " +
            "They won't be enabled. You can turn them on in Settings → Commands.",
    );
    assert.equal(
        compatibilityLine(fromReport(perCommand({ ask: ["AI"], list: [] })), titles),
        "Partly compatible with Fudge: ask uses Raycast AI, which Fudge doesn't support. It won't be enabled. " +
            "You can turn it on in Settings → Commands.",
    );
    assert.equal(
        compatibilityLine(fromReport(perCommand({ ask: ["AI"], tabs: ["Browser Extension"] }, [
            { api: "AI.ask", byDesign: "AI" },
            { api: "BrowserExtension.getTabs", byDesign: "Browser Extension" },
        ]))),
        "Not compatible with Fudge: every command uses Raycast AI or the Raycast Browser Extension, which Fudge " +
            "doesn't support, so none of them will be enabled. You can turn them on in Settings → Commands.",
    );
});

test("per-command results keep command names as Raycast accepts them (caffeinateWhile, dots)", async () => {
    const byCommand = (report: ScanReport) => {
        const result = fromReport(report);
        return "byCommand" in result ? result.byCommand : undefined;
    };
    const camel = perCommand({ caffeinateWhile: ["AI"], addSchedule: [], "show-recent.command": [] });
    assert.deepEqual(byCommand(camel), { count: 3, using: ["caffeinateWhile"] });
    assert.deepEqual(byCommand(perCommand({ "a b": ["AI"], ok: [] })), undefined, "one bad name drops them");

    const supportPath = await mkdtemp(path.join(tmpdir(), "fudge-camel-"));
    await writeCompatibility(supportPath, "scanner-1", new Map([[treeOf(1), fromReport(camel)]]));
    assert.deepEqual((await readCompatibility(supportPath, "scanner-1")).get(treeOf(1)), fromReport(camel));
    await rm(supportPath, { recursive: true, force: true });
});

test("a cached result keeps its commands, and one with a bad commands entry is dropped", async () => {
    const supportPath = await mkdtemp(path.join(tmpdir(), "fudge-partly-"));
    const partly = fromReport(slackLike);
    await writeCompatibility(supportPath, "scanner-1", new Map([[treeOf(1), partly]]));
    assert.deepEqual((await readCompatibility(supportPath, "scanner-1")).get(treeOf(1)), partly);
    const bad = (byCommand: unknown) => ({ notSupported: ["AI"], missing: [], signsIn: false, signsInThroughRaycast: false, unreadable: false, byCommand });
    await writeFile(
        compatibilityFile(supportPath),
        JSON.stringify({
            version: 2,
            scanner: "scanner-1",
            trees: {
                [treeOf(2)]: bad({ count: 2, using: ["a", "b", "c"] }),
                [treeOf(3)]: bad({ count: 2, using: ["Not A Name"] }),
                [treeOf(4)]: bad({ count: "2", using: [] }),
                [treeOf(5)]: bad(null),
                [treeOf(6)]: bad({ count: 3, using: ["a"] }),
            },
        }),
    );
    assert.deepEqual([...(await readCompatibility(supportPath, "scanner-1")).keys()], [treeOf(6)]);
    await rm(supportPath, { recursive: true, force: true });
});

test("install's confirmation carries the scan's gaps, and a failed scan doesn't stop the install", async () => {
    const report = { extension: "alpha", supported: false, gaps: [{ api: "AI.ask", kind: "missing", byDesign: "AI" }], unreadable: [] };
    const withGaps = await storeContext({ scan: { stdout: JSON.stringify(report) } });
    assert.deepEqual(await install(alphaEntry, withGaps.context), {});
    assert.match(
        withGaps.asked[0]!.message,
        /\n\nNot compatible with Fudge: this extension uses Raycast AI, which Fudge doesn't support\. Commands that use it won't work\.$/,
    );

    for (const scan of [{ code: 1, stdout: "" }, { stdout: "not json" }, { stdout: "{}" }]) {
        const failed = await storeContext({ scan });
        assert.deepEqual(await install(alphaEntry, failed.context), {}, JSON.stringify(scan));
        assert.match(failed.asked[0]!.message, /\n\nFudge couldn't check what this extension uses\.$/);
    }
});

// MARK: - Compatibility: the cache, the detail's scan, and install

const treeOf = (n: number) => n.toString(16).padStart(40, "0");
const aiOnly: Compatibility = { notSupported: ["AI"], missing: [], signsIn: false, signsInThroughRaycast: false, unreadable: false };

test("results are cached by tree id, for the scanner that wrote them only", async () => {
    const support = await temporary();
    assert.deepEqual(await readCompatibility(support, "s1"), new Map(), "no file yet");
    await rememberCompatibility(support, "s1", treeOf(1), aiOnly);
    await rememberCompatibility(support, "s1", treeOf(2), { notChecked: true });
    assert.deepEqual(
        await readCompatibility(support, "s1"),
        new Map<string, Compatibility>([
            [treeOf(1), aiOnly],
            [treeOf(2), { notChecked: true }],
        ]),
    );
    assert.deepEqual(await readCompatibility(support, "s2"), new Map(), "another Fudge's scanner: nothing is used");

    // Another build of the tool is another scanner.
    const tool = path.join(support, "fudge");
    await writeFile(tool, "one");
    const before = await scannerIdentity(tool);
    await writeFile(tool, "build two");
    assert.notEqual(await scannerIdentity(tool), before);
    assert.equal(await scannerIdentity(path.join(support, "missing")), "unknown");
});

test("the cache lets in only valid entries, and keeps the newest", async () => {
    const support = await temporary();
    await writeJSON(compatibilityFile(support), {
        version: 2,
        scanner: "s",
        trees: {
            [treeOf(1)]: aiOnly,
            aaa1: aiOnly,
            [treeOf(2)]: { ...aiOnly, missing: ["Clipboard.read", "a b"] },
            [treeOf(3)]: { ...aiOnly, notSupported: ["Telepathy"] },
            [treeOf(4)]: { notSupported: [], missing: [] },
            [treeOf(5)]: "Compatible",
            [treeOf(6)]: { notSupported: [], missing: ["Clipboard.read"], signsIn: true, signsInThroughRaycast: false, unreadable: false },
        },
    });
    assert.deepEqual(
        [...(await readCompatibility(support, "s")).keys()],
        [treeOf(1), treeOf(6)],
        "a short tree id, an API name with a space, an unknown category, missing fields and a string are dropped",
    );
    await writeFile(compatibilityFile(support), "{ not json");
    assert.deepEqual(await readCompatibility(support, "s"), new Map());

    const many = new Map<string, Compatibility>();
    for (let n = 0; n < maxCachedResults + 5; n++) many.set(treeOf(n), { notChecked: true });
    await writeCompatibility(support, "s", many);
    const kept = await readCompatibility(support, "s");
    assert.equal(kept.size, maxCachedResults);
    assert.equal(kept.has(treeOf(4)), false, "the oldest go");
    assert.equal(kept.has(treeOf(maxCachedResults + 4)), true);
    await rememberCompatibility(support, "s", treeOf(5), aiOnly);
    assert.equal([...(await readCompatibility(support, "s")).keys()].at(-1), treeOf(5), "remembering makes it the newest");
});

test("a detail scan fetches the folder's src/ with a per-file cap, checks out its source, scans it, and takes the patterns out again", async () => {
    const report = { extension: "alpha", supported: false, gaps: [{ api: "AI.ask", kind: "missing", byDesign: "AI" }], unreadable: [] };
    const { context, git, cli, repoPath } = await storeContext({
        sources: { alpha: ["index.ts", "lib/util.tsx", "data.json", "logo.png"] },
        scan: { stdout: JSON.stringify(report) },
    });
    assert.deepEqual(await checkFolder("alpha", context, () => false), aiOnly);
    assert.deepEqual(
        git.calls.map((call) => call.args),
        [
            ["ls-tree", "-r", "-z", "HEAD", "--", "extensions/alpha/src/"],
            // What's missing first: nothing is fetched when it's all here.
            ["rev-list", "--objects", "--missing=print", "HEAD:extensions/alpha/src"],
            ["rev-parse", "--verify", "HEAD:extensions/alpha/src"],
            [
                "fetch",
                "--refetch",
                "--no-write-fetch-head",
                "--no-tags",
                "--no-auto-maintenance",
                "--no-auto-gc",
                `--filter=blob:limit=${maxScanBytes}`,
                "origin",
                "c0ffee1234",
            ],
            ["rev-list", "--objects", "--missing=print", "HEAD:extensions/alpha/src"],
            ["sparse-checkout", "add", ...scanPatterns("alpha")],
            ["sparse-checkout", "list"],
            ["sparse-checkout", "set", "--no-cone", "--stdin"],
        ],
    );
    assert.deepEqual(git.calls[5]!.env, { GIT_NO_LAZY_FETCH: "1" }, "the checkout never downloads");
    assert.deepEqual(scanPatterns("alpha"), [
        "/extensions/alpha/src/**/*.tsx",
        "/extensions/alpha/src/**/*.ts",
        "/extensions/alpha/src/**/*.jsx",
        "/extensions/alpha/src/**/*.js",
    ]);
    assert.equal(git.calls[7]!.input, "/extensions/*/package.json\n", "only the scan's own patterns go");
    assert.deepEqual(cli.calls.map((call) => call.args), [["scan", path.join(repoPath, "extensions/alpha"), "--json"]]);
});

test("the source files are what the scan's patterns check out: the scanner's extensions, in a file's name or a folder's", () => {
    for (const file of ["index.ts", "lib/view.tsx", "old.js", "a/b/c.jsx", "types.d.ts", "index.test.ts", "lib.ts/logo.png"]) {
        assert.ok(isScanned(file), file);
    }
    for (const file of ["data.json", "logo.png", "module.mjs", "module.cjs", "style.css", "ts", "notes.ts.md"]) {
        assert.ok(!isScanned(file), file);
    }
});

test("past the caps a row isn't checked: too many source files, or files under src/, fetch nothing; too many bytes scan nothing", async () => {
    const sources = Array.from({ length: maxScanFiles }, (_, n) => `file${n}.ts`);
    const assets = (count: number) => Array.from({ length: count }, (_, n) => `assets/image${n}.png`);
    // Assets don't count toward the scan's cap, only toward the download's.
    const atCaps = await storeContext({ sources: { alpha: [...sources, ...assets(maxSrcFiles - maxScanFiles)] } });
    assert.deepEqual(await checkFolder("alpha", atCaps.context, () => false), fromReport(supportedScan), "exactly both caps is fine");
    assert.equal(atCaps.cli.calls.length, 1);

    const tooManySources = await storeContext({ sources: { alpha: [...sources, "one-more.tsx", "a.png"] } });
    assert.deepEqual(await checkFolder("alpha", tooManySources.context, () => false), { notChecked: true });
    assert.deepEqual(tooManySources.git.calls.map((call) => call.args[0]), ["ls-tree"], "nothing fetched");
    assert.deepEqual(tooManySources.cli.calls, []);

    // Every file under src/ is downloaded, so past the download's cap nothing is, however few the source files.
    const tooManyFiles = await storeContext({ sources: { alpha: ["index.ts", ...assets(maxSrcFiles)] } });
    assert.deepEqual(await checkFolder("alpha", tooManyFiles.context, () => false), { notChecked: true });
    assert.deepEqual(tooManyFiles.git.calls.map((call) => call.args[0]), ["ls-tree"], "nothing fetched");
    assert.deepEqual(tooManyFiles.cli.calls, []);

    // After the fetch, a source file is still missing (over the per-file cap): not checked. An asset still missing is
    // no reason.
    for (const [still, expected] of [
        ["index.ts", { notChecked: true }],
        ["hero.png", fromReport(supportedScan)],
    ] as const) {
        const files = ["index.ts", "hero.png"];
        const left = await storeContext({ sources: { alpha: files } });
        const reply = left.git.run;
        let fetched = false;
        const withMissing: Run = async (program, args, options) => {
            if (args[0] === "fetch") fetched = true;
            if (args[0] !== "rev-list") return reply(program, args, options);
            const missing = fetched ? [still] : files;
            const lines = missing.map((file) => `?${String(files.indexOf(file)).padStart(40, "0")}\n`);
            return { code: 0, stdout: `abc1 extensions/alpha/src\n${lines.join("")}`, stderr: "" };
        };
        const overCap = { ...left.context, repo: new StoreRepository(left.repoPath, { run: withMissing }) };
        assert.deepEqual(await checkFolder("alpha", overCap, () => false), expected, `${still} over the per-file cap`);
        assert.ok(fetched, `${still}: fetched`);
        const checkedOut = left.git.calls.some((call) => call.args[0] === "sparse-checkout" && call.args[1] === "add");
        assert.equal(checkedOut, still === "hero.png", `${still}: checked out or not`);
        assert.equal(left.cli.calls.length, still === "hero.png" ? 1 : 0, `${still}: scanned or not`);
    }

    const big = await storeContext({ sources: { alpha: ["huge.js"] } });
    await mkdir(path.join(big.repoPath, "extensions/alpha/src"), { recursive: true });
    await writeFile(path.join(big.repoPath, "extensions/alpha/src/huge.js"), Buffer.alloc(maxScanBytes + 1));
    assert.deepEqual(await checkFolder("alpha", big.context, () => false), { notChecked: true });
    assert.deepEqual(big.cli.calls, [], "not scanned");
    assert.deepEqual(big.git.calls.at(-1)!.args, ["sparse-checkout", "set", "--no-cone", "--stdin"], "its patterns are taken out");
});

test("a detail scan that fails throws, and still takes its patterns out; one cancelled before its fetch fetches nothing", async () => {
    const failing = await storeContext({ sources: { alpha: ["index.ts"] }, scan: { code: 1 } });
    await assert.rejects(checkFolder("alpha", failing.context, () => false), /fudge scan failed/);
    assert.deepEqual(failing.git.calls.at(-1)!.args, ["sparse-checkout", "set", "--no-cone", "--stdin"]);

    const cancelled = await storeContext({ sources: { alpha: ["index.ts"] } });
    assert.equal(await checkFolder("alpha", cancelled.context, () => true), undefined);
    assert.deepEqual(cancelled.git.calls.map((call) => call.args[0]), ["ls-tree"]);
    assert.deepEqual(cancelled.cli.calls, []);
});

/** Lets started work (the git queue, the fake runs, the file reads) go as far as it can. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

/** Timers that only move when told to. */
function manualTimers() {
    let now = 0;
    let next = 1;
    const waiting = new Map<number, { at: number; run: () => void }>();
    return {
        timers: {
            set: (run: () => void, ms: number) => {
                waiting.set(next, { at: now + ms, run });
                return next++;
            },
            clear: (handle: unknown) => void waiting.delete(handle as number),
        },
        advance(ms: number) {
            now += ms;
            for (const [handle, timer] of [...waiting]) {
                if (timer.at > now) continue;
                waiting.delete(handle);
                timer.run();
            }
        },
    };
}

test("moving through 20 rows quickly fetches nothing; the row the selection rests on is checked once", async () => {
    const report = { extension: "row7", supported: true, gaps: [], unreadable: [] };
    const { context, git, cli } = await storeContext({ sources: { row7: ["index.ts"] }, scan: { stdout: JSON.stringify(report) } });
    const clock = manualTimers();
    const results = new Map<string, Compatibility>();
    let settled: (value: unknown) => void = () => undefined;
    const done = new Promise((resolve) => (settled = resolve));
    const checks = new CompatibilityChecks({
        timers: clock.timers,
        cached: (tree) => results.get(tree),
        check: (dir, _tree, cancelled) => oneAtATime(() => checkFolder(dir, context, cancelled)),
        changed: (dir, tree, result) => {
            if (result !== "failed") results.set(tree, result);
            settled([dir, result]);
        },
    });
    for (let row = 0; row < 20; row++) {
        checks.select(`row${row}`, treeOf(row));
        clock.advance(100);
        await settle();
    }
    assert.equal(git.calls.length, 0, "nothing fetched while moving");
    assert.equal(cli.calls.length, 0);
    checks.select(`row7`, treeOf(7));
    clock.advance(499);
    await settle();
    assert.equal(git.calls.length, 0, "not before half a second of rest");
    checks.select(`row7`, treeOf(7));
    clock.advance(1);
    assert.deepEqual(await done, ["row7", { notSupported: [], missing: [], signsIn: false, signsInThroughRaycast: false, unreadable: false }]);
    assert.equal(cli.calls.length, 1);
    assert.equal(git.calls.filter((call) => call.args[1] === "add").length, 1);

    const before = git.calls.length;
    checks.select(undefined, undefined);
    checks.select(`row7`, treeOf(7));
    clock.advance(5000);
    await settle();
    assert.equal(git.calls.length, before, "a cached row never fetches");
    assert.equal(cli.calls.length, 1);
});

test("moving on cancels a check before its fetch, and a failed check says so", async () => {
    const { context, git } = await storeContext({ sources: { alpha: ["index.ts"] } });
    const clock = manualTimers();
    const changes: unknown[] = [];
    const checks = new CompatibilityChecks({
        timers: clock.timers,
        cached: () => undefined,
        check: (dir, _tree, cancelled) => checkFolder(dir, context, cancelled),
        changed: (dir, _tree, result) => changes.push([dir, result]),
    });
    checks.select("alpha", treeOf(1));
    clock.advance(500);
    checks.select("beta", treeOf(2)); // while alpha's listing is still being read
    await settle();
    assert.deepEqual(git.calls.map((call) => call.args[0]), ["ls-tree"], "alpha's source isn't fetched");
    assert.equal(changes.length, 0);
    checks.stop();

    const failing = await storeContext({ sources: { alpha: ["index.ts"] }, scan: { code: 1 } });
    const failed = new CompatibilityChecks({
        timers: clock.timers,
        cached: () => undefined,
        check: (dir, _tree, cancelled) => checkFolder(dir, failing.context, cancelled),
        changed: (dir, _tree, result) => changes.push([dir, result]),
    });
    failed.select("alpha", treeOf(1));
    clock.advance(500);
    await settle();
    assert.deepEqual(changes, [["alpha", "failed"]]);
});

test("moving through 20 rows fetches no README; the row the selection rests on is fetched once, by its tree", async () => {
    const { context, git } = await storeContext();
    await writeFile(path.join(context.repo.path, "extensions/alpha/README.md"), "# Alpha\n");
    const clock = manualTimers();
    const readmes = new Map<string, string>();
    const fetches = new RestingWork<string>({
        timers: clock.timers,
        done: (key) => readmes.has(key.split("\0")[1]!),
        run: (key, cancelled) =>
            oneAtATime(async () => (cancelled() ? undefined : fetchReadme(context.repo, key.split("\0")[0]!))),
        // As the view keeps them: a failed fetch isn't kept (the view shows it as no README).
        changed: (key, readme) => {
            if (readme !== "failed") readmes.set(key.split("\0")[1]!, readme);
        },
    });
    const adds = () => git.calls.filter((call) => call.args[0] === "sparse-checkout" && call.args[1] === "add");
    for (let row = 0; row < 20; row++) {
        fetches.select(`row${row}\0${treeOf(row)}`);
        clock.advance(100);
        await settle();
    }
    assert.equal(adds().length, 0, "no README fetched while moving");
    fetches.select(`alpha\0${treeOf(7)}`);
    clock.advance(499);
    await settle();
    assert.equal(adds().length, 0, "not before half a second of rest");
    clock.advance(1);
    await settle();
    assert.deepEqual(adds().map((call) => call.args.slice(2)), [["/extensions/alpha/README.md"]]);
    assert.equal(readmes.get(treeOf(7)), "# Alpha\n");

    fetches.select(undefined);
    fetches.select(`alpha\0${treeOf(7)}`);
    clock.advance(5000);
    await settle();
    assert.equal(adds().length, 1, "a README already fetched for that tree never fetches again");
    fetches.select(`alpha\0${treeOf(8)}`);
    clock.advance(500);
    await settle();
    assert.equal(adds().length, 2, "a changed folder is a new tree, fetched again");
});

test("a README git couldn't fetch isn't kept as missing: selecting it again waits, and ⌘R (again) fetches it", async () => {
    let gitFails = true;
    const { context } = await storeContext();
    const failing = fakeRun((_program, args) =>
        gitFails && args[0] === "sparse-checkout" && args[1] === "add"
            ? { code: 128, stderr: "fatal: unable to access 'https://github.com/raycast/extensions/': Could not resolve host" }
            : {},
    );
    const repo = new StoreRepository(context.repo.path, { run: failing.run });
    await writeFile(path.join(repo.path, "extensions/alpha/README.md"), "# Alpha\n");
    await assert.rejects(fetchReadme(repo, "alpha"), /Could not resolve host/, "a failed fetch throws");
    gitFails = false;
    assert.equal(await fetchReadme(repo, "alpha"), "# Alpha\n");
    assert.equal(await fetchReadme(repo, "beta"), "", "a folder with no README has none, which is kept");

    gitFails = true;
    const clock = manualTimers();
    const readmes = new Map<string, string>();
    const failures: string[] = [];
    const fetches = new RestingWork<string>({
        timers: clock.timers,
        done: (key) => readmes.has(key),
        run: (key) => fetchReadme(repo, key),
        changed: (key, readme) => (readme === "failed" ? failures.push(key) : readmes.set(key, readme)),
    });
    const adds = () => failing.calls.filter((call) => call.args[1] === "add").length;
    const before = adds();
    fetches.select("alpha");
    clock.advance(500);
    await settle();
    assert.deepEqual(failures, ["alpha"]);
    assert.equal(readmes.has("alpha"), false, "not kept as missing");
    fetches.select("alpha");
    clock.advance(5000);
    await settle();
    assert.equal(adds() - before, 1, "a render selecting it again doesn't fetch again");

    gitFails = false;
    fetches.again();
    clock.advance(500);
    await settle();
    assert.equal(readmes.get("alpha"), "# Alpha\n", "⌘R fetched it");
    fetches.again();
    clock.advance(5000);
    await settle();
    assert.equal(adds() - before, 2, "and once it's kept, ⌘R doesn't fetch it again");

    // One that failed and was left: ⌘R with nothing selected fetches nothing.
    gitFails = true;
    fetches.select("gamma");
    clock.advance(500);
    await settle();
    assert.deepEqual(failures, ["alpha", "gamma"]);
    fetches.select(undefined);
    gitFails = false;
    fetches.again();
    clock.advance(5000);
    await settle();
    assert.equal(adds() - before, 3, "with nothing selected, again does nothing");
    assert.equal(readmes.has("gamma"), false);
});

test("a README fetch on its way shows as loading, a failed one says so, and none shows only for a folder without one", async () => {
    let gitFails = true;
    const { context } = await storeContext({ folders: [{ dir: "beta", name: "beta", tree: "bbb2" }] });
    const failing = fakeRun((_program, args) =>
        gitFails && args[0] === "sparse-checkout" && args[1] === "add"
            ? { code: 128, stderr: "fatal: unable to access 'https://github.com/raycast/extensions/': Could not resolve host" }
            : {},
    );
    const repo = new StoreRepository(context.repo.path, { run: failing.run });
    await writeFile(path.join(repo.path, "extensions/alpha/README.md"), "# Alpha\n");
    const entry = parseManifest("alpha", manifest("alpha"))!;
    const clock = manualTimers();
    // Each fetch waits for `release`, so a test can look while it runs.
    let release = () => {};
    const held = () => new Promise<void>((resolve) => (release = resolve));
    let gate = held();
    // The store's own state and callbacks (extension-store.tsx), each key a folder's tree.
    let readmes: Record<string, string> = {};
    let failed: ReadonlySet<string> = new Set();
    const scheduled: string[] = [];
    const fetches = new RestingWork<string>({
        timers: clock.timers,
        done: (key) => readmes[key] !== undefined,
        run: async (key) => {
            await gate;
            return fetchReadme(repo, key);
        },
        changed: (key, readme) => {
            if (readme === "failed") failed = new Set(failed).add(key);
            else readmes = { ...readmes, [key]: readme };
        },
        scheduled: (key) => {
            scheduled.push(key);
            failed = refetching(failed, key);
        },
    });
    const shown = (dir = "alpha") => detailMarkdown(entry, "c0ffee", shownReadme(dir, readmes, failed));
    const loading = /Loading the README/;
    const notFetched = /couldn't fetch the README/;
    /** Lets the waiting fetch start, looks while it runs, then lets it end. */
    const fetch = async (why: string, dir = "alpha") => {
        clock.advance(500);
        await settle();
        assert.match(shown(dir), loading, `${why}: loading while it runs`);
        release();
        await settle();
        gate = held();
    };

    fetches.select("alpha");
    assert.match(shown(), loading, "the first fetch, waiting");
    await fetch("the first fetch");
    assert.match(shown(), notFetched, "it failed, and the detail says so");
    assert.doesNotMatch(shown(), loading);

    fetches.select("alpha");
    assert.match(shown(), notFetched, "a render selecting it again fetches nothing, so the failure stays");
    fetches.again();
    assert.match(shown(), loading, "⌘R: on its way, so loading, not the failure");
    await fetch("⌘R's retry");
    assert.match(shown(), notFetched, "the retry failed too");

    fetches.select("beta");
    fetches.select("alpha");
    assert.match(shown(), loading, "back on the row: on its way again");
    gitFails = false;
    await fetch("the fetch on coming back");
    assert.match(shown(), /# Alpha/, "fetched");
    assert.doesNotMatch(shown(), loading);
    assert.doesNotMatch(shown(), notFetched);

    fetches.select("beta");
    assert.match(shown("beta"), loading);
    await fetch("beta's fetch", "beta");
    assert.equal(readmes.beta, "", "beta has no README");
    assert.ok(!/README|---/.test(shown("beta")), "and only that shows nothing");

    fetches.select("alpha");
    fetches.again();
    assert.deepEqual(scheduled, ["alpha", "alpha", "beta", "alpha", "beta"], "a kept README is never on its way again");
});

test("resting work: moving on cancels and aborts, and a result that comes in after it is still kept", async () => {
    const clock = manualTimers();
    const kept: [string, unknown][] = [];
    const runs: { key: string; cancelled: () => boolean; signal: AbortSignal; finish: (value: string) => void }[] = [];
    const work = new RestingWork<string>({
        timers: clock.timers,
        done: () => false,
        run: (key, cancelled, signal) =>
            new Promise((resolve) => runs.push({ key, cancelled, signal, finish: (value) => resolve(value) })),
        changed: (key, result) => kept.push([key, result]),
    });
    work.select("a");
    clock.advance(500);
    assert.equal(runs.length, 1);
    work.select("a");
    assert.equal(runs[0]!.cancelled(), false, "the same key again changes nothing");
    work.select("b");
    assert.equal(runs[0]!.cancelled(), true);
    assert.equal(runs[0]!.signal.aborted, true, "its fetch is ended");
    runs[0]!.finish("A");
    await settle();
    assert.deepEqual(kept, [["a", "A"]]);
    work.stop();
    clock.advance(500);
    assert.equal(runs.length, 1, "a stopped wait never runs");
});

test("install uses this version's cached result instead of scanning, and caches its own scan", async () => {
    const tree = treeOf(42);
    const cached = await storeContext({ tree });
    await rememberCompatibility(cached.supportPath, await scannerIdentity(cached.context.cli), tree, aiOnly);
    assert.deepEqual(await install(alphaEntry, cached.context), {});
    assert.deepEqual(cached.cli.calls.map((call) => call.args[0]), ["build"], "no scan");
    assert.match(cached.asked[0]!.message, /Not compatible with Fudge: this extension uses Raycast AI/);

    const notChecked = await storeContext({ tree });
    await rememberCompatibility(notChecked.supportPath, await scannerIdentity(notChecked.context.cli), tree, { notChecked: true });
    assert.deepEqual(await install(alphaEntry, notChecked.context), {});
    assert.deepEqual(notChecked.cli.calls.map((call) => call.args[0]), ["scan", "build"], "too big to check while browsing: installing scans");

    const fresh = await storeContext({ tree });
    assert.deepEqual(await install(alphaEntry, fresh.context), {});
    assert.deepEqual(
        (await readCompatibility(fresh.supportPath, await scannerIdentity(fresh.context.cli))).get(tree),
        { notSupported: [], missing: [], signsIn: false, signsInThroughRaycast: false, unreadable: false },
        "the list and the detail get the install's scan",
    );
});

test("installed.json drops invalid names, folders and records; an entry without a folder came from its name's", async () => {
    const support = await temporary();
    await writeFile(
        path.join(support, "installed.json"),
        JSON.stringify({
            alpha: { tree: "t", commit: "c", installedAt: "x" },
            aws: { tree: "t", commit: "c", installedAt: "x", dir: "amazon-aws" },
            notion_researcher: { tree: "t", commit: "c", installedAt: "x", dir: "notion_researcher" },
            "../escape": { tree: "t", commit: "c", installedAt: "x" },
            gamma: { tree: "t", commit: "c", installedAt: "x", dir: "../out" },
            beta: { tree: 5 },
        }),
    );
    const installed = await readInstalled(support);
    assert.deepEqual(Object.keys(installed), ["alpha", "aws", "notion_researcher"]);
    assert.equal(installed.alpha?.dir, "alpha", "written before folders were recorded");
    assert.equal(installed.aws?.dir, "amazon-aws");
    await writeFile(path.join(support, "installed.json"), "{ broken");
    assert.deepEqual(await readInstalled(support), {});
    assert.deepEqual(await readInstalled(path.join(support, "missing")), {});
});

// MARK: - Against a real repository (a local bare one, no network)

async function sh(cwd: string, ...args: string[]): Promise<string> {
    const { spawnProgram } = await import("../store-extension/src/git.ts");
    const result = await spawnProgram(
        "/usr/bin/git",
        ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", ...args],
        { cwd, timeout: 30_000 },
    );
    assert.equal(result.code, 0, `git ${args.join(" ")}: ${result.stderr}`);
    return result.stdout;
}

test("clone, list, fetch a README on demand, and see an update after a refresh", async () => {
    const root = await temporary();
    const source = path.join(root, "source");
    const bare = path.join(root, "bare.git");
    await mkdir(source);
    await sh(source, "init", "--quiet", "-b", "main");
    await writeJSON(path.join(source, "extensions/alpha/package.json"), manifest("alpha"));
    await writeFile(path.join(source, "extensions/alpha/README.md"), "# Alpha\n\n![Shot](media/shot.png)\n");
    await writeFile(path.join(source, "extensions/alpha/src.ts"), "export {};\n");
    await writeJSON(path.join(source, "extensions/beta/package.json"), manifest("beta"));
    await sh(source, "add", "-A");
    await sh(source, "commit", "--quiet", "-m", "one");
    await sh(root, "clone", "--quiet", "--bare", source, bare);
    await sh(bare, "config", "uploadpack.allowFilter", "true");
    await sh(bare, "config", "uploadpack.allowAnySHA1InWant", "true");

    const repo = new StoreRepository(path.join(root, "support/repo"), { url: `file://${bare}` });
    await repo.clone();
    assert.deepEqual(
        (await readCatalog(repo.path)).map((entry) => entry.name),
        ["alpha", "beta"],
    );
    const readme = path.join(repo.path, "extensions/alpha/README.md");
    await assert.rejects(readFile(readme), "only manifests are checked out");
    await repo.add("/extensions/alpha/README.md");
    assert.match(await readFile(readme, "utf8"), /^# Alpha/);
    await assert.rejects(readFile(path.join(repo.path, "extensions/alpha/src.ts")), "nothing else of it yet");

    const before = await repo.trees();
    const installed = { alpha: { tree: before.get("alpha")!, commit: await repo.commit(), installedAt: "x", dir: "alpha" } };
    assert.equal(status(parseManifest("alpha", manifest("alpha"))!, installed, before), "installed");

    await writeFile(path.join(source, "extensions/alpha/src.ts"), "export const changed = 1;\n");
    await sh(source, "commit", "--quiet", "-am", "two");
    await sh(source, "push", "--quiet", bare, "main");
    await repo.refresh();
    const after = await repo.trees();
    assert.notEqual(after.get("alpha"), before.get("alpha"));
    assert.equal(after.get("beta"), before.get("beta"));
    assert.equal(status(parseManifest("alpha", manifest("alpha"))!, installed, after), "update");
    assert.equal(await repo.commit(), (await sh(source, "rev-parse", "HEAD")).trim());
    assert.equal(await repo.defaultBranch(), "main");
});

test("a detail scan's patterns fetch the source files alone, from the trees' listing, and go again after", async () => {
    const root = await temporary();
    const source = path.join(root, "source");
    const bare = path.join(root, "bare.git");
    await mkdir(path.join(source, "extensions/alpha/src/lib"), { recursive: true });
    await mkdir(path.join(source, "extensions/alpha/assets"), { recursive: true });
    await sh(source, "init", "--quiet", "-b", "main");
    await writeJSON(path.join(source, "extensions/alpha/package.json"), manifest("alpha"));
    await writeFile(path.join(source, "extensions/alpha/src/index.ts"), "export {};\n");
    await writeFile(path.join(source, "extensions/alpha/src/lib/util.tsx"), "export const x = 1;\n");
    await writeFile(path.join(source, "extensions/alpha/src/data.json"), '{"big": "data"}\n');
    await writeFile(path.join(source, "extensions/alpha/assets/icon.png"), "not really a png\n");
    await writeFile(path.join(source, "extensions/alpha/README.md"), "# Alpha\n");
    await sh(source, "add", "-A");
    await sh(source, "commit", "--quiet", "-m", "one");
    await sh(root, "clone", "--quiet", "--bare", source, bare);
    await sh(bare, "config", "uploadpack.allowFilter", "true");
    await sh(bare, "config", "uploadpack.allowAnySHA1InWant", "true");

    const repo = new StoreRepository(path.join(root, "support/repo"), { url: `file://${bare}` });
    await repo.clone();
    /** The paths under extensions/alpha whose contents aren't downloaded, asked without downloading them. */
    const missing = async () => {
        const objects = await sh(repo.path, "rev-list", "--objects", "--missing=print", "HEAD", "--", "extensions/alpha");
        const names = new Map(
            (await sh(repo.path, "ls-tree", "-r", "HEAD", "extensions/alpha")).split("\n").filter(Boolean).map((line) => {
                const [meta, name] = line.split("\t");
                return [meta!.split(" ")[2]!, name!.replace("extensions/alpha/", "")];
            }),
        );
        return objects.split("\n").filter((line) => line.startsWith("?")).map((line) => names.get(line.slice(1))).sort();
    };
    const everything = ["README.md", "assets/icon.png", "src/data.json", "src/index.ts", "src/lib/util.tsx"];
    assert.deepEqual(await missing(), everything);
    const files = await repo.srcFiles("alpha");
    assert.deepEqual(files.map((file) => file.path).sort(), ["data.json", "index.ts", "lib/util.tsx"]);
    for (const file of files) {
        const object = (await sh(repo.path, "rev-parse", `HEAD:extensions/alpha/src/${file.path}`)).trim();
        assert.equal(file.object, object, `${file.path}'s id`);
    }
    assert.deepEqual(
        await repo.missingObjects("alpha"),
        new Set(files.map((file) => file.object)),
        "and none of them is downloaded",
    );
    assert.deepEqual(await missing(), everything, "listing the source downloads nothing");

    await repo.add(...scanPatterns("alpha"));
    assert.deepEqual(await missing(), ["README.md", "assets/icon.png", "src/data.json"], "only the source files came");
    assert.equal(await readFile(path.join(repo.path, "extensions/alpha/src/lib/util.tsx"), "utf8"), "export const x = 1;\n");
    await assert.rejects(readFile(path.join(repo.path, "extensions/alpha/assets/icon.png")));

    await repo.add("/extensions/alpha/README.md");
    await repo.drop(scanPatterns("alpha"));
    assert.deepEqual(
        (await sh(repo.path, "sparse-checkout", "list")).split("\n").filter(Boolean),
        ["/extensions/*/package.json", "/extensions/alpha/README.md"],
        "every other pattern stays",
    );
    await assert.rejects(readFile(path.join(repo.path, "extensions/alpha/src/index.ts")), "the source left the working tree");
    assert.match(await readFile(path.join(repo.path, "extensions/alpha/README.md"), "utf8"), /^# Alpha/);
    await repo.drop(scanPatterns("alpha"));
    assert.equal((await sh(repo.path, "sparse-checkout", "list")).split("\n").filter(Boolean).length, 2, "dropping again changes nothing");
});

/** The files under `extensions/<dir>` whose contents aren't downloaded, asked without downloading them. */
async function notDownloaded(repoPath: string, dir: string): Promise<string[]> {
    const objects = await sh(repoPath, "rev-list", "--objects", "--missing=print", "HEAD", "--", `extensions/${dir}`);
    const names = new Map(
        (await sh(repoPath, "ls-tree", "-r", "HEAD", `extensions/${dir}`)).split("\n").filter(Boolean).map((line) => {
            const [meta, name] = line.split("\t");
            return [meta!.split(" ")[2]!, name!.replace(`extensions/${dir}/`, "")];
        }),
    );
    return objects.split("\n").filter((line) => line.startsWith("?")).map((line) => names.get(line.slice(1))!).sort();
}

/** A partial clone, as the store makes, of a local remote that lets clients filter, as GitHub does. */
async function partialClone(files: Record<string, string | Buffer>) {
    const root = await temporary();
    const source = path.join(root, "source");
    const bare = path.join(root, "bare.git");
    await mkdir(source);
    await sh(source, "init", "--quiet", "-b", "main");
    for (const [name, contents] of Object.entries(files)) {
        await mkdir(path.dirname(path.join(source, name)), { recursive: true });
        await writeFile(path.join(source, name), contents);
    }
    await sh(source, "add", "-A");
    await sh(source, "commit", "--quiet", "-m", "one");
    await sh(root, "clone", "--quiet", "--bare", source, bare);
    // Filters only: protocol v2 takes a tree's id in a `want` with no setting, so a fall back to v0 would fail here.
    await sh(bare, "config", "uploadpack.allowFilter", "true");
    const repo = new StoreRepository(path.join(root, "support/repo"), { url: `file://${bare}` });
    await repo.clone();
    const { context, cli } = await storeContext();
    return { repo, context: { ...context, repo }, cli, root, bare };
}

test("a check downloads no source file over the cap: that folder isn't checked, and its blob never comes", async () => {
    const big = Buffer.alloc(maxScanBytes + 1024, "a");
    const { repo, context, cli } = await partialClone({
        "extensions/big/package.json": JSON.stringify(manifest("big")),
        "extensions/big/src/index.ts": "export {};\n",
        "extensions/big/src/generated.ts": big,
        "extensions/big/assets/icon.png": "not really a png\n",
        "extensions/small/package.json": JSON.stringify(manifest("small")),
        "extensions/small/src/index.ts": "export {};\n",
        "extensions/small/src/data.json": "{}\n",
        "extensions/small/README.md": "# Small\n",
    });
    assert.deepEqual(await notDownloaded(repo.path, "big"), ["assets/icon.png", "src/generated.ts", "src/index.ts"]);

    assert.deepEqual(await checkFolder("big", context, () => false), { notChecked: true });
    assert.deepEqual(
        await notDownloaded(repo.path, "big"),
        ["assets/icon.png", "src/generated.ts"],
        "the file over the cap never came, nor anything outside src/",
    );
    assert.deepEqual(
        (await sh(repo.path, "sparse-checkout", "list")).split("\n").filter(Boolean),
        ["/extensions/*/package.json"],
        "nothing was checked out",
    );
    assert.equal(cli.calls.length, 0, "nor scanned");

    assert.deepEqual(await checkFolder("small", context, () => false), fromReport(supportedScan));
    assert.deepEqual(
        await notDownloaded(repo.path, "small"),
        ["README.md", "src/data.json"],
        "nothing outside src/ came, nor the asset: its index.ts was here already (big's is the same blob), and a missing " +
            "asset alone fetches nothing",
    );
    assert.deepEqual(cli.calls.map((call) => call.args[0]), ["scan"]);
    assert.deepEqual(
        (await sh(repo.path, "sparse-checkout", "list")).split("\n").filter(Boolean),
        ["/extensions/*/package.json"],
        "the scan's patterns went again",
    );
    assert.deepEqual(await notDownloaded(repo.path, "big"), ["assets/icon.png", "src/generated.ts"]);

    // Checked again (a new build of Fudge, say): the source is here already, so nothing is fetched.
    const calls: string[] = [];
    const recording = new StoreRepository(repo.path, {
        run: (program, args, options) => {
            calls.push(args[0]!);
            return spawnProgram(program, args, options);
        },
    });
    assert.deepEqual(await checkFolder("small", { ...context, repo: recording }, () => false), fromReport(supportedScan));
    assert.ok(calls.includes("rev-list") && !calls.includes("fetch"), `no fetch the second time: ${calls.join(", ")}`);
});

test("only source files decide: an asset over the per-file cap never comes and the row is checked; a small one comes", async () => {
    const big = Buffer.alloc(maxScanBytes + 1024, "a");
    const { repo, context, cli } = await partialClone({
        "extensions/art/package.json": JSON.stringify(manifest("art")),
        "extensions/art/src/index.ts": "export {};\n",
        "extensions/art/src/hero.png": big,
        "extensions/art/src/icon.png": "small\n",
        "extensions/gen/package.json": JSON.stringify(manifest("gen")),
        "extensions/gen/src/index.ts": "export {};\n",
        // The patterns match a folder named like a script too, so its files are checked out with the source.
        "extensions/gen/src/table.js/rows.bin": big,
    });
    const patterns = async () => (await sh(repo.path, "sparse-checkout", "list")).split("\n").filter(Boolean);
    assert.deepEqual(await notDownloaded(repo.path, "art"), ["src/hero.png", "src/icon.png", "src/index.ts"]);

    assert.deepEqual(await checkFolder("art", context, () => false), fromReport(supportedScan));
    assert.deepEqual(
        await notDownloaded(repo.path, "art"),
        ["src/hero.png"],
        "the asset over the cap never came; the small one came with the fetch, and doesn't count",
    );
    assert.deepEqual(cli.calls.map((call) => call.args), [["scan", path.join(repo.path, "extensions/art"), "--json"]]);
    assert.deepEqual(await patterns(), ["/extensions/*/package.json"], "the scan's patterns went again");

    // Checking out a file that isn't here, with the lazy fetch off, would fail: it counts as source, so not checked.
    assert.deepEqual(await checkFolder("gen", context, () => false), { notChecked: true });
    assert.deepEqual(await notDownloaded(repo.path, "gen"), ["src/table.js/rows.bin"]);
    assert.deepEqual(await patterns(), ["/extensions/*/package.json"], "nothing was checked out");
    assert.equal(cli.calls.length, 1, "nor scanned");
});

test("only git's own words for a refused want count as a refusal", () => {
    const tree = "6014216c10952458a5426363594df848e6a3b8b5";
    for (const text of [
        // Protocol v0, a server that allows only its refs' tips in a want.
        `error: git upload-pack: not our ref ${tree}\nfatal: remote error: upload-pack: not our ref ${tree}`,
        // Protocol v0, a server that allows no unadvertised want at all (git's own check, before asking).
        `error: Server does not allow request for unadvertised object ${tree}`,
    ]) {
        assert.ok(isRefusedWant(new GitError(text, "git fetch")), text);
    }
    for (const text of [
        "\ngit stopped after 120 s",
        "fatal: unable to access 'https://github.com/raycast/extensions.git/': Could not resolve host: github.com",
        "fetch-pack: unexpected disconnect while reading sideband packet\nfatal: protocol error: bad pack header",
        "fatal: the remote end hung up unexpectedly",
        "git cancelled",
    ]) {
        assert.ok(!isRefusedWant(new GitError(text, "git fetch")), text);
    }
});

/** The real git runner, recording each call: its arguments, its environment, and how it ended. */
function recording(around: Run = spawnProgram) {
    const calls: { args: string[]; env?: NodeJS.ProcessEnv; code: number; stderr: string }[] = [];
    const run: Run = async (program, args, options) => {
        const result = await around(program, args, options);
        calls.push({ args, env: options.env, code: result.code, stderr: result.stderr });
        return result;
    };
    const steps = () => calls.map((call) => `${call.args.slice(0, 2).join(" ")}${call.env ? " (no lazy fetch)" : ""}`);
    return { run, calls, steps };
}

test("a server that refuses the folder's tree gets the fetch as before: each source file by its id, whatever its size", async () => {
    // Real git on protocol v0, against a server that allows only its refs' tips: it refuses the tree with "not our
    // ref", and the check takes the fetch as before. That server refuses the source files' ids too, so it fails.
    const refusing = await partialClone({
        "extensions/small/package.json": JSON.stringify(manifest("small")),
        "extensions/small/src/index.ts": "export {};\n",
    });
    await sh(refusing.bare, "config", "uploadpack.allowTipSHA1InWant", "true");
    await sh(refusing.repo.path, "config", "protocol.version", "0");
    const v0 = recording();
    await assert.rejects(
        checkFolder("small", { ...refusing.context, repo: new StoreRepository(refusing.repo.path, { run: v0.run }) }, () => false),
        /not our ref/,
    );
    const fetch = v0.calls.find((call) => call.args[0] === "fetch")!;
    assert.match(fetch.stderr, /not our ref/, "git's own refusal");
    assert.deepEqual(
        v0.steps().filter((step) => step.startsWith("fetch") || step.startsWith("sparse-checkout")),
        ["fetch --refetch", "sparse-checkout add"],
        "the fetch as before (the checkout with the lazy fetch on) came after the refusal",
    );

    // On a server that sends source files by their ids (protocol v2) but, here, refuses the tree as v0's would.
    const big = Buffer.alloc(maxScanBytes + 1024, "a");
    const { repo, context, cli } = await partialClone({
        "extensions/art/package.json": JSON.stringify(manifest("art")),
        "extensions/art/src/index.ts": "export const art = 1;\n",
        "extensions/art/src/logo.png": "an asset\n",
        "extensions/huge/package.json": JSON.stringify(manifest("huge")),
        "extensions/huge/src/index.ts": "export const huge = 1;\n",
        "extensions/huge/src/generated.ts": big,
    });
    const refuseTrees: Run = async (program, args, options) => {
        if (args[0] !== "fetch" || !args.includes("--refetch")) return spawnProgram(program, args, options);
        const tree = args.at(-1)!;
        return { code: 128, stdout: "", stderr: `error: git upload-pack: not our ref ${tree}\nfatal: remote error: upload-pack: not our ref ${tree}` };
    };
    const v2 = recording(refuseTrees);
    const refused = { ...context, repo: new StoreRepository(repo.path, { run: v2.run }) };
    assert.deepEqual(await checkFolder("art", refused, () => false), fromReport(supportedScan));
    assert.deepEqual(await notDownloaded(repo.path, "art"), ["src/logo.png"], "only the source file came, not the asset");
    assert.ok(v2.steps().includes("sparse-checkout add"), "with the lazy fetch on");

    // A source file over the per-file cap comes all the same, and the total's check makes the row "Not checked".
    assert.deepEqual(await checkFolder("huge", refused, () => false), { notChecked: true });
    assert.deepEqual(await notDownloaded(repo.path, "huge"), [], "every source file came, whatever its size");
    assert.equal(cli.calls.length, 1, "huge wasn't scanned");
    assert.deepEqual(
        (await sh(repo.path, "sparse-checkout", "list")).split("\n").filter(Boolean),
        ["/extensions/*/package.json"],
        "the scan's patterns went again",
    );
});

test("any other failure of the tree fetch fails the check: no fetch as before, nothing more downloaded", async () => {
    const { repo, context, cli, root } = await partialClone({
        "extensions/small/package.json": JSON.stringify(manifest("small")),
        "extensions/small/src/index.ts": "export {};\n",
        "extensions/small/src/data.json": "{}\n",
    });
    const patterns = async () => (await sh(repo.path, "sparse-checkout", "list")).split("\n").filter(Boolean);
    const unchanged = async (why: string, calls: ReturnType<typeof recording>) => {
        assert.deepEqual(
            calls.steps().filter((step) => step.startsWith("fetch") || step.startsWith("sparse-checkout")),
            ["fetch --refetch"],
            `${why}: no checkout, and no fetch as before`,
        );
        assert.deepEqual(await notDownloaded(repo.path, "small"), ["src/data.json", "src/index.ts"], `${why}: nothing came`);
        assert.deepEqual(await patterns(), ["/extensions/*/package.json"], `${why}: nothing checked out`);
        assert.deepEqual(await locks(repo.path), [], `${why}: no lock left`);
        assert.equal(cli.calls.length, 0, `${why}: not scanned`);
    };

    // A timeout: a remote that takes 30 s to answer, and a fetch given half a second.
    await sh(repo.path, "config", "remote.origin.uploadpack", "sleep 30; git-upload-pack");
    const slow = recording((program, args, options) =>
        spawnProgram(program, args, args[0] === "fetch" ? { ...options, timeout: 500 } : options),
    );
    const started = Date.now();
    await assert.rejects(
        checkFolder("small", { ...context, repo: new StoreRepository(repo.path, { run: slow.run }) }, () => false, new AbortController().signal),
        /git stopped after 0\.5 s/,
    );
    assert.ok(Date.now() - started < 10_000, `the check ended with the fetch (${Date.now() - started} ms)`);
    await unchanged("a timeout", slow);
    await sh(repo.path, "config", "--unset", "remote.origin.uploadpack");

    // A remote that can't be reached.
    await sh(repo.path, "config", "remote.origin.url", `file://${path.join(root, "nowhere.git")}`);
    const unreachable = recording();
    await assert.rejects(
        checkFolder("small", { ...context, repo: new StoreRepository(repo.path, { run: unreachable.run }) }, () => false),
        /Could not read from remote repository/,
    );
    await unchanged("an unreachable remote", unreachable);
});

/** Every `*.lock` file under the copy's `.git`: a git ended while writing leaves one, and later git calls then fail. */
async function locks(repoPath: string): Promise<string[]> {
    const found: string[] = [];
    const walk = async (folder: string) => {
        for (const entry of await readdir(folder, { withFileTypes: true })) {
            const target = path.join(folder, entry.name);
            if (entry.isDirectory()) await walk(target);
            else if (entry.name.endsWith(".lock")) found.push(path.relative(repoPath, target));
        }
    };
    await walk(path.join(repoPath, ".git"));
    return found;
}

test("cancelling a check at each step ends only the download, leaves no lock, and the next check and an install work", async () => {
    const { repo, context, cli } = await partialClone({
        "extensions/small/package.json": JSON.stringify(manifest("small")),
        "extensions/small/src/index.ts": "export {};\n",
    });
    const patterns = async () => (await sh(repo.path, "sparse-checkout", "list")).split("\n").filter(Boolean);
    const settledState = async (step: string, scans = 0) => {
        assert.deepEqual(await locks(repo.path), [], `${step}: no lock left`);
        await sh(repo.path, "status", "--porcelain");
        assert.deepEqual(await patterns(), ["/extensions/*/package.json"], `${step}: nothing stays checked out`);
        assert.equal(cli.calls.length, scans, `${step}: scanned ${scans} times`);
    };

    // During the download: a remote that takes 30 s to answer, and a cancel after half a second.
    await sh(repo.path, "config", "remote.origin.uploadpack", "sleep 30; git-upload-pack");
    const controller = new AbortController();
    const started = Date.now();
    const during = checkFolder("small", context, () => controller.signal.aborted, controller.signal);
    setTimeout(() => controller.abort(), 500);
    assert.equal(await during, undefined);
    assert.ok(Date.now() - started < 500 + cancelGrace + 2000, `the fetch ended within the grace period (${Date.now() - started} ms)`);
    await settledState("during the fetch");
    await sh(repo.path, "config", "--unset", "remote.origin.uploadpack");

    // While a step that writes the index runs (MUST 2): the checkout of the fetched source, and taking its patterns out
    // again. The cancel's real signal is aborted as the step starts, with its git already running, and that git must
    // still run to its end: ended, it would leave `index.lock` for every later checkout and install. So every git the
    // check ran exits 0, including the steps after the cancel.
    for (const [step, expected, scans] of [
        ["sparse-checkout add", undefined, 0],
        ["sparse-checkout set", fromReport(supportedScan), 1],
    ] as const) {
        const controller = new AbortController();
        const exits: { command: string; code: number }[] = [];
        const run: Run = async (program, args, options) => {
            // `spawnProgram` starts the program before it returns, so the abort lands while it runs.
            const running = spawnProgram(program, args, options);
            const command = args.slice(0, 2).join(" ");
            if (command === step) controller.abort();
            const result = await running;
            exits.push({ command, code: result.code });
            return result;
        };
        const stepped = new StoreRepository(repo.path, { run });
        assert.deepEqual(
            await checkFolder("small", { ...context, repo: stepped }, () => controller.signal.aborted, controller.signal),
            expected,
            `cancelled during ${step}`,
        );
        assert.ok(controller.signal.aborted, `${step}: the cancel came`);
        assert.ok(exits.some((exit) => exit.command === step), `${step}: ran`);
        assert.deepEqual(
            exits.filter((exit) => exit.code !== 0),
            [],
            `${step}: every git ran to its end, the one the cancel landed in and those after it`,
        );
        await settledState(`during ${step}`, scans);
    }

    assert.deepEqual(await checkFolder("small", context, () => false), fromReport(supportedScan), "the next check works");
    assert.deepEqual(await install(parseManifest("small", manifest("small"))!, context), {}, "and an install");
    assert.deepEqual(await locks(repo.path), []);
});

test("a default branch name is used only when it's a plain branch name", async () => {
    for (const name of ["main", "master", "release/2026", "v1.2", "dev_branch", "a+b"]) assert.ok(isValidBranch(name), name);
    for (const name of [
        "",
        "-c",
        "--upload-pack=x",
        ".hidden",
        "a/.b",
        "a..b",
        "a//b",
        "a/",
        "/a",
        "a.",
        "a.lock",
        "a/b.lock/c",
        "a b",
        "a:b",
        "a~1",
        "a^",
        "a?",
        "a*",
        "a[b",
        "a\\b",
        "@{-1}",
        "a\nb",
    ]) {
        assert.ok(!isValidBranch(name), JSON.stringify(name));
    }
    const { run, calls } = fakeRun((_program, args) => (args[0] === "symbolic-ref" ? { stdout: "origin/--upload-pack=x\n" } : {}));
    const repo = new StoreRepository(await temporary(), { run });
    await assert.rejects(repo.refresh(), /default branch it can't use: "--upload-pack=x"/);
    assert.deepEqual(
        calls.map((call) => call.args[0]),
        ["symbolic-ref"],
        "nothing is fetched with it",
    );
});

test("refreshing many times keeps the copy one commit deep: only the newest commit is reachable or kept", async () => {
    const root = await temporary();
    const source = path.join(root, "source");
    const bare = path.join(root, "bare.git");
    await mkdir(source);
    await sh(source, "init", "--quiet", "-b", "main");
    await writeJSON(path.join(source, "extensions/alpha/package.json"), manifest("alpha"));
    await writeFile(path.join(source, "extensions/alpha/README.md"), "# Alpha\n");
    await sh(source, "add", "-A");
    await sh(source, "commit", "--quiet", "-m", "one");
    await sh(source, "tag", "v1");
    await sh(root, "clone", "--quiet", "--bare", source, bare);
    await sh(bare, "config", "uploadpack.allowFilter", "true");
    await sh(bare, "config", "uploadpack.allowAnySHA1InWant", "true");

    const repo = new StoreRepository(path.join(root, "support/repo"), { url: `file://${bare}` });
    await repo.clone();
    const commits = [(await sh(source, "rev-parse", "HEAD")).trim()];
    for (const round of [2, 3, 4]) {
        await writeJSON(path.join(source, "extensions/alpha/package.json"), { ...manifest("alpha"), version: `${round}.0.0` });
        await sh(source, "commit", "--quiet", "-am", `round ${round}`);
        await sh(source, "push", "--quiet", bare, "main");
        await repo.refresh();
        commits.push((await sh(source, "rev-parse", "HEAD")).trim());
    }
    const newest = commits.at(-1)!;
    assert.equal(await repo.commit(), newest);
    assert.deepEqual((await sh(repo.path, "rev-list", "--all")).trim().split("\n"), [newest], "from every ref");
    assert.equal((await sh(repo.path, "reflog", "--all")).trim(), "", "no reflog keeps an old commit");
    assert.deepEqual(
        (await sh(repo.path, "for-each-ref", "--format=%(refname)")).trim().split("\n").sort(),
        ["refs/heads/main", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"],
        "the clone's tag and any other ref are gone",
    );
    assert.equal(
        (await readFile(path.join(repo.path, ".git/shallow"), "utf8")).trim(),
        newest,
        ".git/shallow names only the newest commit",
    );
    // Only the objects stored here, so nothing is fetched from the remote to answer.
    const stored = await sh(repo.path, "cat-file", "--batch-all-objects", "--batch-check=%(objectname)");
    for (const old of commits.slice(0, -1)) assert.ok(!stored.includes(old), `${old} was deleted`);
    const packs = (await readdir(path.join(repo.path, ".git/objects/pack"))).filter((file) => file.endsWith(".pack"));
    assert.equal(packs.length, 1, "one pack");
    assert.ok(
        (await readdir(path.join(repo.path, ".git/objects/pack"))).includes(packs[0]!.replace(/\.pack$/, ".promisor")),
        "kept as the remote's, so files it leaves out are still fetched on demand",
    );
    await repo.add("/extensions/alpha/README.md");
    assert.equal(await readFile(path.join(repo.path, "extensions/alpha/README.md"), "utf8"), "# Alpha\n");
    assert.equal(await repo.defaultBranch(), "main");
    assert.equal(
        JSON.parse(await readFile(path.join(repo.path, "extensions/alpha/package.json"), "utf8")).version,
        "4.0.0",
        "the newest manifest is checked out",
    );
});

// MARK: - Regular files only

test("the store reads regular files only: links, FIFOs, folders and big files are refused", async () => {
    const folder = await temporary();
    await writeFile(path.join(folder, "README.md"), "# Fine\n");
    await symlink("/dev/zero", path.join(folder, "zero.md"));
    assert.equal(spawnSync("/usr/bin/mkfifo", [path.join(folder, "fifo.md")]).status, 0);
    await mkdir(path.join(folder, "dir.md"));
    await writeFile(path.join(folder, "big.md"), "x".repeat(maxReadmeBytes + 1));
    assert.equal(await readRegularFile(path.join(folder, "README.md"), maxReadmeBytes), "# Fine\n");
    const started = Date.now();
    for (const name of ["zero.md", "fifo.md", "dir.md", "big.md", "missing.md"]) {
        await assert.rejects(readRegularFile(path.join(folder, name), maxReadmeBytes), name);
    }
    assert.ok(Date.now() - started < 2_000, "nothing is waited on");
});

test("a linked package.json leaves the list, and a linked or missing file fails the package-source check", async () => {
    const repo = await temporary();
    await writeJSON(path.join(repo, "extensions/alpha/package.json"), manifest("alpha"));
    await mkdir(path.join(repo, "extensions/beta"), { recursive: true });
    await symlink("/dev/zero", path.join(repo, "extensions/beta/package.json"));
    assert.deepEqual(
        (await readCatalog(repo)).map((entry) => entry.name),
        ["alpha"],
    );

    const source = await temporary();
    await writeJSON(path.join(source, "package.json"), manifest("gamma"));
    await symlink("/dev/zero", path.join(source, "package-lock.json"));
    assert.equal(await sourceProblem(source), "Its package-lock.json isn't a regular file of at most 50 MB");
    const linkedManifest = await temporary();
    await symlink(path.join(source, "package.json"), path.join(linkedManifest, "package.json"));
    assert.equal(await sourceProblem(linkedManifest), "Its package.json isn't a regular file of at most 1 MB");
    assert.equal(await sourceProblem(await temporary()), "It has no package.json");
});

// MARK: - What the install turns off is what's said (SPEC-121 §2)

/** A scan that says alpha's one command, Run, uses Raycast AI. */
const runUsesAI = {
    extension: "alpha",
    supported: false,
    gaps: [{ api: "AI.ask", kind: "missing", byDesign: "AI" }],
    unreadable: [],
    commands: [{ name: "run", unsupported: ["AI"], traced: true }],
};

test("the build found AI commands the store's failed scan couldn't name: the done message names them", async () => {
    const { context, asked } = await storeContext({ scan: { code: 1, stdout: "" }, built: { commands: { run: ["AI"] } } });
    assert.deepEqual(await install(alphaEntry, context), {
        note: "Turned off: Run, which uses Raycast AI. You can turn it on in Settings → Commands.",
    });
    assert.match(asked[0]!.message, /Fudge couldn't check what this extension uses\.$/);
});

test("the store's scan named AI commands but the build's failed: the done message says every command is on", async () => {
    const { context, asked } = await storeContext({ scan: { stdout: JSON.stringify(runUsesAI) } });
    assert.deepEqual(await install(alphaEntry, context), {
        note: "Fudge couldn't check which of its commands use Raycast AI, so every command is on.",
    });
    assert.match(asked[0]!.message, /Not compatible with Fudge: every command uses Raycast AI/);
});

test("when the build turns off what the confirmation named, the done message adds nothing", async () => {
    const agree = await storeContext({ scan: { stdout: JSON.stringify(runUsesAI) }, built: { commands: { run: ["AI"] } } });
    assert.deepEqual(await install(alphaEntry, agree.context), {});
    const none = await storeContext({ built: { commands: {} } });
    assert.deepEqual(await install(alphaEntry, none.context), {}, "nothing named, nothing off");
    const neither = await storeContext({ scan: { code: 1, stdout: "" } });
    assert.deepEqual(await install(alphaEntry, neither.context), {}, "neither could check: the confirmation said so");
});

test("installNote names what's really on and off, in each case", () => {
    const named = (...using: string[]): Compatibility => ({
        notSupported: ["AI"],
        missing: [],
        signsIn: false,
        signsInThroughRaycast: false,
        unreadable: false,
        byCommand: { count: 3, using },
    });
    const titles = (name: string) => name.replace(/^./, (c) => c.toUpperCase());
    assert.equal(installNote(named("ask"), { ask: ["AI"] }, titles), undefined);
    assert.equal(installNote(undefined, {}, titles), undefined);
    assert.equal(installNote({ notChecked: true }, undefined, titles), undefined);
    assert.equal(
        installNote(named("ask"), { ask: ["AI"], tabs: ["Browser Extension"] }, titles),
        "Turned off: Ask and Tabs, which use Raycast AI or the Raycast Browser Extension. You can turn them on in " +
            "Settings → Commands.",
    );
    assert.equal(installNote(named("ask"), {}, titles), "Every command is on: none of them uses Raycast AI.");
    assert.equal(
        installNote(named("ask", "summarize"), undefined, titles),
        "Fudge couldn't check which of its commands use Raycast AI, so every command is on.",
    );
    // A result from before per-command scans names no command, so whatever the build turned off is named.
    const whole: Compatibility = { notSupported: ["AI"], missing: [], signsIn: false, signsInThroughRaycast: false, unreadable: false };
    assert.equal(
        installNote(whole, { ask: ["AI"] }, titles),
        "Turned off: Ask, which uses Raycast AI. You can turn it on in Settings → Commands.",
    );
});

test("a finished install or update leaves a Success toast, with the note when there is one (SPEC-130)", () => {
    const note = "Turned off: Ask, which uses Raycast AI. You can turn it on in Settings → Commands.";
    assert.deepEqual(doneToast("Jira", false, {}), { title: "Installed Jira" });
    assert.deepEqual(doneToast("Jira", false, { note }), { title: "Installed Jira", message: note });
    assert.deepEqual(doneToast("Jira", true, {}), { title: "Updated Jira" });
    assert.deepEqual(doneToast("Jira", true, { note }), { title: "Updated Jira", message: note });
});

test("the store never closes Fudge's window: no showHUD, closeMainWindow or popToRoot in its source (SPEC-130)", async () => {
    // Any mention of the names, not only a named import, so every way of reaching them counts, comments included.
    const closers = (text: string) => [...text.matchAll(/\b(showHUD|closeMainWindow|popToRoot)\b/g)].map((match) => match[1]);
    for (const [form, text] of [
        ["named", 'import { Toast, showHUD } from "@raycast/api";'],
        ["renamed", 'import { closeMainWindow as close } from "@raycast/api";'],
        ["namespace", 'import * as api from "@raycast/api";\nawait api.popToRoot();'],
        ["require", 'require("@raycast/api").showHUD("Installed");'],
        ["dynamic import", '(await import("@raycast/api")).closeMainWindow();'],
        ["by key", 'api["popToRoot"]();'],
    ]) {
        assert.equal(closers(text).length, 1, form);
    }
    const source = path.join(import.meta.dirname, "../store-extension/src");
    const files = (await readdir(source, { recursive: true })).filter((name) => /\.tsx?$/.test(name));
    assert.ok(files.includes("extension-store.tsx") && files.includes("failure-view.tsx"), "the store's views are read");
    const found: string[] = [];
    for (const name of files) {
        for (const closer of closers(await readFile(path.join(source, name), "utf8"))) found.push(`${name}: ${closer}`);
    }
    assert.deepEqual(found, [], "each of these closes the launcher in Raycast and in Fudge");
});

test("the install's compatibility.json is read as the app reads it", async () => {
    const installed = await temporary();
    assert.equal(await builtCompatibility(installed, ["ask"]), undefined, "no file: the build couldn't check");
    await writeJSON(path.join(installed, "compatibility.json"), {
        commands: { ask: ["AI", "Telepathy"], gone: ["AI"], plain: [], odd: "AI" },
    });
    assert.deepEqual(await builtCompatibility(installed, ["ask", "plain", "odd"]), { ask: ["AI"] }, "manifest commands only");
    await writeFile(path.join(installed, "compatibility.json"), "not json");
    assert.equal(await builtCompatibility(installed, ["ask"]), undefined);
    const linked = await temporary();
    await writeJSON(path.join(linked, "real.json"), { commands: { ask: ["AI"] } });
    await symlink(path.join(linked, "real.json"), path.join(linked, "compatibility.json"));
    assert.equal(await builtCompatibility(linked, ["ask"]), undefined, "never through a link");
});

// MARK: - One install of an extension at a time (SPEC-153)

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** `read` once it stops throwing, or its last error after `limit` ms. */
async function waitFor<T>(read: () => Promise<T>, limit = 10_000): Promise<T> {
    const end = Date.now() + limit;
    for (;;) {
        try {
            return await read();
        } catch (error) {
            if (Date.now() > end) throw error;
            await delay(10);
        }
    }
}

/** `promise`, or a failure saying `what` after `limit` ms: a deadlock fails the test instead of hanging it. */
async function within<T>(promise: Promise<T>, what: string, limit = 10_000): Promise<T> {
    let timer: NodeJS.Timeout | undefined;
    const late = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${what}: still waiting after ${limit} ms`)), limit);
    });
    try {
        return await Promise.race([promise, late]);
    } finally {
        clearTimeout(timer);
    }
}

/** A view for `installPressed` that writes down what the user would see. */
function pressView() {
    const shown: string[] = [];
    const failures: string[] = [];
    const view: InstallView = {
        toast: async (title) => {
            shown.push(`toast: ${title}`);
            return {
                hide: async () => void shown.push("hidden"),
                done: (title, message) => void shown.push(`done: ${title}${message ? ` (${message})` : ""}`),
                failed: (title, message) => void shown.push(`failed: ${title} (${message})`),
            };
        },
        load: async () => void shown.push("loaded"),
        failed: (title) => void failures.push(title),
    };
    return { view, shown, failures };
}

/** Holds every `fudge build` of `context` until `release`, and lists them. */
function gatedBuilds(context: StoreContext) {
    const run = context.run!;
    const builds: string[] = [];
    let release = () => {};
    const gate = new Promise<void>((resolve) => (release = resolve));
    context.run = async (program, args, options) => {
        if (args[0] === "build") {
            builds.push(path.basename(args[1]!));
            await gate;
        }
        return run(program, args, options);
    };
    return { builds, release: () => release() };
}

/** The view's `runInstall` (extension-store.tsx): one press per name, each in the queue. */
function pressing(context: StoreContext, view: InstallView, presses = new InstallPresses()) {
    return (entry: StoreEntry, updating: boolean) =>
        presses.press(entry.name, updating, () => oneAtATime(() => installPressed(entry, updating, context, view)));
}

test("a second press on a name that's installing does nothing; a press on another name waits its turn", async () => {
    const { context, supportPath } = await storeContext({ folders: [{ dir: "beta", name: "beta", tree: "bbb1" }] });
    const beta = parseManifest("beta", manifest("beta"))!;
    const gated = gatedBuilds(context);
    const { view, shown, failures } = pressView();
    let changes = 0;
    const presses = new InstallPresses(() => changes++);
    const press = pressing(context, view, presses);

    const first = press(alphaEntry, false);
    let second: Promise<void> | undefined;
    try {
        assert.equal(presses.state("alpha"), "installing");
        // Install again, ⌘U Update and Try Again all go through the same press: none of them shows a toast or queues.
        await within(Promise.all([press(alphaEntry, false), press(alphaEntry, true), press(alphaEntry, false)]), "ignored presses");
        second = press(beta, false);
        assert.equal(presses.state("beta"), "installing", "its row says so while it waits");
        await waitFor(async () => assert.deepEqual(gated.builds, ["alpha"]));
        await settle();
        assert.deepEqual(gated.builds, ["alpha"], "one build, and beta waits its turn");
        assert.deepEqual(shown, ["toast: Installing Alpha…"], "one toast");
    } finally {
        // Released whatever happened, so a failure here can't leave the store's queue stuck for the tests after it.
        gated.release();
    }
    await within(Promise.all([first, second]), "the presses");
    assert.deepEqual(gated.builds, ["alpha", "beta"]);
    assert.deepEqual(shown, [
        "toast: Installing Alpha…",
        "loaded",
        "done: Installed Alpha",
        "toast: Installing Beta…",
        "loaded",
        "done: Installed Beta",
    ]);
    assert.deepEqual(failures, []);
    assert.equal(presses.state("alpha"), undefined, "the name is free once the press has ended, after the load");
    assert.equal(presses.state("beta"), undefined);
    assert.equal(changes, 4, "drawn again when each name starts and stops");
    assert.deepEqual(Object.keys(await readInstalled(supportPath)).sort(), ["alpha", "beta"]);
});

test("two ⌘U presses run one update, and two Try Agains one install", async () => {
    const updating = await storeContext({ tree: "bbb2" });
    await writeInstalled(updating.supportPath, { alpha: { tree: "aaa1", commit: "old", installedAt: "x", dir: "alpha" } });
    await mkdir(path.join(updating.extensionsDir, "alpha"));
    const gated = gatedBuilds(updating.context);
    const shown = pressView();
    const press = pressing(updating.context, shown.view);
    const first = press(alphaEntry, true);
    try {
        await within(press(alphaEntry, true), "the second ⌘U");
    } finally {
        gated.release();
    }
    await within(first, "the update");
    assert.deepEqual(gated.builds, ["alpha"]);
    assert.deepEqual(shown.shown, ["toast: Updating Alpha…", "loaded", "done: Updated Alpha"]);

    // The first build fails; the failure view's Try Again, pressed twice, runs one more.
    let builds = 0;
    const failing = await storeContext({ build: () => ({ code: builds++ === 0 ? 1 : 0, stderr: "error: esbuild failed" }) });
    const again = pressView();
    const retry = pressing(failing.context, again.view);
    await within(retry(alphaEntry, false), "the failed install");
    assert.deepEqual(again.failures, ["Couldn't install Alpha"]);
    const gatedRetry = gatedBuilds(failing.context);
    const tried = retry(alphaEntry, false);
    try {
        await within(retry(alphaEntry, false), "the second Try Again");
    } finally {
        gatedRetry.release();
    }
    await within(tried, "Try Again");
    assert.equal(builds, 2);
    assert.deepEqual(again.shown, [
        "toast: Installing Alpha…",
        "failed: Couldn't install Alpha (See the details.)",
        "toast: Installing Alpha…",
        "loaded",
        "done: Installed Alpha",
    ]);
});

test("while a name installs, every row of that name says so and offers no Install, Update or Uninstall", async () => {
    const tags = (busy?: "installing" | "updating", state: "available" | "installed" | "update" = "installed") =>
        accessoryTexts(alphaEntry, state, "Partly compatible", busy).filter((accessory) => "tag" in accessory);
    assert.deepEqual(tags(), [{ tag: "Partly compatible" }, { tag: "Installed" }]);
    assert.deepEqual(tags("installing", "available"), [{ tag: "Partly compatible" }, { tag: "Installing…" }]);
    assert.deepEqual(tags("updating"), [{ tag: "Partly compatible" }, { tag: "Updating…" }], "in place of Installed");
    assert.deepEqual(tags("updating", "update"), [{ tag: "Partly compatible" }, { tag: "Updating…" }], "and of Update available");

    assert.deepEqual(rowActions("available"), { install: true, update: false, uninstall: false });
    assert.deepEqual(rowActions("installed"), { install: false, update: false, uninstall: true });
    assert.deepEqual(rowActions("update"), { install: false, update: true, uninstall: true });
    for (const state of ["available", "installed", "update"] as const) {
        for (const busy of ["installing", "updating"] as const) {
            assert.deepEqual(rowActions(state, busy), { install: false, update: false, uninstall: false }, `${state}, ${busy}`);
        }
    }

    // The key is the manifest name, so a second folder with the same name is busy too.
    const presses = new InstallPresses();
    let finish = () => {};
    const pressed = presses.press("alpha", false, () => new Promise<void>((resolve) => (finish = resolve)));
    const twin = parseManifest("alpha-two", manifest("alpha"))!;
    assert.equal(presses.state(twin.name), "installing");
    finish();
    await pressed;

    // A name a build from another session is installing: a press does nothing.
    const elsewhere = new InstallPresses(() => {}, (name) => name === "alpha");
    let ran = false;
    await elsewhere.press("alpha", false, async () => void (ran = true));
    assert.equal(ran, false);
    assert.equal(elsewhere.state("alpha"), undefined);
});

test("fudge build's status for another build running is the app's: one fixture pins both", async () => {
    const statuses = JSON.parse(await readFile(new URL("./fixtures/build-statuses.json", import.meta.url), "utf8")) as {
        alreadyBuilding: number;
    };
    assert.equal(statuses.alreadyBuilding, alreadyBuildingStatus);
});

test("a build that exits 75 says the extension is already being installed: no failure view, no log, nothing written", async () => {
    const { context, supportPath } = await storeContext({ build: () => ({ code: 75, stderr: "fudge: another fudge build is installing alpha" }) });
    const lines: string[] = [];
    context.log = (line) => void lines.push(line);
    await assert.rejects(install(alphaEntry, context), (error: unknown) => error instanceof AlreadyBuilding);
    const { view, shown, failures } = pressView();
    await installPressed(alphaEntry, false, context, view);
    assert.deepEqual(shown, ["toast: Installing Alpha…", "done: Alpha is already being installed"]);
    assert.deepEqual(failures, [], "no failure view, and nothing in Fudge.log");
    assert.deepEqual(lines, []);
    assert.deepEqual(await readInstalled(supportPath), {});

    // The second run, after a swift: import the check missed, is read the same way.
    let runs = 0;
    const retried = await storeContext({
        build: () =>
            runs++ === 0
                ? { code: 1, stderr: `✘ [ERROR] ${chooseSwiftPartsMessage} [plugin swift]\n\n    src/index.ts:1:20:` }
                : { code: 75 },
    });
    retried.context.chooseSwiftParts = async () => "leave-out";
    await assert.rejects(install(alphaEntry, retried.context), (error: unknown) => error instanceof AlreadyBuilding);
    assert.equal(runs, 2);
});

test("each build is recorded in installing/<pid>.json while it runs, and the record goes however the run ends", async () => {
    const endings: [string, Partial<GitResult>][] = [
        ["success", { code: 0 }],
        ["failure", { code: 1, stderr: "error: esbuild failed" }],
        ["timeout", { code: 143, stderr: "\nfudge stopped after 600 s" }],
        ["refusal", { code: 75, stderr: "fudge: another fudge build is installing alpha" }],
    ];
    for (const [ending, result] of endings) {
        const { context, supportPath, extensionsDir, repoPath } = await storeContext();
        const own = new Set<number>();
        context.ownBuilds = own;
        const run = context.run!;
        let recorded: unknown;
        context.run = async (program, args, options) => {
            if (args[0] !== "build") return run(program, args, options);
            options.started?.(4242);
            recorded = await waitFor(async () => JSON.parse(await readFile(path.join(supportPath, "installing/4242.json"), "utf8")));
            return { stdout: "", stderr: "", code: 0, ...result };
        };
        const outcome = await install(alphaEntry, context).then(
            () => "installed",
            (error: unknown) => (error instanceof AlreadyBuilding ? "already" : "failed"),
        );
        assert.equal(outcome, { success: "installed", failure: "failed", timeout: "failed", refusal: "already" }[ending]);
        assert.deepEqual(
            recorded,
            {
                pid: 4242,
                name: "alpha",
                dir: "alpha",
                title: "Alpha",
                tree: "aaa1",
                commit: "c0ffee1234",
                updating: false,
                startedAt: "2026-11-20T12:00:00.000Z",
                deadline: "2026-11-20T12:10:00.000Z",
                command: [context.cli, "build", path.join(repoPath, "extensions/alpha"), "--into", extensionsDir],
            },
            ending,
        );
        assert.deepEqual(await readdir(installingFolder(supportPath)), [], `${ending}: the record is gone`);
        assert.ok(own.has(4242), "it's this session's build");
    }
});

test("a record is removed only once its write has settled, so a run that ends at once leaves none", async () => {
    const { context, supportPath } = await storeContext({ build: () => ({ code: 75 }) });
    let written = false;
    context.buildRecords = {
        write: async (support, record) => {
            await delay(200);
            await writeBuildRecord(support, record);
            written = true;
        },
        remove: removeBuildRecord,
    };
    const run = context.run!;
    context.run = async (program, args, options) => {
        if (args[0] === "build") options.started?.(4343);
        return run(program, args, options);
    };
    await assert.rejects(install(alphaEntry, context), (error: unknown) => error instanceof AlreadyBuilding);
    assert.equal(written, true, "the install waited for the write");
    await delay(300);
    assert.deepEqual(await readdir(installingFolder(supportPath)), [], "and then removed it");
});

test("only a program that started calls started, with its pid", async () => {
    let called = false;
    const failed = await spawnProgram("/nonexistent/fudge", ["build"], { timeout: 5000, started: () => void (called = true) });
    assert.equal(failed.code, -1);
    assert.equal(called, false, "a spawn that fails never calls started");
    let pid: number | undefined;
    const ran = await spawnProgram("/usr/bin/true", [], { timeout: 5000, started: (started) => void (pid = started) });
    assert.equal(ran.code, 0);
    assert.ok(Number.isSafeInteger(pid) && pid! > 0);
    // One that throws can't change the run.
    const thrown = await spawnProgram("/usr/bin/true", [], {
        timeout: 5000,
        started: () => {
            throw new Error("boom");
        },
    });
    assert.equal(thrown.code, 0);
});

test("a record that can't be written or removed is logged, and the install ends as it would have", async () => {
    const rejections: unknown[] = [];
    const rejected = (reason: unknown) => void rejections.push(reason);
    process.on("unhandledRejection", rejected);
    try {
        const failingWrite = async () => {
            throw new Error("disk full");
        };
        const failingRemove = async () => {
            throw new Error("read-only");
        };
        for (const [failing, files, cliCode] of [
            ["write", { write: failingWrite, remove: removeBuildRecord }, 0],
            ["remove", { write: writeBuildRecord, remove: failingRemove }, 0],
            ["write, failed build", { write: failingWrite, remove: removeBuildRecord }, 1],
            ["remove, failed build", { write: writeBuildRecord, remove: failingRemove }, 1],
        ] as const) {
            const { context, supportPath } = await storeContext({ cliCode });
            const lines: string[] = [];
            context.log = (line) => void lines.push(line);
            context.buildRecords = files;
            const run = context.run!;
            context.run = async (program, args, options) => {
                if (args[0] === "build") options.started?.(5151);
                return run(program, args, options);
            };
            if (cliCode === 0) {
                assert.deepEqual(await install(alphaEntry, context), {}, failing);
                assert.equal((await readInstalled(supportPath)).alpha?.tree, "aaa1", failing);
            } else {
                await assert.rejects(install(alphaEntry, context), /esbuild failed/, failing);
                assert.deepEqual(await readInstalled(supportPath), {}, failing);
            }
            assert.deepEqual(
                lines,
                [failing.startsWith("write") ? "Couldn't record the build of Alpha: disk full" : "Couldn't remove the record of Alpha's build: read-only"],
                failing,
            );
        }
        await settle();
        assert.deepEqual(rejections, []);
    } finally {
        process.off("unhandledRejection", rejected);
    }
});

/** A record of another session's build of alpha, started a minute ago, with nine minutes left. */
function otherRecord(overrides: Partial<BuildRecord> = {}): BuildRecord {
    const start = Date.now() - 60_000;
    return {
        pid: 7001,
        name: "alpha",
        dir: "alpha",
        title: "Alpha",
        tree: "t-new",
        commit: "c-new",
        updating: false,
        startedAt: new Date(start).toISOString(),
        deadline: new Date(start + 600_000).toISOString(),
        command: ["/Applications/Fudge.app/Contents/Helpers/fudge", "build", "/repo/extensions/alpha", "--into", "/Users/someone/Library/Application Support/Fudge/extensions"],
        ...overrides,
    };
}

/** Processes as the checks see them: each live pid with its `ps` line, and the signals sent. */
function fakeProbe() {
    const processes = new Map<number, ProcessState>();
    const signalled: number[] = [];
    const probe: ProcessProbe = {
        alive: (pid) => processes.has(pid),
        state: async (pid) => processes.get(pid),
        terminate: (pid) => void signalled.push(pid),
    };
    const running = (record: BuildRecord, stat = "S") => processes.set(record.pid, { stat, args: record.command.join(" ") });
    return { probe, processes, signalled, running };
}

/** A store that opens with `records` from another session in `installing/`. */
async function otherSession(records: BuildRecord[], options: { own?: number[]; probe?: ProcessProbe } = {}) {
    const supportPath = await temporary();
    const extensionsDir = await temporary();
    for (const record of records) await writeBuildRecord(supportPath, record);
    const fake = fakeProbe();
    const settled: Settled[] = [];
    const order: string[] = [];
    let clock = () => new Date();
    const builds = new OtherBuilds({
        supportPath,
        extensionsDir,
        probe: options.probe ?? fake.probe,
        own: new Set(options.own ?? []),
        now: () => clock(),
        settled: (outcome) => {
            settled.push(outcome);
            order.push("settled");
        },
    });
    return {
        supportPath,
        extensionsDir,
        builds,
        fake,
        settled,
        order,
        setClock: (next: () => Date) => (clock = next),
        /** Resolves once every record from another session has settled. */
        allSettled: () => within(builds.hold("test", async () => {}), "settling"),
        records: async () => (await readdir(installingFolder(supportPath)).catch(() => [])).filter((name) => !name.startsWith(".")),
    };
}

test("installing/: a write's dot file is skipped, and deleted only once it's an hour old; anything else invalid is deleted", async () => {
    const support = await temporary();
    const folder = installingFolder(support);
    const good = otherRecord({ pid: 101 });
    await writeBuildRecord(support, good);
    await writeFile(path.join(folder, ".202.abcd.tmp"), "{");
    await writeFile(path.join(folder, ".303.abcd.tmp"), "{");
    const hourAgo = new Date(Date.now() - 61 * 60 * 1000);
    await utimes(path.join(folder, ".303.abcd.tmp"), hourAgo, hourAgo);
    const invalid: Record<string, unknown> = {
        "404.json": { ...otherRecord({ pid: 404 }), name: "../etc" },
        "405.json": { ...otherRecord({ pid: 405 }), dir: "a/b" },
        "406.json": otherRecord({ pid: 999 }),
        "407.json": { ...otherRecord({ pid: 407 }), startedAt: "yesterday" },
        "408.json": { ...otherRecord({ pid: 408 }), command: [] },
        "409.json": { ...otherRecord({ pid: 409 }), updating: "no" },
        "0410.json": otherRecord({ pid: 410 }),
        "notes.txt": otherRecord({ pid: 411 }),
    };
    for (const [name, value] of Object.entries(invalid)) await writeFile(path.join(folder, name), JSON.stringify(value));
    await writeFile(path.join(folder, "412.json"), "not json");
    await mkdir(path.join(folder, "413.json"));
    await symlink(path.join(folder, "101.json"), path.join(folder, "414.json"));

    assert.deepEqual(await readBuildRecords(support), [good]);
    assert.deepEqual((await readdir(folder)).sort(), [".202.abcd.tmp", "101.json"]);
    // `load()` and the poll read them the same way: the fresh dot file stays.
    const session = new OtherBuilds({ supportPath: support, extensionsDir: await temporary(), probe: fakeProbe().probe, own: new Set([101]), settled: () => {} });
    await session.check();
    await session.check();
    assert.deepEqual((await readdir(folder)).sort(), [".202.abcd.tmp", "101.json"]);
    assert.equal(parseProcessLine("ZN   <defunct>\n")?.stat, "ZN");
    assert.deepEqual(parseProcessLine("S    /a/fudge build /b --into /c d\n"), { stat: "S", args: "/a/fudge build /b --into /c d" });
});

test("a record whose build still runs: its rows say so, and nothing is written", async () => {
    const record = otherRecord();
    const session = await otherSession([record]);
    session.fake.running(record);
    await session.builds.check();
    assert.equal(session.builds.busy("alpha"), "installing");
    assert.equal(session.builds.busy("beta"), undefined);
    assert.ok(session.builds.pending);
    await settle();
    assert.deepEqual(session.settled, []);
    assert.deepEqual(await session.records(), ["7001.json"]);
    assert.deepEqual(await readInstalled(session.supportPath), {});
    const updating = await otherSession([otherRecord({ updating: true })]);
    updating.fake.running(otherRecord());
    await updating.builds.check();
    assert.equal(updating.builds.busy("alpha"), "updating");
});

test("an ended build is a zombie of the host: a state starting with Z, or <defunct>, has ended, and gets no signal", async () => {
    const past = new Date(Date.now() - 1000).toISOString();
    for (const state of [{ stat: "Z", args: "<defunct>" }, { stat: "ZN" }, { stat: "S", args: "<defunct>" }]) {
        const record = otherRecord({ deadline: past });
        const session = await otherSession([record]);
        session.fake.processes.set(record.pid, { stat: state.stat, args: state.args ?? record.command.join(" ") });
        await session.builds.check();
        await session.allSettled();
        assert.deepEqual(session.settled.map(({ adopted, seen }) => ({ adopted, seen })), [{ adopted: false, seen: false }], state.stat);
        assert.deepEqual(session.fake.signalled, [], `${state.stat}: never signalled, even past its deadline`);
        assert.deepEqual(await session.records(), []);
    }
});

test("an ended build is adopted only when its folder was made between its start and the end bound", async () => {
    // Found ended at open: the end bound is the deadline.
    const record = otherRecord();
    const adopted = await otherSession([record]);
    await mkdir(path.join(adopted.extensionsDir, "alpha"));
    adopted.setClock(() => new Date("2026-11-22T16:00:00.000Z"));
    await adopted.builds.check();
    await adopted.allSettled();
    assert.deepEqual(adopted.settled, [{ record, adopted: true, seen: false }], "settled without a toast");
    assert.deepEqual(await readInstalled(adopted.supportPath), {
        alpha: { tree: "t-new", commit: "c-new", installedAt: "2026-11-22T16:00:00.000Z", dir: "alpha" },
    });
    assert.deepEqual(await adopted.records(), []);

    // Found ended at open, its folder made after the deadline (a build from Terminal, say).
    const start = Date.now() - 2 * 60 * 60 * 1000;
    const late = await otherSession([otherRecord({ startedAt: new Date(start).toISOString(), deadline: new Date(start + 600_000).toISOString() })]);
    await mkdir(path.join(late.extensionsDir, "alpha"));
    await late.builds.check();
    await late.allSettled();
    assert.deepEqual(late.settled.map((outcome) => outcome.adopted), [false]);
    assert.deepEqual(await readInstalled(late.supportPath), {});

    // No folder.
    const none = await otherSession([otherRecord()]);
    await none.builds.check();
    await none.allSettled();
    assert.deepEqual(none.settled.map((outcome) => outcome.adopted), [false]);
    assert.deepEqual(await readInstalled(none.supportPath), {});

    // A failed update leaves the older folder, made before the start; the older entry stays.
    const failed = await otherSession([]);
    await mkdir(path.join(failed.extensionsDir, "alpha"));
    const older = { alpha: { tree: "t-old", commit: "c-old", installedAt: "x", dir: "alpha" } };
    await writeInstalled(failed.supportPath, older);
    await delay(20);
    const started = Date.now();
    await writeBuildRecord(failed.supportPath, otherRecord({ updating: true, startedAt: new Date(started).toISOString(), deadline: new Date(started + 600_000).toISOString() }));
    await failed.builds.check();
    await failed.allSettled();
    assert.deepEqual(failed.settled.map((outcome) => outcome.adopted), [false]);
    assert.deepEqual(await readInstalled(failed.supportPath), older);

    // No tree: the store couldn't have recorded it.
    const treeless = await otherSession([otherRecord({ tree: undefined })]);
    await mkdir(path.join(treeless.extensionsDir, "alpha"));
    await treeless.builds.check();
    await treeless.allSettled();
    assert.deepEqual(treeless.settled.map((outcome) => outcome.adopted), [false]);
});

test("a build seen ending while the store is open: the end bound is that moment", async () => {
    // Its folder made before the poll saw it end: adopted, with a toast.
    const record = otherRecord();
    const seen = await otherSession([record]);
    seen.fake.running(record);
    await seen.builds.check();
    await mkdir(path.join(seen.extensionsDir, "alpha"));
    seen.fake.processes.delete(record.pid);
    await seen.builds.check();
    await seen.allSettled();
    assert.deepEqual(seen.settled.map(({ adopted, seen }) => ({ adopted, seen })), [{ adopted: true, seen: true }]);

    // Its folder made after the moment the poll saw it end (a clock 30 s behind, so the folder is there when the record
    // settles, and still after that moment): dropped, `installed.json` unchanged, though it's before the deadline.
    const after = await otherSession([record]);
    after.fake.running(record);
    await after.builds.check();
    await mkdir(path.join(after.extensionsDir, "alpha"));
    after.fake.processes.delete(record.pid);
    after.setClock(() => new Date(Date.now() - 30_000));
    await after.builds.check();
    await after.allSettled();
    assert.deepEqual(after.settled.map(({ adopted, seen }) => ({ adopted, seen })), [{ adopted: false, seen: true }]);
    assert.deepEqual(await readInstalled(after.supportPath), {});

    assert.deepEqual(settledToast({ record, adopted: true, seen: true }), { failed: false, title: "Installed Alpha" });
    assert.deepEqual(settledToast({ record: { ...record, updating: true }, adopted: true, seen: true }), { failed: false, title: "Updated Alpha" });
    assert.deepEqual(settledToast({ record, adopted: false, seen: true }), {
        failed: true,
        title: "Couldn't install Alpha",
        message: "Its build stopped before it finished. Try again to see the error.",
    });
});

test("a pid kill(pid, 0) can't find has ended, whatever ps says; EPERM and ESRCH both mean it isn't the store's", async () => {
    const record = otherRecord();
    const fake = fakeProbe();
    fake.running(record);
    assert.equal(await stillRunning(record, fake.probe), true);
    assert.equal(await stillRunning(record, { ...fake.probe, alive: () => false }), false);
    const real = systemProbe();
    assert.equal(real.alive(process.pid), true);
    assert.equal(real.alive(1), false, "launchd, another user's process: EPERM");
    const gone = spawn("/usr/bin/true", [], { stdio: "ignore" });
    await once(gone, "exit");
    assert.equal(real.alive(gone.pid!), false, "an ended, reaped child: ESRCH");
    assert.equal(await real.state(gone.pid!), undefined, "and ps lists nothing for it");
});

test("a reused pid isn't the build: it has ended, and its process is never signalled", async () => {
    const record = otherRecord({ deadline: new Date(Date.now() - 1000).toISOString() });
    const session = await otherSession([record]);
    session.fake.processes.set(record.pid, { stat: "S", args: "/usr/bin/vim notes.txt" });
    await mkdir(path.join(session.extensionsDir, "alpha"));
    await session.builds.check();
    await session.allSettled();
    assert.equal(session.settled.length, 1);
    assert.deepEqual(session.fake.signalled, []);
});

test("a build still running past its deadline gets SIGTERM, once, and no other process does", async () => {
    const late = otherRecord({ deadline: new Date(Date.now() - 1000).toISOString() });
    const onTime = otherRecord({ pid: 7002, name: "beta", dir: "beta", title: "Beta" });
    const reused = otherRecord({ pid: 7003, name: "gamma", dir: "gamma", title: "Gamma", deadline: late.deadline });
    const session = await otherSession([late, onTime, reused]);
    session.fake.running(late);
    session.fake.running(onTime);
    session.fake.processes.set(reused.pid, { stat: "S", args: "/bin/sleep 100" });
    await session.builds.check();
    await session.builds.check();
    assert.deepEqual(session.fake.signalled, [late.pid]);
    session.fake.processes.delete(late.pid);
    await session.builds.check();
    assert.deepEqual(session.fake.signalled, [late.pid]);
});

test("this session's own records are never settled by its poll", async () => {
    const record = otherRecord();
    const session = await otherSession([record], { own: [record.pid] });
    await session.builds.check();
    await settle();
    assert.deepEqual(session.settled, []);
    assert.equal(session.builds.busy("alpha"), undefined);
    assert.deepEqual(await session.records(), ["7001.json"]);
});

test("the poll checks every 2 seconds while a build from another session is pending, and stops when the store goes", async () => {
    let tick: (() => void) | undefined;
    const cleared: unknown[] = [];
    const timers = {
        setInterval: ((run: () => void, ms: number) => {
            assert.equal(ms, pollInterval);
            tick = run;
            return 1;
        }) as unknown as typeof setInterval,
        clearInterval: ((handle: unknown) => void cleared.push(handle)) as unknown as typeof clearInterval,
    };
    const record = otherRecord();
    const supportPath = await temporary();
    await writeBuildRecord(supportPath, record);
    const fake = fakeProbe();
    fake.running(record);
    const builds = new OtherBuilds({ supportPath, extensionsDir: await temporary(), probe: fake.probe, own: new Set(), timers, settled: () => {} });
    builds.start();
    assert.equal(pollInterval, 2000);
    await builds.check();
    fake.processes.delete(record.pid);
    tick!();
    await waitFor(async () => assert.equal(builds.pending, false));
    builds.stop();
    assert.deepEqual(cleared, [1]);
});

test("the real checks: a running child of the test's own, then an ended one nobody reaps", async () => {
    const probe = systemProbe();
    const command = [process.execPath, "-e", "setTimeout(() => {}, 60000)"];
    const child = spawn(command[0]!, command.slice(1), { stdio: "ignore" });
    const exited = once(child, "exit");
    const running = otherRecord({ pid: child.pid!, command });
    try {
        await waitFor(async () => assert.equal(await stillRunning(running, probe), true));
    } finally {
        process.kill(child.pid!, "SIGTERM");
    }
    await exited;
    assert.equal(await stillRunning(running, probe), false);

    // A perl that forks a child which exits at once, and never waits for it: the child is a zombie, as an orphaned build
    // is of the host. `kill(pid, 0)` still finds it, and the checks say it has ended.
    const perl = spawn("/usr/bin/perl", ["-e", 'my $p = fork(); if ($p == 0) { exit 0 } $| = 1; print "$p\\n"; sleep 600'], {
        stdio: ["ignore", "pipe", "ignore"],
    });
    try {
        const [data] = (await once(perl.stdout!, "data")) as [Buffer];
        const zombie = Number(data.toString().trim());
        await waitFor(async () => assert.match((await probe.state(zombie))?.stat ?? "", /^Z/));
        assert.equal(probe.alive(zombie), true);
        const record = otherRecord({ pid: zombie, command: ["/usr/bin/perl", "-e", "fork"], deadline: new Date(Date.now() - 1000).toISOString() });
        assert.equal(await stillRunning(record, probe), false);
        const signalled: number[] = [];
        const session = await otherSession([record], { probe: { ...probe, terminate: (pid) => void signalled.push(pid) } });
        await session.builds.check();
        await session.allSettled();
        assert.equal(session.settled.length, 1);
        assert.deepEqual(signalled, [], "no signal to the zombie, even past its deadline");
    } finally {
        process.kill(perl.pid!, "SIGTERM");
    }
});

test("a refresh waits outside the queue while another session's build runs, then runs once after it settles", async () => {
    const record = otherRecord();
    const session = await otherSession([record]);
    session.fake.running(record);
    await session.builds.check();
    const order = session.order;
    // ⌘R twice, and the day-old refresh on open.
    const refresh = () => heldRefresh(session.builds, async () => void order.push("refresh"));
    const held = [refresh(), refresh(), refresh()];
    // A README fetch, a compatibility check, an install and an uninstall go on meanwhile.
    await within(oneAtATime(async () => void order.push("readme")), "a README fetch");
    await within(oneAtATime(async () => void order.push("check")), "a compatibility check");
    assert.deepEqual(order, ["readme", "check"], "the refresh didn't touch repo/ or enter the queue");
    assert.equal(heldRefreshMessage(session.builds.records()), "The list updates when Alpha has installed");
    assert.equal(heldRefreshMessage([record, { ...record, pid: 2 }]), "The list updates when the installs have finished");
    assert.equal(heldRefreshMessage([{ ...record, updating: true }]), "The list updates when Alpha has updated");

    session.fake.processes.delete(record.pid);
    await session.builds.check();
    await within(Promise.all(held), "the held refresh, with no deadlock");
    assert.deepEqual(order, ["readme", "check", "settled", "refresh"], "the record settles first, then the refresh runs once");
    // Nothing pending: a refresh runs at once.
    await within(refresh(), "a refresh with nothing pending");
    assert.deepEqual(order.at(-1), "refresh");
});

test("a copy that can't be read: the records come first, so its removal waits for a running build", async () => {
    const record = otherRecord();
    const session = await otherSession([record]);
    session.fake.running(record);
    const order = session.order;
    const opening = openCopy(false, {
        others: session.builds,
        exists: async () => true,
        load: async () => {
            order.push("load failed");
            throw new Error("the copy can't be read");
        },
        remove: async () => void order.push("remove"),
        refresh: () => heldRefresh(session.builds, async () => void order.push("refresh")),
        needsRefresh: async () => false,
    });
    await waitFor(async () => assert.deepEqual(order, ["load failed"]));
    await settle();
    assert.deepEqual(order, ["load failed"], "the removal waits");
    assert.equal(session.builds.busy("alpha"), "installing", "the record was read before the copy");
    session.fake.processes.delete(record.pid);
    await session.builds.check();
    await within(opening, "the removal and the clone after it");
    assert.deepEqual(order, ["load failed", "settled", "remove", "refresh"]);

    // The day-old refresh waits too, and an open with nothing pending goes on at once.
    const quiet = await otherSession([]);
    await within(
        openCopy(false, {
            others: quiet.builds,
            exists: async () => true,
            load: async () => void quiet.order.push("loaded"),
            remove: async () => void quiet.order.push("remove"),
            refresh: () => heldRefresh(quiet.builds, async () => void quiet.order.push("refresh")),
            needsRefresh: async () => true,
        }),
        "an open with nothing pending",
    );
    assert.deepEqual(quiet.order, ["loaded", "refresh"]);
});
