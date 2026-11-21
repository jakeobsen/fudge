// One running command. The host starts a worker thread per launch (see
// host.ts) and talks to it with the messages in protocol.ts.
//
// The command's compiled CommonJS file gets fudge's own @raycast/api and the
// same React the renderer uses: `require` is intercepted for those names in
// this thread only.

import Module from "node:module";
import path from "node:path";
import { parentPort, workerData } from "node:worker_threads";
import React, { createElement, type FunctionComponent } from "react";
import * as jsxRuntime from "react/jsx-runtime";
import { placeholderEnvironment, setLaunchContext, type LaunchEnvironment } from "./api/launch.ts";
import { Toast } from "./api/feedback.ts";
import { createApiModule } from "./api/module.ts";
import { explainRenderError } from "./api/oauth.ts";
import { providersFromEnvironment, rewriteFetch } from "./api/oauth-fetch.ts";
import { NavigationRoot, type NavigationHandle } from "./api/navigation.ts";
import { recordRender } from "./api/render.ts";
import { callApp, connect, holdWhilePending, settle } from "./bridge.ts";
import { revive, type CommandMode, type HostToWorker, type LaunchProps, type WorkerMessage } from "./protocol.ts";
import { createRoot, StaleCallbackError, type Root } from "./renderer/root.ts";

export type WorkerData = {
    entry: string;
    mode: CommandMode;
    launchProps: LaunchProps;
    preferences: Record<string, unknown>;
    environment: Partial<LaunchEnvironment>;
};

const port = parentPort;
if (!port) throw new Error("worker.ts runs as a worker thread started by host.ts");
const post = (message: WorkerMessage) => port.postMessage(message);

const provided: Record<string, unknown> = {
    "@raycast/api": createApiModule(),
    react: React,
    "react/jsx-runtime": jsxRuntime,
    // Bundles built for development call jsxDEV; production React has none.
    "react/jsx-dev-runtime": {
        Fragment: jsxRuntime.Fragment,
        jsxDEV: (type: Parameters<typeof jsxRuntime.jsx>[0], props: object, key?: string) => jsxRuntime.jsx(type, props, key),
    },
};

type Load = (this: unknown, request: string, parent: unknown, isMain: boolean) => unknown;
const internals = Module as unknown as { _load: Load };
const load = internals._load;
internals._load = function (request, parent, isMain) {
    if (Object.hasOwn(provided, request)) return provided[request];
    return load.call(this, request, parent, isMain);
};

function report(error: unknown, fatal: boolean): void {
    const failure = error instanceof Error ? error : new Error(String(error));
    post({ type: "error", message: failure.message, stack: failure.stack, fatal });
}

// Dependencies' deprecation warnings (e.g. Node's punycode module) are noise to the user.
process.noDeprecation = true;
process.on("uncaughtException", (error) => report(error, false));
process.on("unhandledRejection", (reason) => report(reason, false));
connect((request) => post(request));
// Sign-in's token and refresh requests go to the relay the user chose, never to Raycast's servers (SPEC-056).
globalThis.fetch = rewriteFetch(globalThis.fetch, providersFromEnvironment(), (provider) =>
    callApp<{ server: string | null; signedIn: boolean }>("oauth.server", { provider }).then((answer) => ({
        server: answer?.server ?? null,
        signedIn: answer?.signedIn === true,
    })),
);

const { entry, mode, launchProps, preferences, environment } = workerData as WorkerData;
// launchCommand's context carries Dates and Buffers as markers (see protocol.ts `encode`).
if (launchProps.launchContext !== undefined) {
    launchProps.launchContext = revive(launchProps.launchContext) as Record<string, unknown>;
}
setLaunchContext({
    preferences,
    // `fudge build` installs each command as `<extension>/dist/<command>.cjs`, with the manifest beside `dist/`.
    manifestFile: path.join(path.dirname(path.dirname(entry)), "package.json"),
    environment: { ...placeholderEnvironment, commandMode: mode, ...environment },
    launchProps,
});
let root: Root | null = null;
const navigation: NavigationHandle = { current: null };

port.on("message", (message: HostToWorker) => {
    switch (message.type) {
        case "event": {
            // Every event is answered with one `eventSettled`, so the app knows when no handler is running. It
            // comes after the render the handler caused: React renders a state update on a later turn (its
            // scheduler's setImmediate, queued before this one), and the root sends the snapshot a turn after that.
            const settled = () =>
                setImmediate(() => {
                    const done = () => post({ type: "eventSettled" });
                    if (root) root.whenRendered(done);
                    else done();
                });
            if (!root) return settled();
            try {
                const result = root.dispatch(message.node, message.path, revive(message.args) as unknown[]);
                if (isPromiseLike(result)) {
                    result.then(settled, (error: unknown) => {
                        report(error, false);
                        settled();
                    });
                    return;
                }
            } catch (error) {
                if (error instanceof StaleCallbackError) {
                    post({ type: "log", level: "error", message: `ignored an event: ${error.message}` });
                } else {
                    report(error, false);
                }
            }
            settled();
            return;
        }
        case "slots":
            // Always answered, so the app never waits on it; without a root (a no-view command) there are no items.
            post({ type: "slots", items: root ? root.slots(message.nodes) : [] });
            return;
        case "pop":
            navigation.current?.pop();
            return;
        case "unload":
            root?.unmount();
            post({ type: "exit", reason: "unloaded" });
            return;
        case "rpcResult":
            settle(message.id, message.result, message.error);
            return;
        case "toastAction":
            try {
                Toast.runAction(message.toast, message.action);
            } catch (error) {
                report(error, false);
            }
            return;
    }
});

try {
    // An old command module calls the deprecated `render(<Command />)` while it loads, and exports nothing.
    const { result: exported, rendered } = recordRender(() => Module.createRequire(entry)(entry) as unknown);
    const exportedCommand =
        typeof exported === "function" ? exported : (exported as { default?: unknown } | null | undefined)?.default;
    // The default export wins. Without one, the element `render` got is the root, as if the default export were
    // `() => element`. The app shows nothing a no-view command renders, so that one fails, saying why.
    const fromRender = typeof exportedCommand !== "function" && rendered !== undefined;
    const command = fromRender ? () => rendered?.element : exportedCommand;
    if (fromRender && mode === "no-view") throw new Error(`${entry} shows a view with render(), but it's a no-view command`);

    if (typeof command !== "function") {
        // An old no-view command exports nothing: its work is the module's top-level code, which ran as it loaded.
        // The worker ends when that work does. Its timers, sockets and child processes keep it alive as Node's
        // always do, and the message port only while a call into the app waits for its answer. The host then
        // reports `finished`.
        if (mode !== "no-view") throw new Error(`${entry} has no default export to run`);
        holdWhilePending(port);
    } else if (mode === "view" || mode === "menu-bar") {
        // A menu-bar command renders like a view command: its MenuBarExtra is the view.
        root = createRoot({
            onRender: (snapshot) => post({ type: "render", ...snapshot }),
            onError: (error) => report(explainRenderError(error), true),
        });
        const view = createElement(command as FunctionComponent<LaunchProps>, launchProps);
        root.render(createElement(NavigationRoot, { root: view, handle: navigation }));
    } else {
        await (command as (props: LaunchProps) => unknown)(launchProps);
        await flushOutput();
        post({ type: "exit", reason: "finished" });
    }
} catch (error) {
    report(error, true);
    await flushOutput();
    post({ type: "exit", reason: "crashed" });
}

/**
 * Waits until the host has read everything the command wrote to stdout and stderr. They reach the host on their own
 * channel, so without this a no-view command's last `console.log` could arrive after its `exit`, when the host has
 * already stopped the worker. A write's callback runs once the host has taken the data; capped at a second.
 */
async function flushOutput(): Promise<void> {
    const flushed = (stream: NodeJS.WriteStream) => new Promise<void>((resolve) => stream.write("", () => resolve()));
    await Promise.race([
        Promise.all([flushed(process.stdout), flushed(process.stderr)]),
        // Not unref'd: if the host never reads a stream, the worker still reports its exit after a second.
        new Promise((resolve) => setTimeout(resolve, 1000)),
    ]);
}

function isPromiseLike(value: unknown): value is PromiseLike<unknown> {
    return typeof (value as PromiseLike<unknown> | null)?.then === "function";
}
