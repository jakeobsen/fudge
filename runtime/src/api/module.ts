// The object extensions receive for `require("@raycast/api")`.
//
// It holds fudge's implementation. Anything else @raycast/api exports is a
// stub that throws `NotAvailableError` naming it as soon as it's used (called,
// rendered as a component, or read from), so a missing API fails with a clear
// message instead of "undefined is not a function". Implemented components
// report missing members the same way (`Action.CopyToClipboard`).

import * as implementation from "./index.ts";
import { RAYCAST_EXPORTS } from "./raycast-exports.generated.ts";
import { isNotAvailable, notAvailable } from "./stubs.ts";

export { NotAvailableError, notAvailable } from "./stubs.ts";

const known = new Set(RAYCAST_EXPORTS);

// Keyed by object, then by name: one object can be reached by two names
// (List.Item and the old ListItem), and each name reports its own path.
const wrappers = new WeakMap<object, Map<string, unknown>>();

/**
 * Wraps an implemented component or namespace so that a capitalised member
 * it lacks (a sub-component or a constant group, like `Action.CopyToClipboard`)
 * is a stub naming it. Wrappers are cached: React needs a component to be the
 * same object on every render.
 */
function withMissingMembers(value: unknown, name: string): unknown {
    if ((typeof value !== "function" && typeof value !== "object") || value === null) return value;
    // A stub already fails on any use, and must stay recognisable to `isNotAvailable` (`pasteText`).
    if (isNotAvailable(value)) return value;
    let byName = wrappers.get(value);
    if (!byName) wrappers.set(value, (byName = new Map()));
    const cached = byName.get(name);
    if (cached) return cached;
    const wrapper = new Proxy(value, {
        get(target, key, receiver) {
            const member = Reflect.get(target, key, receiver);
            if (typeof key !== "string" || !/^[A-Z]/.test(key)) return member;
            // A proxy must hand back a frozen property exactly as it is (Keyboard.Shortcut, …).
            const own = Reflect.getOwnPropertyDescriptor(target, key);
            if (own && !own.configurable && own.writable === false) return member;
            if (member === undefined) return notAvailable(`${name}.${key}`);
            return withMissingMembers(member, `${name}.${key}`);
        },
    });
    byName.set(name, wrapper);
    return wrapper;
}

export function createApiModule(implemented: Record<string, unknown> = implementation): Record<string, unknown> {
    const target: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(implemented)) target[key] = withMissingMembers(value, key);
    const stub = (key: string) => (known.has(key) ? notAvailable(key) : undefined);
    return new Proxy(target, {
        get(object, key, receiver) {
            if (typeof key !== "string" || key in object) return Reflect.get(object, key, receiver);
            return stub(key);
        },
        has(object, key) {
            return key in object || (typeof key === "string" && known.has(key));
        },
        ownKeys(object) {
            return [...new Set([...Reflect.ownKeys(object), ...known])];
        },
        getOwnPropertyDescriptor(object, key) {
            const own = Reflect.getOwnPropertyDescriptor(object, key);
            if (own || typeof key !== "string" || !known.has(key)) return own;
            return { configurable: true, enumerable: true, writable: false, value: stub(key) };
        },
    });
}
