import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { callApp, connect, holdWhilePending, settle, type RpcRequest } from "../src/bridge.ts";
import { noticeOf } from "../src/notice.ts";

afterEach(() => {
    connect(null);
    holdWhilePending(null);
});

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

test("a refusal on purpose rejects with the app's notice marked on the error", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const refused = callApp("oauth.prepare");
    const plain = callApp("oauth.prepare");
    settle(sent[0]!.id, undefined, "Sign-in is off.", "signInOff");
    settle(sent[1]!.id, undefined, "Fudge can't sign in to X yet.");
    const error = await refused.catch((e: unknown) => e);
    assert.deepEqual(noticeOf(error), { notice: "signInOff", message: "Sign-in is off." });
    assert.equal(noticeOf(await plain.catch((e: unknown) => e)), undefined);
});

test("calls fail cleanly when the bridge isn't connected", async () => {
    await assert.rejects(callApp("toast.show"), /toast\.show: not connected to the Fudge app/);
});

test("answers for unknown ids are ignored", () => {
    settle(123456, "nobody asked");
});

test("a hold is kept only while a call waits for its answer", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const steps: string[] = [];
    const hold = { ref: () => steps.push("ref"), unref: () => steps.push("unref") };

    // A call already waiting when the hold is set holds it at once.
    const first = callApp("clipboard.copy");
    holdWhilePending(hold);
    assert.deepEqual(steps, ["ref"]);
    const second = callApp("hud.show");
    assert.deepEqual(steps, ["ref"], "a second call doesn't hold it again");
    settle(sent[0]!.id, null);
    assert.deepEqual(steps, ["ref"], "one call still waits");
    settle(sent[1]!.id, undefined, "refused");
    assert.deepEqual(steps, ["ref", "unref"], "an error answers a call too");
    await first;
    await assert.rejects(second);

    const third = callApp("open");
    settle(sent[2]!.id, null);
    await third;
    assert.deepEqual(steps, ["ref", "unref", "ref", "unref"]);

    // With nothing waiting, setting the hold lets go of it at once.
    const idle: string[] = [];
    holdWhilePending({ ref: () => idle.push("ref"), unref: () => idle.push("unref") });
    assert.deepEqual(idle, ["unref"]);
});
