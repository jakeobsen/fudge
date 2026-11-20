import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { afterEach, test } from "node:test";
import { fileURLToPath } from "node:url";
import { LaunchType } from "../src/api/constants.ts";
import { launchCommand, launchParams, type LaunchOptions } from "../src/api/launch-command.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";

afterEach(() => connect(null));

const user = LaunchType.UserInitiated;

test("launchCommand checks its options before calling the app", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const rejects = (options: unknown, message: string) =>
        assert.rejects(launchCommand(options as LaunchOptions), { name: "TypeError", message });

    await rejects({ type: user }, "launchCommand: name is required");
    await rejects({ name: "", type: user }, "launchCommand: name is required");
    await rejects(undefined, "launchCommand: name is required");
    const badType = "launchCommand: type must be LaunchType.UserInitiated or LaunchType.Background";
    await rejects({ name: "list" }, badType);
    await rejects({ name: "list", type: "now" }, badType);
    await rejects(
        { name: "list", type: user, extensionName: "other" },
        "launchCommand: ownerOrAuthorName is required with extensionName",
    );
    await rejects(
        { name: "list", type: user, ownerOrAuthorName: "someone", extensionName: null },
        "launchCommand: extensionName is required with ownerOrAuthorName",
    );
    await rejects({ name: "list", type: user, arguments: { query: { text: "x" } } }, 'launchCommand: argument "query" must be a string');
    await rejects({ name: "list", type: user, arguments: { tags: ["a"] } }, 'launchCommand: argument "tags" must be a string');
    await rejects({ name: "list", type: user, context: "text" }, "launchCommand: context must be an object");
    await rejects({ name: "list", type: user, fallbackText: 3 }, "launchCommand: fallbackText must be a string");
    const cycle: Record<string, unknown> = {};
    cycle.self = cycle;
    await assert.rejects(launchCommand({ name: "list", type: user, context: cycle }), {
        name: "TypeError",
        message: /context must be JSON serializable/,
    });
    assert.equal(sent.length, 0, "nothing reaches the app");
});

test("launchCommand sends command.launch with stringified arguments, null meaning absent", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const launched = launchCommand({
        name: "show",
        type: LaunchType.Background,
        extensionName: "other",
        ownerOrAuthorName: "someone",
        arguments: { text: "hi", count: 3, ratio: 1.5, on: false, gone: null, unset: undefined },
        context: { from: "a", skip: undefined, fn: () => 1 },
        fallbackText: "typed",
    });
    assert.equal(sent.length, 1);
    assert.equal(sent[0]!.method, "command.launch");
    assert.deepEqual(sent[0]!.params, {
        name: "show",
        type: "background",
        extensionName: "other",
        ownerOrAuthorName: "someone",
        arguments: { text: "hi", count: "3", ratio: "1.5", on: "false" },
        context: { from: "a" },
        fallbackText: "typed",
    });
    settle(sent[0]!.id, null);
    assert.equal(await launched, undefined);

    assert.deepEqual(launchParams({ name: "list", type: user, arguments: null, context: null, fallbackText: null }), {
        name: "list",
        type: "userInitiated",
        arguments: {},
    });
});

test("an error from the app rejects launchCommand with its message", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const launched = launchCommand({ name: "missing", type: user });
    settle(sent[0]!.id, undefined, 'No command "missing" in extension "fixture"');
    await assert.rejects(launched, { name: "Error", message: 'No command "missing" in extension "fixture"' });
});

test("Dates and Buffers in the context reach the launched command as Dates and Buffers", async () => {
    // The caller's side: what launchCommand sends, through JSON as the host and the app pass it on.
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const at = new Date("2026-11-20T12:34:56.000Z");
    const launched = launchCommand({
        name: "target",
        type: user,
        context: { from: "a", nested: { at, list: [Buffer.from("bytes"), 1] } },
    });
    const { context } = JSON.parse(JSON.stringify(sent[0]!.params)) as { context: unknown };
    settle(sent[0]!.id, null);
    await launched;
    assert.deepEqual(context, {
        from: "a",
        nested: { at: { $date: "2026-11-20T12:34:56.000Z" }, list: [{ $buffer: Buffer.from("bytes").toString("base64") }, 1] },
    });

    // The target's side: a host launching the command with that context.
    const host = spawn(process.execPath, [fileURLToPath(new URL("../src/host.ts", import.meta.url))], { stdio: ["pipe", "pipe", "pipe"] });
    const lines = createInterface({ input: host.stdout });
    const report = new Promise<Record<string, unknown>>((resolve) =>
        lines.on("line", (line) => {
            const message = JSON.parse(line) as { type: string; message?: string };
            if (message.type === "log") resolve(JSON.parse(message.message!) as Record<string, unknown>);
        }),
    );
    const entry = fileURLToPath(new URL("./fixtures/launch-context.cjs", import.meta.url));
    host.stdin.write(`${JSON.stringify({ type: "launch", session: "s", entry, mode: "no-view", launchProps: { launchContext: context } })}\n`);
    assert.deepEqual(await report, { from: "a", at: "2026-11-20T12:34:56.000Z", data: "bytes", environment: true });
    host.stdin.end();
    await once(host, "exit");
});
