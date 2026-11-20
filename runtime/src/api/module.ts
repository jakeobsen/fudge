// The object extensions receive for `require("@raycast/api")`.
//
// It holds fudge's implementation. Anything else @raycast/api exports is a
// stub that throws `NotAvailableError` naming it, when it's called or
// used as a component, so a missing API fails with a clear message instead
// of "undefined is not a function".

import * as implementation from "./index.ts";
import { RAYCAST_EXPORTS } from "./raycast-exports.generated.ts";

export class NotAvailableError extends Error {
    readonly api: string;
    constructor(api: string) {
        super(`${api} isn't available in fudge yet`);
        this.name = "NotAvailableError";
        this.api = api;
    }
}

const known = new Set(RAYCAST_EXPORTS);

// Keys that JavaScript itself or React read from any value they're handed.
// For these the stub answers `undefined` instead of producing another stub.
const transparent = new Set([
    "$$typeof",
    "prototype",
    "displayName",
    "defaultProps",
    "propTypes",
    "contextType",
    "contextTypes",
    "childContextTypes",
    "getDerivedStateFromProps",
    "getDerivedStateFromError",
    "then",
    "toJSON",
    "constructor",
    "name",
    "length",
    "call",
    "apply",
    "bind",
    "_payload",
    "_init",
    "render",
    "compare",
    "type",
]);

/** A stand-in for the missing API `name`. Calling it throws; its members are stubs too. */
export function notAvailable(name: string): unknown {
    const fail = () => {
        throw new NotAvailableError(name);
    };
    return new Proxy(function () {}, {
        apply: fail,
        construct: fail,
        get(_target, key) {
            if (typeof key === "symbol" || transparent.has(key)) return undefined;
            return notAvailable(`${name}.${key}`);
        },
    });
}

export function createApiModule(implemented: Record<string, unknown> = implementation): Record<string, unknown> {
    const target: Record<string, unknown> = { ...implemented };
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
