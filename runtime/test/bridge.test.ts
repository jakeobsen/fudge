import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { callApp, connect, settle, type RpcRequest } from "../src/bridge.ts";

afterEach(() => connect(null));

test("a call is sent with an id and resolves with the app's answer", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const answer = callApp<string>("clipboard.read", { offset: 0 });
    assert.equal(sent.length, 1);
    assert.deepEqual({ ...sent[0], id: 0 }, { type: "rpc", id: 0, method: "clipboard.read", params: { offset: 0 } });
    settle(sent[0]!.id, "hello");
    assert.equal(await answer, "hello");
});

test("an error from the app rejects the call", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const answer = callApp("alert.confirm");
    settle(sent[0]!.id, undefined, "the user closed the window");
    await assert.rejects(answer, /the user closed the window/);
});

test("calls fail cleanly when the bridge isn't connected", async () => {
    await assert.rejects(callApp("toast.show"), /toast\.show: not connected to the Fudge app/);
});

test("answers for unknown ids are ignored", () => {
    settle(123456, "nobody asked");
});
