import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { placeholderEnvironment, setLaunchContext } from "../src/api/launch.ts";
import { createApiModule } from "../src/api/module.ts";

const folder = mkdtempSync(path.join(tmpdir(), "fudge-deprecated-"));
after(() => rmSync(folder, { recursive: true, force: true }));

const manifest = {
    name: "tools",
    preferences: [
        { name: "host", type: "textfield", required: true, title: "Host", description: "Where it is", placeholder: "example.com" },
        { name: "token", type: "password", required: false, title: "Token", description: "Your token" },
        { name: "mode", type: "dropdown", title: "Mode", description: "Extension-wide", default: "a", data: [{ title: "A", value: "a" }] },
    ],
    commands: [
        {
            name: "run",
            title: "Run",
            mode: "no-view",
            preferences: [
                { name: "verbose", type: "checkbox", title: "Output", description: "More output", label: "Verbose", default: false },
                {
                    name: "mode",
                    type: "dropdown",
                    required: true,
                    title: "Mode",
                    description: "The command's own",
                    default: "b",
                    data: [
                        { title: "A", value: "a" },
                        { title: "B", value: "b" },
                    ],
                },
            ],
        },
        { name: "other", title: "Other", mode: "no-view", preferences: [{ name: "unrelated", type: "textfield", title: "X", description: "" }] },
    ],
};
const manifestFile = path.join(folder, "package.json");
writeFileSync(manifestFile, JSON.stringify(manifest));

/** Sets the launch; `file` null leaves the manifest out. */
function launch(values: Record<string, unknown>, file: string | null = manifestFile) {
    setLaunchContext({
        preferences: values,
        manifestFile: file ?? undefined,
        environment: { ...placeholderEnvironment, extensionName: "tools", commandName: "run", commandMode: "no-view" },
        launchProps: {},
    });
}

test("preferences describes the running command's preferences, with their values", () => {
    // The stored host, the token left unset, the dropdown and checkbox at their defaults.
    launch({ host: "fudge.local", mode: "b", verbose: false });
    const { preferences } = createApiModule() as { preferences: Record<string, Record<string, unknown>> };
    assert.deepEqual(Object.keys(preferences), ["host", "token", "mode", "verbose"], "the extension's, then the command's");
    assert.deepEqual(preferences.host, {
        name: "host",
        type: "textfield",
        required: true,
        title: "Host",
        description: "Where it is",
        value: "fudge.local",
        placeholder: "example.com",
    });
    assert.deepEqual(preferences.token, { name: "token", type: "password", required: false, title: "Token", description: "Your token" });
    assert.deepEqual(preferences.verbose, {
        name: "verbose",
        type: "checkbox",
        required: false,
        title: "Output",
        description: "More output",
        value: false,
        default: false,
        label: "Verbose",
    });
    // The command's own declaration of a name wins over the extension's.
    assert.equal(preferences.mode!.description, "The command's own");
    assert.equal(preferences.mode!.required, true);
    assert.equal(preferences.mode!.value, "b");
    assert.deepEqual(preferences.mode!.data, [
        { title: "A", value: "a" },
        { title: "B", value: "b" },
    ]);
    assert.equal("unrelated" in preferences, false, "another command's preferences aren't there");
    assert.equal(preferences.Missing, undefined, "a name it doesn't have is just undefined");
    assert.deepEqual(JSON.parse(JSON.stringify(preferences)).host.value, "fudge.local");
});

test("preferences follows the launch, and is empty without a manifest", () => {
    const { preferences } = createApiModule() as { preferences: Record<string, Record<string, unknown>> };
    launch({ host: "first" });
    assert.equal(preferences.host!.value, "first");
    launch({ host: "second" });
    assert.equal(preferences.host!.value, "second");
    launch({}, path.join(folder, "missing.json"));
    assert.deepEqual(Object.keys(preferences), []);
    launch({}, null);
    assert.deepEqual(Object.keys(preferences), []);
});

test("randomId returns a random, URL-safe id of 21 characters", () => {
    const { randomId } = createApiModule() as { randomId: (size?: number) => string };
    const ids = Array.from({ length: 200 }, () => randomId());
    for (const id of ids) assert.match(id, /^[A-Za-z0-9_-]{21}$/);
    assert.equal(new Set(ids).size, ids.length, "no two alike");
    assert.match(randomId(8), /^[A-Za-z0-9_-]{8}$/);
});
