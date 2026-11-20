import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { updateCommandMetadata, type CommandMetadataUpdate } from "../src/api/command-metadata.ts";
import { createApiModule } from "../src/api/module.ts";
import { connect, settle, type RpcRequest } from "../src/bridge.ts";

afterEach(() => connect(null));

test("updateCommandMetadata sends command.updateMetadata and resolves once the app has stored it", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));

    let resolved = false;
    const update = updateCommandMetadata({ subtitle: "3 unread" }).then(() => (resolved = true));
    assert.equal(sent.length, 1);
    assert.equal(sent[0]!.method, "command.updateMetadata");
    assert.deepEqual(sent[0]!.params, { subtitle: "3 unread" });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(resolved, false, "it waits for the app");
    settle(sent[0]!.id, null);
    await update;
    assert.equal(resolved, true);
});

test("updateCommandMetadata sends null to go back to the manifest's subtitle", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    for (const metadata of [{ subtitle: null }, {}, { subtitle: undefined }]) {
        const update = updateCommandMetadata(metadata);
        settle(sent[sent.length - 1]!.id, null);
        await update;
    }
    assert.deepEqual(
        sent.map((request) => request.params),
        [{ subtitle: null }, { subtitle: null }, { subtitle: null }],
    );
});

test("updateCommandMetadata passes the app's rejection through", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const update = updateCommandMetadata({ subtitle: "x" });
    settle(sent[0]!.id, undefined, "updateCommandMetadata: the calling command isn't running");
    await assert.rejects(update, { message: "updateCommandMetadata: the calling command isn't running" });
});

test("updateCommandMetadata checks its argument before calling the app", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const rejects = (metadata: unknown, message: string) =>
        assert.rejects(updateCommandMetadata(metadata as CommandMetadataUpdate), { name: "TypeError", message });
    await rejects(undefined, "updateCommandMetadata: metadata must be an object");
    await rejects("subtitle", "updateCommandMetadata: metadata must be an object");
    await rejects({ subtitle: 3 }, "updateCommandMetadata: subtitle must be a string or null");
    assert.equal(sent.length, 0, "nothing reaches the app");
});

test("@raycast/api's updateCommandMetadata is fudge's, not the stub", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    const api = createApiModule() as { updateCommandMetadata: typeof updateCommandMetadata };
    const update = api.updateCommandMetadata({ subtitle: "x" });
    assert.equal(sent[0]?.method, "command.updateMetadata");
    settle(sent[0]!.id, null);
    await update;
});
