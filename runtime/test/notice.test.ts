import assert from "node:assert/strict";
import { test } from "node:test";
import { errorReport, markNotice, noticeOf } from "../src/notice.ts";

const refusal = () => markNotice(new Error("Sign-in is off."), "signInOff");

test("the mark is found on the error itself, and isn't one of its keys", () => {
    const error = refusal();
    assert.deepEqual(noticeOf(error), { notice: "signInOff", message: "Sign-in is off." });
    assert.deepEqual(Object.keys(error), []);
    assert.equal(JSON.stringify(error), "{}", "logging or serializing it shows nothing of the mark");
    assert.equal(noticeOf(new Error("Sign-in is off.")), undefined, "the text alone is no notice");
});

test("the mark is found however a library wraps the refusal: causes and aggregates, nested", () => {
    const wrapped = new Error("Couldn't load repositories", { cause: new Error("authorize failed", { cause: refusal() }) });
    assert.deepEqual(noticeOf(wrapped), { notice: "signInOff", message: "Sign-in is off." });

    const aggregate = new AggregateError([new Error("other"), refusal()], "Several things failed");
    assert.equal(noticeOf(aggregate)?.notice, "signInOff");
    assert.equal(noticeOf(new Error("outer", { cause: aggregate }))?.notice, "signInOff");
    assert.equal(noticeOf(new AggregateError([new Error("x", { cause: refusal() })]))?.notice, "signInOff");

    // A cause that isn't an Error, such as a plain object a library rethrows, still counts by its mark.
    const plain = markNotice(Object.assign(new Error("Sign-in was cancelled."), {}), "signInCancelled");
    assert.equal(noticeOf({ cause: plain })?.notice, "signInCancelled");
});

test("anything else is no notice: plain errors, values, cycles and getters that throw", () => {
    for (const value of [undefined, null, "Sign-in is off.", 42, new Error("x"), new AggregateError([])]) {
        assert.equal(noticeOf(value), undefined);
    }
    const a = new Error("a");
    const b = new Error("b", { cause: a });
    (a as { cause?: unknown }).cause = b;
    assert.equal(noticeOf(a), undefined, "a cycle ends");

    const hostile = new Proxy(new Error("hostile"), {
        get() {
            throw new Error("no reading");
        },
    });
    assert.equal(noticeOf(hostile), undefined);
    assert.equal(noticeOf(new AggregateError([hostile, refusal()]))?.notice, "signInOff", "the next one still counts");

    // A chain longer than any real one is cut off rather than walked forever.
    let long: Error = refusal();
    for (let i = 0; i < 200; i++) long = new Error(`wrap ${i}`, { cause: long });
    assert.equal(noticeOf(long), undefined);
});

test("the error report carries the notice and the refusal's own message, or neither", () => {
    const plain = new Error("boom");
    assert.deepEqual(errorReport(plain, true), { type: "error", message: "boom", stack: plain.stack, fatal: true });
    assert.equal("notice" in errorReport(plain, true), false);
    const thrown = errorReport("a string", false);
    assert.deepEqual({ ...thrown, stack: undefined }, { type: "error", message: "a string", stack: undefined, fatal: false });

    const wrapped = new Error("Couldn't load repositories", { cause: refusal() });
    assert.deepEqual(errorReport(wrapped, true), {
        type: "error",
        message: "Sign-in is off.",
        stack: wrapped.stack,
        fatal: true,
        notice: "signInOff",
    });
});
