import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { bundledPackages, components, markdown, plainText } from "../scripts/notices.ts";

const sample = [
    { name: "Thing", version: "1.2.3", license: "MIT", where: "In `x.js`.", text: "Copyright\r\n\r\nUse it.\n\n" },
    { name: "Data", version: "Emoji 16.0", license: "Unicode-3.0", where: "In the grid.", text: "Has ``` inside\n" },
];

test("each notice has its name, version, place, license and the license file's own text", () => {
    const text = plainText(sample);
    assert.match(text, /^Thing 1\.2\.3$/m);
    assert.match(text, /^In x\.js\. License: MIT\.$/m, "backticks are Markdown's, not the text file's");
    assert.match(text, /^Copyright\n\nUse it\.\n/m, "line endings made \\n, trailing blank lines gone");
    assert.match(text, /^Data \(Emoji 16\.0\)$/m);
});

test("no line of a license can close its Markdown block", () => {
    const md = markdown(sample);
    assert.match(md, /^````text\nHas ``` inside\n````$/m);
    assert.match(md, /^```text\nCopyright\n\nUse it\.\n```$/m);
});

test("every npm package a bundle Fudge ships takes in is listed", async () => {
    const listed = new Set(components.flatMap((component) => (component.package ? [component.package] : [])));
    const bundled = await bundledPackages();
    for (const name of ["react", "react-reconciler", "scheduler"]) assert.ok(bundled.has(name), `${name} is bundled`);
    assert.deepEqual([...bundled].filter((name) => !listed.has(name)), []);
    assert.ok(listed.has("esbuild"), "the esbuild binary in Contents/Helpers isn't in a bundle, but ships");
});

test("the bundled Node.js is listed at the Makefile's version, with the LICENSE `make app` copies beside it", () => {
    const node = components.find((component) => component.name === "Node.js");
    assert.ok(node?.version && typeof node.licenseFile === "function", "Node.js is listed, with its license file's path");
    const makefile = readFileSync(new URL("../../Makefile", import.meta.url), "utf8");
    assert.equal(node.version(), makefile.match(/^NODE_VERSION\s*:?=\s*(\S+)/m)?.[1]);
    assert.match(node.licenseFile(), /\/\.cache\/node\/node-v[^/]+-darwin-[^/]+\/LICENSE$/);
    assert.match(readFileSync(node.licenseFile(), "utf8"), /^Node\.js is licensed for use as follows:/);
});
