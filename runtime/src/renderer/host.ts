// The React host config: how React builds and changes fudge's UI tree.
//
// Host instances are plain objects. React calls these functions during a
// commit; after every commit `resetAfterCommit` tells the container, which
// schedules sending the tree to the app (see root.ts).

import { createContext } from "react";
import Reconciler from "react-reconciler";
import { DefaultEventPriority, NoEventPriority } from "react-reconciler/constants.js";

export type HostInstance = {
    kind: "instance";
    id: number;
    type: string;
    props: Record<string, unknown>;
    children: HostNode[];
    hidden: boolean;
    /** The container this instance belongs to; never serialized. */
    container: Container;
};

export type HostText = {
    kind: "text";
    id: number;
    text: string;
    hidden: boolean;
};

export type HostNode = HostInstance | HostText;

export type Container = {
    children: HostNode[];
    /** Every mounted instance by id, so events from the app can find their target. */
    instances: Map<number, HostInstance>;
    nextId: number;
    onCommit: () => void;
};

export function createContainer(onCommit: () => void): Container {
    return { children: [], instances: new Map(), nextId: 1, onCommit };
}

let currentUpdatePriority: number = NoEventPriority;

function propsWithoutChildren(props: Record<string, unknown>): Record<string, unknown> {
    const { children: _children, ...rest } = props;
    return rest;
}

function insert(children: HostNode[], child: HostNode, before?: HostNode): void {
    const existing = children.indexOf(child);
    if (existing !== -1) children.splice(existing, 1);
    const index = before === undefined ? -1 : children.indexOf(before);
    if (index === -1) children.push(child);
    else children.splice(index, 0, child);
}

function remove(children: HostNode[], child: HostNode): void {
    const index = children.indexOf(child);
    if (index !== -1) children.splice(index, 1);
    forget(child);
}

/** Removes `node` and everything under it from its container's index. */
function forget(node: HostNode): void {
    if (node.kind !== "instance") return;
    node.container.instances.delete(node.id);
    for (const child of node.children) forget(child);
}

const hostConfig = {
    rendererPackageName: "fudge",
    rendererVersion: "0.0.0",
    extraDevToolsConfig: null,

    supportsMutation: true,
    supportsPersistence: false,
    supportsHydration: false,
    supportsMicrotasks: true,
    scheduleMicrotask: queueMicrotask,
    scheduleTimeout: setTimeout,
    cancelTimeout: clearTimeout,
    noTimeout: -1,
    isPrimaryRenderer: true,
    warnsIfNotActing: false,

    createInstance(type: string, props: Record<string, unknown>, container: Container): HostInstance {
        const instance: HostInstance = {
            kind: "instance",
            id: container.nextId++,
            type,
            props: propsWithoutChildren(props),
            children: [],
            hidden: false,
            container,
        };
        container.instances.set(instance.id, instance);
        return instance;
    },
    createTextInstance(text: string, container: Container): HostText {
        return { kind: "text", id: container.nextId++, text, hidden: false };
    },
    appendInitialChild(parent: HostInstance, child: HostNode): void {
        parent.children.push(child);
    },
    finalizeInitialChildren: () => false,
    shouldSetTextContent: () => false,
    getRootHostContext: () => ({}),
    getChildHostContext: (parentContext: object) => parentContext,
    getPublicInstance: (instance: HostNode) => instance,
    prepareForCommit: () => null,
    resetAfterCommit(container: Container): void {
        container.onCommit();
    },
    preparePortalMount(): void {},

    appendChild(parent: HostInstance, child: HostNode): void {
        insert(parent.children, child);
    },
    appendChildToContainer(container: Container, child: HostNode): void {
        insert(container.children, child);
    },
    insertBefore(parent: HostInstance, child: HostNode, before: HostNode): void {
        insert(parent.children, child, before);
    },
    insertInContainerBefore(container: Container, child: HostNode, before: HostNode): void {
        insert(container.children, child, before);
    },
    removeChild(parent: HostInstance, child: HostNode): void {
        remove(parent.children, child);
    },
    removeChildFromContainer(container: Container, child: HostNode): void {
        remove(container.children, child);
    },
    clearContainer(container: Container): void {
        for (const child of container.children) forget(child);
        container.children = [];
    },
    commitUpdate(instance: HostInstance, _type: string, _oldProps: unknown, newProps: Record<string, unknown>): void {
        instance.props = propsWithoutChildren(newProps);
    },
    commitTextUpdate(text: HostText, _oldText: string, newText: string): void {
        text.text = newText;
    },
    commitMount(): void {},
    resetTextContent(): void {},
    hideInstance(instance: HostInstance): void {
        instance.hidden = true;
    },
    unhideInstance(instance: HostInstance): void {
        instance.hidden = false;
    },
    hideTextInstance(text: HostText): void {
        text.hidden = true;
    },
    unhideTextInstance(text: HostText): void {
        text.hidden = false;
    },
    detachDeletedInstance(): void {},

    getInstanceFromNode: () => null,
    beforeActiveInstanceBlur(): void {},
    afterActiveInstanceBlur(): void {},
    prepareScopeUpdate(): void {},
    getInstanceFromScope: () => null,

    setCurrentUpdatePriority(priority: number): void {
        currentUpdatePriority = priority;
    },
    getCurrentUpdatePriority: () => currentUpdatePriority,
    resolveUpdatePriority: () =>
        currentUpdatePriority !== NoEventPriority ? currentUpdatePriority : DefaultEventPriority,

    NotPendingTransition: null,
    HostTransitionContext: createContext(null),
    resetFormInstance(): void {},
    requestPostPaintCallback(): void {},
    shouldAttemptEagerTransition: () => false,
    trackSchedulerEvent(): void {},
    resolveEventType: () => null,
    resolveEventTimeStamp: () => -1.1,
    bindToConsole(methodName: "log" | "warn" | "error" | "info", args: unknown[]) {
        return console[methodName].bind(console, ...args);
    },

    maySuspendCommit: () => false,
    maySuspendCommitOnUpdate: () => false,
    maySuspendCommitInSyncRender: () => false,
    preloadInstance: () => true,
    startSuspendingCommit: () => null,
    suspendInstance(): void {},
    suspendOnActiveViewTransition(): void {},
    waitForCommitToBeReady: () => null,
    getSuspendedCommitReason: () => null,
};

// The config is checked by the tests, not by the (very wide) HostConfig type.
export const reconciler = Reconciler(hostConfig as unknown as Parameters<typeof Reconciler>[0]);
