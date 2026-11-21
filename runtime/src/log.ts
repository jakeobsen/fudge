// A command's side of its log file (SPEC-124). The worker sends each line to the host as a `log` message, and the
// app writes it to the extension's file. Lines below the Log level are dropped here, before they're even formatted,
// so Debug costs nothing while it's off.

import { formatWithOptions } from "node:util";
import { logs, type LogLevel } from "./protocol.ts";

let level: LogLevel = "debug";
let send: ((level: LogLevel, message: string) => void) | null = null;

/** Where lines go: the worker posts them to the host. */
export function connectLog(sink: (level: LogLevel, message: string) => void): void {
    send = sink;
}

/** The Log level setting; the app sends a change to running commands too. */
export function setLogLevel(next: LogLevel): void {
    level = next;
}

/** Sends a line for the command's log file when the Log level records `lineLevel`; `message` is made only then. */
export function logLine(lineLevel: LogLevel, message: string | (() => string)): void {
    if (send === null || !logs(lineLevel, level)) return;
    send(lineLevel, typeof message === "function" ? message() : message);
}

/** `console.error` is an error, `console.warn` a warning, `console.log` and `console.info` info, `console.debug` debug. */
const consoleLevels = { error: "error", warn: "warning", log: "info", info: "info", debug: "debug" } as const;

/** Points `console`'s methods at the log, formatting their arguments as Node's console does, without colors. */
export function routeConsole(target: Console): void {
    for (const [method, lineLevel] of Object.entries(consoleLevels) as [keyof typeof consoleLevels, LogLevel][]) {
        target[method] = (...args: unknown[]) => logLine(lineLevel, () => formatWithOptions({ colors: false }, ...args));
    }
}
