import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { environment, getSelectedFinderItems, getSelectedText } from "../src/api/index.ts";
import { createApiModule } from "../src/api/module.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";

let calls: RpcRequest[] = [];

/** A fake app that answers each call on the next tick, with a result or an error message. */
function answer(reply: (method: string) => { result?: unknown; error?: string }): void {
    calls = [];
    connect((request) => {
        calls.push(request);
        const { result, error } = reply(request.method);
        setImmediate(() => settle(request.id, result ?? null, error));
    });
}
afterEach(() => connect(null));

test("getSelectedText resolves with the app's text", async () => {
    answer(() => ({ result: "selected words" }));
    assert.equal(await getSelectedText(), "selected words");
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [["selection.text", null]],
    );
});

test("getSelectedText rejects with the app's message", async () => {
    for (const message of [
        "Unable to get selected text from frontmost application",
        "fudge needs Accessibility permission to read the selected text. Allow fudge in System Settings → Privacy & Security → Accessibility.",
    ]) {
        answer(() => ({ error: message }));
        await assert.rejects(getSelectedText(), (error: Error) => error instanceof Error && error.message === message);
    }
});

test("getSelectedFinderItems resolves with the paths in Finder's order", async () => {
    answer(() => ({ result: [{ path: "/Users/someone/b.txt" }, { path: "/Users/someone/A folder" }] }));
    assert.deepEqual(await getSelectedFinderItems(), [{ path: "/Users/someone/b.txt" }, { path: "/Users/someone/A folder" }]);
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [["selection.finderItems", null]],
    );

    answer(() => ({ result: [] }));
    assert.deepEqual(await getSelectedFinderItems(), []);
});

test("getSelectedFinderItems rejects with the app's message", async () => {
    for (const message of [
        "Finder isn't the frontmost application",
        "fudge needs permission to control Finder. Allow it in System Settings → Privacy & Security → Automation.",
        "Finder didn't answer in time",
    ]) {
        answer(() => ({ error: message }));
        await assert.rejects(getSelectedFinderItems(), (error: Error) => error instanceof Error && error.message === message);
    }
});

test("@raycast/api provides both, not stubs", () => {
    const api = createApiModule();
    assert.equal(environment.canAccess(api.getSelectedText), true);
    assert.equal(environment.canAccess(api.getSelectedFinderItems), true);
});
