// The extension host's entry point. The fudge app starts it with Node and
// talks to it over stdin/stdout; see protocol.ts.

import { createInterface } from "node:readline";
import { handleLine } from "./protocol.ts";

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });

lines.on("line", (line) => {
    if (line.trim() === "") return;
    process.stdout.write(JSON.stringify(handleLine(line)) + "\n");
});
