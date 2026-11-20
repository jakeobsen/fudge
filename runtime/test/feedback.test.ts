import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { Alert, Toast, closeMainWindow, confirmAlert, popToRoot, showHUD, showToast } from "../src/api/index.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";

let calls: RpcRequest[] = [];
let answer: (request: RpcRequest) => unknown = () => null;

beforeEach(() => {
    calls = [];
    answer = () => null;
    connect((request) => {
        calls.push(request);
        setImmediate(() => settle(request.id, answer(request)));
    });
});
afterEach(() => connect(null));

const flush = () => new Promise((resolve) => setImmediate(resolve));

test("showToast shows a toast; changing it updates it in place", async () => {
    const toast = await showToast({ style: Toast.Style.Animated, title: "Loading" });
    toast.style = Toast.Style.Success;
    toast.title = "Done";
    toast.message = "3 items";
    await flush();
    await toast.hide();
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["toast.show", { id: 1, title: "Loading", message: null, style: "ANIMATED", primaryAction: null, secondaryAction: null }],
            ["toast.show", { id: 1, title: "Loading", message: null, style: "SUCCESS", primaryAction: null, secondaryAction: null }],
            ["toast.show", { id: 1, title: "Done", message: null, style: "SUCCESS", primaryAction: null, secondaryAction: null }],
            ["toast.show", { id: 1, title: "Done", message: "3 items", style: "SUCCESS", primaryAction: null, secondaryAction: null }],
            ["toast.hide", { id: 1 }],
        ],
    );
});

test("a toast that isn't shown changes without calling the app", () => {
    const toast = new Toast({ title: "quiet" });
    toast.title = "still quiet";
    assert.equal(calls.length, 0);
    assert.equal(toast.style, Toast.Style.Success, "Success is the default style");
});

test("the old showToast(style, title, message) form still works", async () => {
    await showToast(Toast.Style.Failure, "Oops", "it broke");
    assert.deepEqual(calls[0]!.params, {
        id: (calls[0]!.params as { id: number }).id,
        title: "Oops",
        message: "it broke",
        style: "FAILURE",
        primaryAction: null,
        secondaryAction: null,
    });
});

test("a toast's actions run when the app says the user picked them", async () => {
    const picked: string[] = [];
    const toast = await showToast({
        title: "Copied",
        primaryAction: { title: "Undo", shortcut: { modifiers: ["cmd"], key: "z" }, onAction: (t) => picked.push(`undo ${t.title}`) },
        secondaryAction: { title: "Open", onAction: () => picked.push("open") },
    });
    const sent = calls[0]!.params as { id: number; primaryAction: object; secondaryAction: object };
    assert.deepEqual(sent.primaryAction, { title: "Undo", shortcut: { modifiers: ["cmd"], key: "z" } });
    assert.deepEqual(sent.secondaryAction, { title: "Open", shortcut: null });
    Toast.runAction(sent.id, "primary");
    Toast.runAction(sent.id, "secondary");
    Toast.runAction(999, "primary");
    assert.deepEqual(picked, ["undo Copied", "open"]);
    await toast.hide();
    Toast.runAction(sent.id, "primary");
    assert.equal(picked.length, 2, "a hidden toast's actions don't run");
});

test("confirmAlert resolves with the user's choice and runs the matching action", async () => {
    const ran: string[] = [];
    const options = {
        title: "Delete?",
        message: "This can't be undone",
        primaryAction: { title: "Delete", style: Alert.ActionStyle.Destructive, onAction: () => ran.push("delete") },
        dismissAction: { title: "Keep", onAction: () => ran.push("keep") },
    };
    answer = () => true;
    assert.equal(await confirmAlert(options), true);
    answer = () => false;
    assert.equal(await confirmAlert(options), false);
    assert.deepEqual(ran, ["delete", "keep"]);
    assert.deepEqual(calls[0]!.params, {
        title: "Delete?",
        message: "This can't be undone",
        icon: null,
        primaryAction: { title: "Delete", style: "destructive" },
        dismissAction: { title: "Keep", style: null },
    });
});

test("showHUD, closeMainWindow and popToRoot ask the app", async () => {
    await showHUD("Copied", { clearRootSearch: true });
    await closeMainWindow({ popToRootType: "immediate" });
    await popToRoot();
    assert.deepEqual(
        calls.map((call) => [call.method, call.params]),
        [
            ["hud.show", { title: "Copied", clearRootSearch: true, popToRootType: "default" }],
            ["window.close", { clearRootSearch: false, popToRootType: "immediate" }],
            ["window.popToRoot", { clearSearchBar: false }],
        ],
    );
});
