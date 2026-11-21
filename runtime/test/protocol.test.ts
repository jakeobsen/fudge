import assert from "node:assert/strict";
import { test } from "node:test";
import { encode, parseAppMessage, revive } from "../src/protocol.ts";

const parse = (value: unknown) => parseAppMessage(typeof value === "string" ? value : JSON.stringify(value));

test("ping parses", () => {
    assert.deepEqual(parse({ type: "ping", id: 7 }), { ok: true, message: { type: "ping", id: 7 } });
});

test("invalid JSON and shapeless messages are protocol errors", () => {
    assert.deepEqual(parse("{nope"), { ok: false, error: { type: "protocolError", message: "not valid JSON" } });
    assert.equal(parse({ id: 1 }).ok, false);
    assert.equal(parse([]).ok, false);
    assert.equal(parse({ type: "ping" }).ok, false);
});

test("unknown types are rejected and keep the id", () => {
    assert.deepEqual(parse({ type: "explode", id: 3 }), {
        ok: false,
        error: { type: "protocolError", message: "unknown message type `explode`", id: 3 },
    });
});

test("launch needs a session, an entry and a known mode", () => {
    const launch = {
        type: "launch",
        session: "s1",
        entry: "/x/cmd.js",
        mode: "view",
        launchProps: { arguments: { a: "1" } },
        preferences: { loud: true },
        environment: { extensionName: "x", supportPath: "/s" },
    };
    assert.deepEqual(parse(launch), { ok: true, message: launch });
    assert.equal((parse({ ...launch, preferences: "nope" }) as { message: { preferences?: object } }).message.preferences, undefined);
    assert.equal(parse({ ...launch, session: "" }).ok, false);
    assert.equal(parse({ ...launch, entry: undefined }).ok, false);
    assert.deepEqual(parse({ ...launch, mode: "menu-bar" }), { ok: true, message: { ...launch, mode: "menu-bar" } });
    assert.deepEqual(parse({ ...launch, mode: "window" }), {
        ok: false,
        error: { type: "protocolError", message: "`launch` needs a `mode` of `view`, `no-view` or `menu-bar`" },
    });
});

test("event needs a node and a path of strings; args default to none", () => {
    assert.deepEqual(parse({ type: "event", session: "s", node: 4, path: ["onAction"] }), {
        ok: true,
        message: { type: "event", session: "s", node: 4, path: ["onAction"], args: [] },
    });
    assert.equal(parse({ type: "event", session: "s", node: "4", path: [] }).ok, false);
    assert.equal(parse({ type: "event", session: "s", node: 4, path: [1] }).ok, false);
});

test("slots needs a session and an array of node ids", () => {
    assert.deepEqual(parse({ type: "slots", session: "s", nodes: [3, 5] }), {
        ok: true,
        message: { type: "slots", session: "s", nodes: [3, 5] },
    });
    assert.equal(parse({ type: "slots", session: "s", nodes: ["3"] }).ok, false);
    assert.equal(parse({ type: "slots", session: "s", nodes: [1.5] }).ok, false);
    assert.equal(parse({ type: "slots", session: "s" }).ok, false);
    assert.equal(parse({ type: "slots", nodes: [] }).ok, false);
});

test("rpcResult carries a result or an error", () => {
    assert.deepEqual(parse({ type: "rpcResult", session: "s", id: 2, result: true }), {
        ok: true,
        message: { type: "rpcResult", session: "s", id: 2, result: true, error: undefined },
    });
    assert.equal(parse({ type: "rpcResult", session: "s" }).ok, false);
});

test("revive turns $date markers back into Dates, deeply", () => {
    const revived = revive([{ due: { $date: "2026-01-02T00:00:00.000Z" } }, "x", { $date: 5 }]) as [{ due: Date }, string, object];
    assert.ok(revived[0].due instanceof Date);
    assert.equal(revived[0].due.toISOString(), "2026-01-02T00:00:00.000Z");
    assert.equal(revived[1], "x");
    assert.deepEqual(revived[2], { $date: 5 }, "only string dates are revived");
});

test("encode marks Dates and Buffers, deeply, and revive undoes it", () => {
    const value = {
        at: new Date("2026-01-02T00:00:00.000Z"),
        list: [Buffer.from("hi"), new Uint8Array([1, 2]), Number.NaN, undefined, () => 1],
        url: new URL("https://example.com/a"),
        gone: undefined,
        invalid: new Date("nope"),
    };
    const encoded = encode(value);
    assert.deepEqual(encoded, {
        at: { $date: "2026-01-02T00:00:00.000Z" },
        list: [{ $buffer: "aGk=" }, { $buffer: "AQI=" }, null, null, null],
        url: "https://example.com/a",
        invalid: null,
    });
    const revived = revive(JSON.parse(JSON.stringify(encoded))) as { at: Date; list: [Buffer, Buffer] };
    assert.equal(revived.at.toISOString(), "2026-01-02T00:00:00.000Z");
    assert.ok(Buffer.isBuffer(revived.list[0]));
    assert.equal(revived.list[0].toString("utf8"), "hi");
    assert.deepEqual([...revived.list[1]], [1, 2]);
    assert.throws(() => encode({ big: 1n }), TypeError);
});
