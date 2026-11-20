import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { raycastExports, render } from "../scripts/raycast-exports.ts";
import * as implementation from "../src/api/index.ts";
import { createApiModule, NotAvailableError } from "../src/api/module.ts";
import { RAYCAST_EXPORTS } from "../src/api/raycast-exports.generated.ts";

test("the generated export list matches the vendored type definitions", () => {
    const types = readFileSync(fileURLToPath(new URL("../vendor/raycast-api/index.d.ts", import.meta.url)), "utf8");
    const generated = readFileSync(fileURLToPath(new URL("../src/api/raycast-exports.generated.ts", import.meta.url)), "utf8");
    assert.equal(generated, render(raycastExports(types)), "run `npm run generate`");
    assert.ok(RAYCAST_EXPORTS.includes("List") && RAYCAST_EXPORTS.includes("showToast"));
});

test("everything fudge implements is part of @raycast/api", () => {
    for (const name of Object.keys(implementation)) {
        assert.ok(RAYCAST_EXPORTS.includes(name), `${name} isn't a @raycast/api export`);
    }
});

test("implemented exports come through unchanged", () => {
    const api = createApiModule();
    assert.equal(api.List, implementation.List);
    assert.equal(api.useNavigation, implementation.useNavigation);
});

test("a missing export throws NotAvailableError naming it when called", () => {
    const api = createApiModule({});
    const showHUD = api.showHUD as () => void;
    assert.throws(showHUD, (error: unknown) => error instanceof NotAvailableError && error.api === "showHUD");
    assert.throws(() => new (api.Cache as new () => object)(), /Cache isn't available in fudge yet/);
});

test("members of a missing export are named in full", () => {
    const api = createApiModule({}) as { Clipboard: { copy(text: string): void } };
    assert.throws(() => api.Clipboard.copy("x"), /^NotAvailableError: Clipboard\.copy isn't available in fudge yet$/);
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
