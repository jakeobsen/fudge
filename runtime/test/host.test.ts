import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const hostPath = fileURLToPath(new URL("../src/host.ts", import.meta.url));

test("the host answers over stdin/stdout, one JSON message per line", async () => {
    const host = spawn(process.execPath, [hostPath], { stdio: ["pipe", "pipe", "inherit"] });
    const replies = createInterface({ input: host.stdout })[Symbol.asyncIterator]();

    host.stdin.write('{"type":"ping","id":1}\n\n{"type":"ping","id":2}\n');

    assert.deepEqual(JSON.parse((await replies.next()).value), { type: "pong", id: 1 });
    assert.deepEqual(JSON.parse((await replies.next()).value), { type: "pong", id: 2 });

    host.stdin.end();
    const [code] = await once(host, "exit");
    assert.equal(code, 0);
});
