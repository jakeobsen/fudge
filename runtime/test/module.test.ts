import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { raycastEnums, raycastExports, renderEnums, renderExports, vendoredVersion } from "../scripts/raycast-types.ts";
import * as implementation from "../src/api/index.ts";
import { createApiModule, NotAvailableError } from "../src/api/module.ts";
import { RAYCAST_EXPORTS } from "../src/api/raycast-exports.generated.ts";
import { recordRender } from "../src/api/render.ts";

const read = (path: string) => readFileSync(fileURLToPath(new URL(path, import.meta.url)), "utf8");
const types = read("../vendor/raycast-api/index.d.ts");

test("the generated files match the vendored type definitions", () => {
    assert.equal(read("../src/api/raycast-exports.generated.ts"), renderExports(raycastExports(types), vendoredVersion()), "run `npm run generate`");
    assert.equal(read("../src/api/raycast-enums.generated.ts"), renderEnums(raycastEnums(types)), "run `npm run generate`");
    assert.ok(RAYCAST_EXPORTS.includes("List") && RAYCAST_EXPORTS.includes("showToast"));
});

test("enums carry Raycast's own values", () => {
    assert.equal(Object.keys(implementation.Icon).length, 478);
    assert.equal(implementation.Icon.Trash, "trash-16");
    assert.equal(implementation.Color.SecondaryText, "raycast-secondary-text");
    assert.equal(implementation.LaunchType.UserInitiated, "userInitiated");
    assert.equal(implementation.Action.Style.Destructive, "destructive");
    assert.ok(Object.isFrozen(implementation.Icon));
});

test("enum parsing handles comments and members without a value", () => {
    const parsed = raycastEnums(`declare enum Mixed {\n  /** doc */ A = "a", // note\n  B,\n  C = 5,\n  D\n}`);
    assert.deepEqual(parsed, { Mixed: { A: "a", B: 0, C: 5, D: 6 } });
});

test("everything fudge implements is part of @raycast/api", () => {
    for (const name of Object.keys(implementation)) {
        assert.ok(RAYCAST_EXPORTS.includes(name), `${name} isn't a @raycast/api export`);
    }
});

test("implemented exports keep their behaviour and a stable identity", () => {
    const api = createApiModule() as typeof implementation;
    assert.equal(api.List.displayName, "List");
    assert.equal(api.Action.Style.Destructive, "destructive");
    assert.equal(api.List.Item, api.List.Item, "React needs the same component object on every render");
    assert.equal(createApiModule().List, api.List, "wrappers are shared");
});

test("frozen constants come through the module exactly as they are", () => {
    const api = createApiModule() as typeof implementation;
    assert.deepEqual(api.Keyboard.Shortcut.Common.Refresh, {
        macOS: { modifiers: ["cmd"], key: "r" },
        Windows: { modifiers: ["ctrl"], key: "r" },
    });
    assert.equal(api.Keyboard.Shortcut, implementation.Keyboard.Shortcut);
    assert.equal(api.Icon.Trash, "trash-16");
});

test("a missing member of an implemented component names itself", () => {
    const api = createApiModule() as { Action: Record<string, unknown>; List: { Item: Record<string, unknown> } };
    assert.throws(() => (api.Action.Teleport as () => void)(), /^NotAvailableError: Action\.Teleport isn't available in Fudge yet$/);
    assert.throws(() => (api.List.Item.Accessory as () => void)(), /List\.Item\.Accessory isn't available/);
    assert.equal(api.Action.displayName, "Action", "lowercase members aren't stubbed");
});

test("a missing export throws NotAvailableError naming it when called", () => {
    const api = createApiModule({});
    const showHUD = api.showHUD as () => void;
    assert.throws(showHUD, (error: unknown) => error instanceof NotAvailableError && error.api === "showHUD");
    assert.throws(() => new (api.Cache as new () => object)(), /Cache isn't available in Fudge yet/);
});

test("reading a member of a missing export throws, naming it in full", () => {
    const api = createApiModule({}) as { Clipboard: { copy(text: string): void }; environment: { supportPath: string } };
    assert.throws(() => api.Clipboard.copy("x"), /^NotAvailableError: Clipboard\.copy isn't available in Fudge yet$/);
    assert.throws(() => api.environment.supportPath, /environment\.supportPath isn't available in Fudge yet/);
});

test("stubs don't look like promises or React types", () => {
    const api = createApiModule({}) as Record<string, Record<string, unknown>>;
    assert.equal(api.showToast!.then, undefined);
    assert.equal(api.MenuBarExtra!.$$typeof, undefined);
    assert.equal(api.MenuBarExtra!.prototype, undefined);
});

test("names that @raycast/api doesn't export stay undefined", () => {
    const api = createApiModule({});
    assert.equal(api.notARaycastExport, undefined);
    assert.ok("showToast" in api);
    assert.ok(!("notARaycastExport" in api));
    assert.ok(Object.keys(api).includes("showToast"), "missing exports are enumerable, for esbuild's interop helpers");
});

test("Image.Mask, the old ImageMask, Color.Brown and captureException are there", () => {
    const api = createApiModule() as Record<string, any>;
    assert.equal(api.Image.Mask.Circle, "circle");
    assert.equal(api.Image.Mask.RoundedRectangle, "roundedRectangle");
    assert.deepEqual({ ...api.ImageMask }, { ...api.Image.Mask });
    assert.deepEqual(Object.keys(api.Color.Brown), ["light", "dark"]);
    const errors: unknown[][] = [];
    const original = console.error;
    console.error = (...args: unknown[]) => errors.push(args);
    try {
        api.captureException(new Error("boom"));
    } finally {
        console.error = original;
    }
    assert.equal((errors[0]?.[1] as Error).message, "boom");
});

test("render() outside a command module's load does nothing and doesn't throw", () => {
    const api = createApiModule() as { render: (element: unknown) => unknown };
    assert.equal(api.render({ type: "List" }), undefined);
    // During a load, the first call is recorded; a later load starts afresh, and calls after it count for nothing.
    assert.deepEqual(recordRender(() => api.render("first")), { result: undefined, rendered: { element: "first" } });
    assert.deepEqual(recordRender(() => 1), { result: 1 });
    assert.equal(api.render("late"), undefined);
    assert.deepEqual(recordRender(() => 2), { result: 2 });
});

test("a load that throws still stops recording render() calls", () => {
    assert.throws(() =>
        recordRender(() => {
            throw new Error("broken module");
        }),
    );
    assert.deepEqual(recordRender(() => 3), { result: 3 });
});
