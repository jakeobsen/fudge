import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { createApiModule } from "../src/api/module.ts";
import { WindowManagement } from "../src/api/window-management.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";
import { gaps } from "../scripts/compat/scan.ts";
import { raycastDeclarations, vendoredTypes } from "../scripts/raycast-types.ts";

// WindowManagement (FUD-93) asks the app over rpc; a fake app answers here, so nothing reads or moves a real window.

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

test("WindowManagement has Raycast's four functions and DesktopType", () => {
    const api = createApiModule() as { WindowManagement: typeof WindowManagement };
    for (const name of ["getDesktops", "getActiveWindow", "getWindowsOnActiveDesktop", "setWindowBounds"] as const) {
        assert.equal(typeof api.WindowManagement[name], "function", name);
    }
    assert.deepEqual({ ...api.WindowManagement.DesktopType }, { User: "User", FullScreen: "FullScreen" });
    assert.ok(Object.isFrozen(WindowManagement.DesktopType));
});

test("each function is one rpc, and answers with what the app sent", async () => {
    const window = { id: "11", bounds: "fullscreen", desktopId: "screen-1", active: true };
    answer = (request) => (request.method === "windows.active" ? window : request.method === "windows.setBounds" ? null : []);
    assert.deepEqual(await WindowManagement.getDesktops(), []);
    assert.deepEqual(await WindowManagement.getActiveWindow(), window);
    assert.deepEqual(await WindowManagement.getWindowsOnActiveDesktop(), []);
    assert.equal(await WindowManagement.setWindowBounds({ id: "11", bounds: { position: { x: 100 } } }), undefined);
    await WindowManagement.setWindowBounds({ id: "11", bounds: { size: { width: 640 } }, desktopId: "screen-1" });
    await WindowManagement.setWindowBounds({ id: "12", bounds: "fullscreen" });
    assert.deepEqual(
        calls.map(({ method, params }) => ({ method, params })),
        [
            { method: "windows.desktops", params: null },
            { method: "windows.active", params: null },
            { method: "windows.onActiveDesktop", params: null },
            { method: "windows.setBounds", params: { id: "11", bounds: { position: { x: 100 } } } },
            { method: "windows.setBounds", params: { id: "11", bounds: { size: { width: 640 } }, desktopId: "screen-1" } },
            { method: "windows.setBounds", params: { id: "12", bounds: "fullscreen" } },
        ],
    );
});

test("a refusal from the app rejects with its message", async () => {
    connect((request) => setImmediate(() => settle(request.id, null, "There is no active window")));
    await assert.rejects(WindowManagement.getActiveWindow(), { message: "There is no active window" });
});

test("the compat scan counts WindowManagement as implemented", () => {
    const api = createApiModule() as Record<string, unknown>;
    const declared = raycastDeclarations(vendoredTypes());
    const used = [
        "WindowManagement.getDesktops",
        "WindowManagement.getActiveWindow",
        "WindowManagement.getWindowsOnActiveDesktop",
        "WindowManagement.setWindowBounds",
        "WindowManagement.DesktopType.FullScreen",
    ];
    assert.deepEqual(gaps({ api: new Set(used), utils: new Set() }, api, declared, {}).gaps, []);
});
