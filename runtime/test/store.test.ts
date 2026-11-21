import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
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
    searchKeywords,
    sections,
    status,
    type StoreEntry,
} from "../store-extension/src/catalog.ts";
import {
    checkFolder,
    compatibilityFile,
    compatibilityLine,
    compatibilityText,
    CompatibilityChecks,
    fromReport,
    isNotCompatible,
    maxCachedResults,
    maxScanBytes,
    maxScanFiles,
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
    spawnProgram,
    stopRunningGit,
    storeEnvironment,
    StoreRepository,
    type GitResult,
    type Run,
} from "../store-extension/src/git.ts";
import {
    detailMarkdown,
    filterImages,
    imageSource,
    isGitHubImage,
    rendererPass,
} from "../store-extension/src/readme.ts";
import {
    caseClash,
    lockfileProblem,
    packageJSONProblem,
    sourceProblem,
    specProblem,
} from "../store-extension/src/sources.ts";
import {
    buildArguments,
    bundledNames,
    failureDetails,
    install,
    oneAtATime,
    readInstalled,
    StoreError,
    uninstall,
    writeInstalled,
    type StoreContext,
} from "../store-extension/src/store.ts";

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
    const calls: { program: string; args: string[]; cwd?: string; timeout: number; stoppable?: boolean; input?: string }[] = [];
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
    const present = fakeRun();
    assert.equal(await gitAvailable(present.run), true);
    assert.deepEqual(
        present.calls.map((call) => [call.program, ...call.args]),
        [
            ["/usr/bin/xcode-select", "-p"],
            ["/usr/bin/git", "--version"],
        ],
    );
    const broken = fakeRun((program) => (program.endsWith("git") ? { code: 1, stderr: "xcrun: error: invalid active developer path" } : {}));
    assert.equal(await gitAvailable(broken.run), false);
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
    const git = fakeRun((_program, args) => {
        if (args[0] === "rev-parse") return { stdout: "c0ffee1234\n" };
        if (args[0] === "ls-tree" && args.includes("-r")) {
            const prefix = args.at(-1)!;
            const dir = /^extensions\/([^/]+)\/src\/$/.exec(prefix)![1]!;
            return { stdout: (options.sources?.[dir] ?? []).map((file) => `${prefix}${file}\0`).join("") };
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
    const cli = fakeRun((_program, args) =>
        args[0] === "scan"
            ? { code: 0, stdout: JSON.stringify(supportedScan), ...options.scan }
            : { code: options.cliCode ?? 0, stderr: options.cliCode ? "error: esbuild failed" : "" },
    );
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
    assert.equal(await install(alphaEntry, context), true);
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

test("a folder whose manifest has another name installs from the folder, under the name, and records both", async () => {
    const { context, git, cli, supportPath, extensionsDir, repoPath } = await storeContext({
        folders: [{ dir: "amazon-aws", name: "aws", tree: "a5a1" }],
    });
    const aws = parseManifest("amazon-aws", manifest("aws", { title: "Amazon AWS" }))!;
    assert.equal(await install(aws, context), true);
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
    assert.equal(await install(first, context), true);
    await mkdir(path.join(extensionsDir, "world-clock"));
    await assert.rejects(install(second, context), (error: unknown) => {
        assert.ok(error instanceof StoreError);
        assert.equal(error.message, "Another extension called world-clock is installed. Uninstall it first.");
        return true;
    });
    await assert.rejects(uninstall(second, context), /wasn't installed by the store/, "nor removed through the other row");
    assert.equal(await install(first, context), true, "updating the first one");
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
    assert.equal(await install(alphaEntry, context), true, "its own folder isn't a clash");
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
    assert.deepEqual(accessoryTexts(gamma, "installed", true), [
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

test("install's confirmation carries the scan's gaps, and a failed scan doesn't stop the install", async () => {
    const report = { extension: "alpha", supported: false, gaps: [{ api: "AI.ask", kind: "missing", byDesign: "AI" }], unreadable: [] };
    const withGaps = await storeContext({ scan: { stdout: JSON.stringify(report) } });
    assert.equal(await install(alphaEntry, withGaps.context), true);
    assert.match(
        withGaps.asked[0]!.message,
        /\n\nNot compatible with Fudge: this extension uses Raycast AI, which Fudge doesn't support\. Commands that use it won't work\.$/,
    );

    for (const scan of [{ code: 1, stdout: "" }, { stdout: "not json" }, { stdout: "{}" }]) {
        const failed = await storeContext({ scan });
        assert.equal(await install(alphaEntry, failed.context), true, JSON.stringify(scan));
        assert.match(failed.asked[0]!.message, /\n\nFudge couldn't check what this extension uses\.$/);
    }
});

// MARK: - Compatibility: the cache, the detail's scan, and install

const treeOf = (n: number) => n.toString(16).padStart(40, "0");
const aiOnly: Compatibility = { notSupported: ["AI"], missing: [], signsIn: false, unreadable: false };

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
        scanner: "s",
        trees: {
            [treeOf(1)]: aiOnly,
            aaa1: aiOnly,
            [treeOf(2)]: { ...aiOnly, missing: ["Clipboard.read", "a b"] },
            [treeOf(3)]: { ...aiOnly, notSupported: ["Telepathy"] },
            [treeOf(4)]: { notSupported: [], missing: [] },
            [treeOf(5)]: "Compatible",
            [treeOf(6)]: { notSupported: [], missing: ["Clipboard.read"], signsIn: true, unreadable: false },
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

test("a detail scan fetches only the folder's source files, scans them, and takes the patterns out again", async () => {
    const report = { extension: "alpha", supported: false, gaps: [{ api: "AI.ask", kind: "missing", byDesign: "AI" }], unreadable: [] };
    const { context, git, cli, repoPath } = await storeContext({
        sources: { alpha: ["index.ts", "lib/util.tsx", "data.json", "logo.png"] },
        scan: { stdout: JSON.stringify(report) },
    });
    assert.deepEqual(await checkFolder("alpha", context, () => false), aiOnly);
    assert.deepEqual(
        git.calls.map((call) => call.args),
        [
            ["ls-tree", "-r", "-z", "--name-only", "HEAD", "--", "extensions/alpha/src/"],
            ["sparse-checkout", "add", ...scanPatterns("alpha")],
            ["sparse-checkout", "list"],
            ["sparse-checkout", "set", "--no-cone", "--stdin"],
        ],
    );
    assert.deepEqual(scanPatterns("alpha"), [
        "/extensions/alpha/src/**/*.ts",
        "/extensions/alpha/src/**/*.tsx",
        "/extensions/alpha/src/**/*.js",
        "/extensions/alpha/src/**/*.jsx",
    ]);
    assert.equal(git.calls[3]!.input, "/extensions/*/package.json\n", "only the scan's own patterns go");
    assert.deepEqual(cli.calls.map((call) => call.args), [["scan", path.join(repoPath, "extensions/alpha"), "--json"]]);
});

test("past the caps a row isn't checked: too many source files fetches nothing, too many bytes scans nothing", async () => {
    const many = Array.from({ length: maxScanFiles + 1 }, (_, n) => `file${n}.ts`);
    const counted = await storeContext({ sources: { alpha: [...many, "a.png", "b.json"] } });
    assert.deepEqual(await checkFolder("alpha", counted.context, () => false), { notChecked: true });
    assert.deepEqual(counted.git.calls.map((call) => call.args[0]), ["ls-tree"], "nothing fetched");
    assert.deepEqual(counted.cli.calls, []);
    const atCap = await storeContext({ sources: { alpha: [...many.slice(1), "a.png"] } });
    await checkFolder("alpha", atCap.context, () => false);
    assert.equal(atCap.cli.calls.length, 1, "exactly the cap, and other files, are fine");

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
    assert.deepEqual(await done, ["row7", { notSupported: [], missing: [], signsIn: false, unreadable: false }]);
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

test("install uses this version's cached result instead of scanning, and caches its own scan", async () => {
    const tree = treeOf(42);
    const cached = await storeContext({ tree });
    await rememberCompatibility(cached.supportPath, await scannerIdentity(cached.context.cli), tree, aiOnly);
    assert.equal(await install(alphaEntry, cached.context), true);
    assert.deepEqual(cached.cli.calls.map((call) => call.args[0]), ["build"], "no scan");
    assert.match(cached.asked[0]!.message, /Not compatible with Fudge: this extension uses Raycast AI/);

    const notChecked = await storeContext({ tree });
    await rememberCompatibility(notChecked.supportPath, await scannerIdentity(notChecked.context.cli), tree, { notChecked: true });
    assert.equal(await install(alphaEntry, notChecked.context), true);
    assert.deepEqual(notChecked.cli.calls.map((call) => call.args[0]), ["scan", "build"], "too big to check while browsing: installing scans");

    const fresh = await storeContext({ tree });
    assert.equal(await install(alphaEntry, fresh.context), true);
    assert.deepEqual(
        (await readCompatibility(fresh.supportPath, await scannerIdentity(fresh.context.cli))).get(tree),
        { notSupported: [], missing: [], signsIn: false, unreadable: false },
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
    assert.deepEqual((await repo.sourceFiles("alpha")).sort(), ["data.json", "index.ts", "lib/util.tsx"]);
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
