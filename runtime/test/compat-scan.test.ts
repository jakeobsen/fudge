import assert from "node:assert/strict";
import { test } from "node:test";
import * as implementation from "../src/api/index.ts";
import { createApiModule } from "../src/api/module.ts";
import { mark, NOT_DRAWN, notAvailable, UNAVAILABLE } from "../src/api/stubs.ts";
import { RAYCAST_UTILS_PATHS } from "../scripts/compat/raycast-utils.generated.ts";
import { category } from "../scripts/compat/extension.ts";
import { apiName, gaps, isExtensionSource, support, toJavaScript, uses } from "../scripts/compat/scan.ts";
import { raycastDeclarations, vendoredTypes } from "../scripts/raycast-types.ts";

const api = createApiModule() as Record<string, unknown>;
const declared = raycastDeclarations(vendoredTypes());

test("finds what a module uses from @raycast/api, however it's imported", async () => {
    const source = `
        import { Clipboard, showToast as toast, type LaunchProps, List } from "@raycast/api";
        import * as raycast from "@raycast/api";
        import { useFetch, showFailureToast } from "@raycast/utils";
        const { launchCommand } = require("@raycast/api");
        export default function Command(props: LaunchProps) {
            Clipboard.copy("x");
            toast({ title: "hi" });
            raycast.environment.supportPath;
            launchCommand({ name: "other" });
            useFetch("https://example.com").data;
            showFailureToast(new Error("x"));
            const accessory: List.Item.Accessory = {};
            return <List><raycast.Action.CopyToClipboard content="" /></List>;
        }
    `;
    const found = uses(await toJavaScript(source, "command.tsx"));
    assert.deepEqual(
        [...found.api].sort(),
        ["Action.CopyToClipboard", "Clipboard.copy", "List", "environment.supportPath", "launchCommand", "showToast"],
        "types (LaunchProps, List.Item.Accessory) don't count",
    );
    assert.deepEqual([...found.utils].sort(), ["showFailureToast", "useFetch"]);
});

test("decides whether fudge provides an API path", () => {
    assert.equal(support(api, "Clipboard.copy"), "implemented");
    assert.equal(support(api, "render", declared), "implemented", "the deprecated top-level render()");
    assert.equal(support(api, "Action.CopyToClipboard"), "implemented");
    assert.equal(support(api, "Toast.Style.Failure"), "implemented");
    assert.equal(support(api, "environment.commandName.length"), "implemented", "past the API, it's the value");
    assert.equal(support(api, "Action.NoSuchAction"), "missing");
    assert.equal(support(api, "AI.ask"), "missing", "a stub");
    assert.equal(support(api, "Clipboard.noSuchFunction"), "missing");
    assert.equal(support(api, "NotARaycastExport"), "not-raycast");
});

test("names the API a path is about", () => {
    assert.equal(apiName("Clipboard.copy"), "Clipboard.copy");
    assert.equal(apiName("environment.commandName.length"), "environment.commandName");
    assert.equal(apiName("Image.Mask.Circle"), "Image.Mask.Circle");
});

test("a stub is missing wherever the path reaches it, lowercase members included", () => {
    // fudge implements every member of its namespaces now, so a small module stands in for one with stubs.
    const partial = { Clipboard: { copy() {}, paste: notAvailable("Clipboard.paste") }, pasteText: notAvailable("pasteText") };
    assert.equal(support(partial, "Clipboard.paste"), "missing", "a stub member of an implemented namespace");
    assert.equal(support(partial, "Clipboard.copy"), "implemented");
    assert.equal(support(partial, "pasteText"), "missing", "an implemented export that is a stub");
    assert.equal(support(api, "BrowserExtension.getTabs"), "missing", "a member of an export fudge leaves out");
    assert.equal(support(api, "environment.commandName"), "implemented", "a getter that needs a running command");
});

test("the deprecated preferences and randomId are implemented", () => {
    assert.equal(support(api, "preferences", declared), "implemented");
    assert.equal(support(api, "randomId", declared), "implemented");
});

test("an extension reading the deprecated preferences record has no gaps", async () => {
    const source = `
        import { preferences, showToast } from "@raycast/api";
        export default async function Command() {
            const key = preferences.apiKey.value as string;
            const { value: region } = preferences.region;
            await showToast({ title: key + String(region) + String(preferences["host"]?.value) });
        }
    `;
    const found = uses(await toJavaScript(source, "command.ts"));
    assert.ok([...found.api].some((path) => path.startsWith("preferences.apiKey")), [...found.api].join(", "));
    assert.equal(support(api, "preferences.apiKey.value", declared), "implemented");
    assert.equal(support(api, "preferences.apiKey", declared), "implemented");
    assert.deepEqual(gaps(found, api, declared, RAYCAST_UTILS_PATHS), { gaps: [], notRaycast: [] });
});

test("OAuth stays left out by design, though its client can be built (D-50)", () => {
    for (const path of ["OAuth", "OAuth.PKCEClient", "OAuth.RedirectMethod.Web", "OAuth.RedirectMethod.AppURI"]) {
        assert.equal(support(api, path, declared), "missing", path);
        assert.equal(category({ api: apiName(path), kind: "missing" }), "OAuth", path);
    }
});

test("an action that renders but fails when used is render-but-fail", () => {
    assert.equal(support(api, "Action.CreateSnippet", declared), "render-but-fail");
    assert.equal(support(api, "Action.CopyToClipboard", declared), "implemented");
    assert.equal(support(api, "Action.CreateQuicklink", declared), "implemented", "the app opens its Create Quicklink form");
    assert.equal(support(api, "Action.ToggleQuickLook", declared), "implemented", "the app performs Quick Look");
    assert.equal(support(api, "Action.Paste", declared), "implemented", "Paste works now");
    for (const path of ["Action.PickDate", "Action.PickDate.Type.DateTime", "Action.PickDate.isFullDay"]) {
        assert.equal(support(api, path, declared), "implemented", `${path} works now`);
    }
});

test("a component the app doesn't draw, and any member of one, is not-drawn", () => {
    // The app draws every component now, so a small marked component stands in for one it doesn't.
    const Thing = Object.assign(() => null, { Item: Object.assign(() => null, { Kind: { Big: "big" } }) });
    mark(Thing, NOT_DRAWN, "Thing");
    for (const path of ["Thing", "Thing.Item", "Thing.Item.Kind.Big"]) {
        assert.equal(support({ Thing }, path), "not-drawn", `${path}: a member of a component that isn't drawn`);
    }
    // The app draws these now, and the old names that reach them too.
    const drawn = [
        ...["Form", "Form.TextField", "Form.Checkbox", "List.Item", "Detail.Metadata.Label"],
        ...["Grid", "Grid.Item", "Grid.Dropdown.Item", "Grid.Inset.Small"],
        ...["Form.Dropdown", "Form.Dropdown.Item", "Form.DropdownItem", "FormDropdownItem", "Form.TagPicker.Item"],
        ...["Form.DatePicker", "Form.DatePicker.Type.Date", "Form.FilePicker", "Form.LinkAccessory"],
    ];
    for (const path of drawn) {
        assert.equal(support(api, path, declared), "implemented", path);
    }
});

/** Every component and constant group in fudge's @raycast/api, by path. */
function components(): Map<string, object> {
    const found = new Map<string, object>();
    const visit = (value: unknown, path: string) => {
        if ((typeof value !== "function" && typeof value !== "object") || value === null || found.has(path)) return;
        found.set(path, value);
        for (const [key, member] of Object.entries(value)) if (/^[A-Z]/.test(key)) visit(member, `${path}.${key}`);
    };
    for (const [name, value] of Object.entries(implementation)) visit(value, name);
    return found;
}

test("no component is both unavailable and not drawn", () => {
    const both = [...components()].filter(([, value]) => NOT_DRAWN in value && UNAVAILABLE in value).map(([path]) => path);
    assert.deepEqual(both, []);
});

test("Raycast's types declare every component fudge implements", () => {
    const undeclared = [...components().keys()].filter((path) => !declared(path));
    assert.deepEqual(undeclared, []);
});

test("paths Raycast doesn't declare are not-raycast, not gaps", () => {
    const paths = ["Color.Gray", "Icon.Safari", "Toast.Style.SuccessMessage", "showToast.mockResolvedValue", "LocalStorage.__reset"];
    for (const path of paths) assert.equal(support(api, path, declared), "not-raycast", path);
    for (const path of ["Toast.Style.Failure", "Keyboard.Shortcut.Common.Copy", "environment.supportPath", "Image.Mask.Circle"]) {
        assert.equal(declared(path), true, path);
    }
    assert.equal(declared("preferences.apiKey"), true, "the old `preferences` is a Record, so any key is declared");
    assert.deepEqual(
        gaps({ api: new Set(["Color.Gray", "Icon.Safari", "Clipboard.copy"]), utils: new Set() }, api, declared, {}),
        { gaps: [], notRaycast: ["Color.Gray", "Icon.Safari"] },
        "an extension with only not-raycast paths has no gaps",
    );
});

test("an extension using a @raycast/utils export inherits its paths", () => {
    const table = {
        useThing: ["WindowManagement.getActiveWindow", "Clipboard.copy", "Color.Gray"],
        useOther: ["WindowManagement.getActiveWindow"],
    };
    assert.deepEqual(gaps({ api: new Set(), utils: new Set(["useThing", "useOther"]) }, api, declared, table).gaps, [
        { api: "WindowManagement.getActiveWindow", kind: "via @raycast/utils", via: ["useOther", "useThing"] },
    ]);
    assert.deepEqual(
        gaps({ api: new Set(["WindowManagement.getActiveWindow"]), utils: new Set(["useThing"]) }, api, declared, table)
            .gaps,
        [{ api: "WindowManagement.getActiveWindow", kind: "missing" }],
        "a direct use counts as direct",
    );
    const oauth = gaps({ api: new Set(), utils: new Set(["OAuthService"]) }, api, declared, RAYCAST_UTILS_PATHS);
    assert.ok(oauth.gaps.some((gap) => gap.api === "OAuth.PKCEClient" && gap.kind === "via @raycast/utils"));
    assert.ok(RAYCAST_UTILS_PATHS.useAI?.includes("AI.ask"));
});

test("tests and mocks aren't extension code", () => {
    for (const path of ["index.tsx", "lib/api.ts", "hooks/useThing.js", "components/List.jsx", "testing.ts", "contest/x.ts"]) {
        assert.equal(isExtensionSource(path), true, path);
    }
    const skipped = [
        "index.test.tsx",
        "api.spec.ts",
        "lib/api.test.js",
        "__mocks__/raycast.ts",
        "__tests__/index.tsx",
        "test/helpers.ts",
        "lib/tests/fixtures.ts",
        "types.d.ts",
        "node_modules/x/index.js",
        "README.md",
    ];
    for (const path of skipped) assert.equal(isExtensionSource(path), false, path);
});
