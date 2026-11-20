// One running command. The host starts a worker thread per launch (see
// host.ts) and talks to it with the messages in protocol.ts.
//
// The command's compiled CommonJS file gets fudge's own @raycast/api and the
// same React the renderer uses: `require` is intercepted for those names in
// this thread only.

import Module from "node:module";
import { parentPort, workerData } from "node:worker_threads";
import React, { createElement, type FunctionComponent } from "react";
import * as jsxRuntime from "react/jsx-runtime";
import { placeholderEnvironment, setLaunchContext, type LaunchEnvironment } from "./api/launch.ts";
import { createApiModule } from "./api/module.ts";
import { NavigationRoot, type NavigationHandle } from "./api/navigation.ts";
import { connect, settle } from "./bridge.ts";
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

const { entry, mode, launchProps, preferences, environment } = workerData as WorkerData;
setLaunchContext({
    preferences,
    environment: { ...placeholderEnvironment, commandMode: mode, ...environment },
    launchProps,
});
let root: Root | null = null;
const navigation: NavigationHandle = { current: null };

port.on("message", (message: HostToWorker) => {
    switch (message.type) {
        case "event": {
            if (!root) return;
            try {
                const result = root.dispatch(message.node, message.path, revive(message.args) as unknown[]);
                if (isPromiseLike(result)) result.then(undefined, (error: unknown) => report(error, false));
            } catch (error) {
                if (error instanceof StaleCallbackError) {
                    post({ type: "log", level: "error", message: `ignored an event: ${error.message}` });
                } else {
                    report(error, false);
                }
            }
            return;
        }
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
    }
});

try {
    const exported = Module.createRequire(entry)(entry) as unknown;
    const command =
        typeof exported === "function" ? exported : (exported as { default?: unknown } | null | undefined)?.default;
    if (typeof command !== "function") throw new Error(`${entry} has no default export to run`);

    if (mode === "view") {
        root = createRoot({
            onRender: (snapshot) => post({ type: "render", ...snapshot }),
            onError: (error) => report(error, true),
        });
        const view = createElement(command as FunctionComponent<LaunchProps>, launchProps);
        root.render(createElement(NavigationRoot, { root: view, handle: navigation }));
    } else {
        await (command as (props: LaunchProps) => unknown)(launchProps);
        post({ type: "exit", reason: "finished" });
    }
} catch (error) {
    report(error, true);
    post({ type: "exit", reason: "crashed" });
}

function isPromiseLike(value: unknown): value is PromiseLike<unknown> {
    return typeof (value as PromiseLike<unknown> | null)?.then === "function";
}
