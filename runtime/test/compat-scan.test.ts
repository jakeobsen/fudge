import assert from "node:assert/strict";
import { test } from "node:test";
import { createApiModule } from "../src/api/module.ts";
import { apiName, support, toJavaScript, uses } from "../scripts/compat/scan.ts";

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
    const api = createApiModule() as Record<string, unknown>;
    assert.equal(support(api, "Clipboard.copy"), "implemented");
    assert.equal(support(api, "Action.CopyToClipboard"), "implemented");
    assert.equal(support(api, "Toast.Style.Failure"), "implemented");
    assert.equal(support(api, "environment.commandName.length"), "implemented", "past the API, it's the value");
    assert.equal(support(api, "Action.NoSuchAction"), "missing");
    assert.equal(support(api, "AI.ask"), "missing", "a stub");
    assert.equal(support(api, "Clipboard.noSuchFunction"), "missing");
    assert.equal(support(api, "NotARaycastExport"), "unknown");
});

test("names the API a path is about", () => {
    assert.equal(apiName("Clipboard.copy"), "Clipboard.copy");
    assert.equal(apiName("environment.commandName.length"), "environment.commandName");
    assert.equal(apiName("Image.Mask.Circle"), "Image.Mask.Circle");
});
