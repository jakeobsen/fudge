import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import {
    accessoryTexts,
    allFilter,
    categories,
    filterEntries,
    iconURL,
    installedFilter,
    parseManifest,
    readCatalog,
    searchKeywords,
    sections,
    status,
    type StoreEntry,
} from "../store-extension/src/catalog.ts";
import {
    gitAvailable,
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
    compatibilityLine,
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

test("a manifest's name must be valid and equal its folder's", () => {
    assert.equal(parseManifest("alpha", manifest("alpha"))?.name, "alpha");
    assert.equal(parseManifest("alpha", manifest("beta")), undefined, "a mismatched name");
    for (const bad of ["Alpha", "-alpha", "al pha", "../alpha", "alpha/x", "al*pha", "", ".alpha"]) {
        assert.equal(parseManifest(bad, manifest(bad)), undefined, bad);
    }
    assert.equal(parseManifest("alpha", manifest("alpha", { commands: [] })), undefined, "no commands");
    assert.equal(parseManifest("alpha", { ...manifest("alpha"), title: 5 }), undefined, "no title");
    assert.equal(parseManifest("alpha", null), undefined);
});

test("an entry has the manifest's fields, and only a plain icon file name", () => {
    const entry = parseManifest("alpha", manifest("alpha"))!;
    assert.deepEqual(entry, {
        name: "alpha",
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
    await writeJSON(path.join(repo, "extensions/mismatch/package.json"), manifest("other"));
    await writeJSON(path.join(repo, "extensions/Upper/package.json"), manifest("Upper"));
    await writeJSON(path.join(repo, "extensions/empty/package.json"), manifest("empty", { commands: [] }));
    await mkdir(path.join(repo, "extensions/no-manifest"), { recursive: true });
    await writeFile(path.join(repo, "extensions/broken-json"), "");
    await mkdir(path.join(repo, "extensions/broken"), { recursive: true });
    await writeFile(path.join(repo, "extensions/broken/package.json"), "{ not json");
    const entries = await readCatalog(repo);
    assert.deepEqual(
        entries.map((entry) => entry.name),
        ["alpha", "zeta"],
    );
    assert.deepEqual(await readCatalog(path.join(repo, "missing")), []);
});

// MARK: - Rows

const alpha = parseManifest("alpha", manifest("alpha", { categories: ["Productivity", "Developer Tools"] }))!;
const beta = parseManifest("beta", manifest("beta", { author: "", commands: [{ name: "a", title: "A" }, { name: "b", title: "B" }] }))!;
const gamma = parseManifest("gamma", manifest("gamma", { categories: ["Media"] }))!;
const record = (tree: string) => ({ tree, commit: "c1", installedAt: "2026-11-20T00:00:00.000Z" });

test("installed and update come from installed.json and the folder's tree id", () => {
    const trees = new Map([
        ["alpha", "t1"],
        ["beta", "t2-new"],
    ]);
    const installed = { alpha: record("t1"), beta: record("t2") };
    assert.equal(status(alpha, installed, trees), "installed");
    assert.equal(status(beta, installed, trees), "update");
    assert.equal(status(gamma, installed, trees), "available");
});

test("rows show the author, the commands and the state; search includes keywords, author and name", () => {
    assert.deepEqual(accessoryTexts(alpha, "installed"), [{ text: "someone" }, { text: "1 command" }, { tag: "Installed" }]);
    assert.deepEqual(accessoryTexts(beta, "update"), [{ text: "2 commands" }, { tag: "Update available" }]);
    assert.deepEqual(accessoryTexts(gamma, "available"), [{ text: "someone" }, { text: "1 command" }]);
    assert.deepEqual(searchKeywords(alpha), ["word", "someone", "alpha"]);
    assert.deepEqual(searchKeywords(beta), ["word", "beta"]);
});

test("the category and Installed filters, and installed ones first", () => {
    const entries: StoreEntry[] = [gamma, beta, alpha];
    const installed = { gamma: record("t") };
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
    assert.equal((await other).code, 0, "the CLI's build isn't stoppable");
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
    options: { confirm?: boolean; cliCode?: number; tree?: string; scan?: { code?: number; stdout?: string } } = {},
) {
    const root = await temporary();
    const supportPath = path.join(root, "support");
    const extensionsDir = path.join(root, "extensions");
    const repoPath = path.join(supportPath, "repo");
    await mkdir(extensionsDir, { recursive: true });
    await writeJSON(path.join(repoPath, "extensions/alpha/package.json"), manifest("alpha", { dependencies: { a: "^1" } }));
    const git = fakeRun((_program, args) => {
        if (args[0] === "rev-parse") return { stdout: "c0ffee1234\n" };
        if (args[0] === "ls-tree") return { stdout: `040000 tree ${options.tree ?? "aaa1"}\textensions/alpha\n` };
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
    return { context, git, cli, asked, trashed, extensionsDir, supportPath, repoPath };
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
        alpha: { tree: "aaa1", commit: "c0ffee1234", installedAt: "2026-11-20T12:00:00.000Z" },
    });
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
        assert.equal(error.message, "An extension named alpha is already installed (not from the store)");
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
    const { context, supportPath } = await storeContext({ cliCode: 1 });
    await assert.rejects(install(alphaEntry, context), /esbuild failed/);
    assert.deepEqual(await readInstalled(supportPath), {});
});

test("updating an installed extension asks to update and records the new tree", async () => {
    const { context, asked, supportPath, extensionsDir } = await storeContext({ tree: "bbb2" });
    await writeInstalled(supportPath, { alpha: { tree: "aaa1", commit: "old", installedAt: "x" } });
    await mkdir(path.join(extensionsDir, "alpha"));
    assert.equal(await install(alphaEntry, context), true, "its own folder isn't a clash");
    assert.equal(asked[0]!.title, "Update Alpha?");
    assert.equal((await readInstalled(supportPath)).alpha?.tree, "bbb2");
});

test("uninstall trashes only what the store installed, and forgets it", async () => {
    const { context, trashed, supportPath, extensionsDir } = await storeContext();
    await assert.rejects(uninstall(alphaEntry, context), /wasn't installed by the store/);
    await mkdir(path.join(extensionsDir, "alpha"));
    await writeInstalled(supportPath, { alpha: { tree: "t", commit: "c", installedAt: "x" } });
    assert.equal(await uninstall(alphaEntry, context), true);
    assert.deepEqual(trashed, [path.join(extensionsDir, "alpha")]);
    assert.deepEqual(await readInstalled(supportPath), {});
});

test("the confirmation says what the scan found: up to five APIs, and how many more", async () => {
    const gaps = (...apis: string[]) => ({ supported: false, gaps: apis.map((api) => ({ api })), unreadable: [] });
    assert.equal(compatibilityLine(supportedScan), "Fudge supports everything this extension uses.");
    assert.equal(
        compatibilityLine(gaps("MenuBarExtra", "MenuBarExtra.Item", "MenuBarExtra")),
        "This extension uses things Fudge doesn't have yet: MenuBarExtra, MenuBarExtra.Item. Some of its commands may not work.",
    );
    assert.equal(
        compatibilityLine(gaps("A", "B", "C", "D", "E", "F", "G")),
        "This extension uses things Fudge doesn't have yet: A, B, C, D, E, and 2 more. Some of its commands may not work.",
    );
    assert.equal(
        compatibilityLine({ supported: false, gaps: [], unreadable: ["src/a.ts"] }),
        "Fudge couldn't read all of this extension's source, so some of it may not work.",
    );
    assert.equal(compatibilityLine(undefined), "Fudge couldn't check what this extension uses.");
});

test("install's confirmation carries the scan's gaps, and a failed scan doesn't stop the install", async () => {
    const report = { extension: "alpha", supported: false, gaps: [{ api: "AI.ask", kind: "missing", byDesign: "AI" }], unreadable: [] };
    const withGaps = await storeContext({ scan: { stdout: JSON.stringify(report) } });
    assert.equal(await install(alphaEntry, withGaps.context), true);
    assert.match(withGaps.asked[0]!.message, /\n\nThis extension uses things Fudge doesn't have yet: AI\.ask\. Some of its commands may not work\.$/);

    for (const scan of [{ code: 1, stdout: "" }, { stdout: "not json" }, { stdout: "{}" }]) {
        const failed = await storeContext({ scan });
        assert.equal(await install(alphaEntry, failed.context), true, JSON.stringify(scan));
        assert.match(failed.asked[0]!.message, /\n\nFudge couldn't check what this extension uses\.$/);
    }
});

test("installed.json drops invalid names and records; a broken file reads as empty", async () => {
    const support = await temporary();
    await writeFile(
        path.join(support, "installed.json"),
        JSON.stringify({
            alpha: { tree: "t", commit: "c", installedAt: "x" },
            "../escape": { tree: "t", commit: "c", installedAt: "x" },
            beta: { tree: 5 },
        }),
    );
    assert.deepEqual(Object.keys(await readInstalled(support)), ["alpha"]);
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
    const installed = { alpha: { tree: before.get("alpha")!, commit: await repo.commit(), installedAt: "x" } };
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
