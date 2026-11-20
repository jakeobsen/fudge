import assert from "node:assert/strict";
import { test } from "node:test";
import { handleLine } from "../src/protocol.ts";

test("ping is answered with a pong carrying the same id", () => {
    assert.deepEqual(handleLine('{"type":"ping","id":7}'), { type: "pong", id: 7 });
});

test("invalid JSON is reported, not thrown", () => {
    assert.deepEqual(handleLine("{nope"), { type: "error", message: "not valid JSON" });
});

test("a message without a type is rejected", () => {
    assert.equal(handleLine('{"id":1}').type, "error");
    assert.equal(handleLine("[]").type, "error");
});

test("ping without an id is rejected", () => {
    assert.equal(handleLine('{"type":"ping"}').type, "error");
});

test("unknown types are rejected and keep the id", () => {
    assert.deepEqual(handleLine('{"type":"launch","id":3}'), {
        type: "error",
        id: 3,
        message: "unknown message type `launch`",
    });
});
