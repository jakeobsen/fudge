// Stand-ins for the parts of @raycast/api that fudge doesn't implement.

export class NotAvailableError extends Error {
    readonly api: string;
    constructor(api: string) {
        super(`${api} isn't available in Fudge yet`);
        this.name = "NotAvailableError";
        this.api = api;
    }
}

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

/** A stand-in for the missing API `name`: calling it, or reading a member, throws. */
export function notAvailable(name: string): unknown {
    const fail = () => {
        throw new NotAvailableError(name);
    };
    const stub = new Proxy(function () {}, {
        apply: fail,
        construct: fail,
        get(_target, key) {
            if (typeof key === "symbol" || transparent.has(key)) return undefined;
            throw new NotAvailableError(`${name}.${key}`);
        },
    });
    stubs.add(stub);
    return stub;
}

const stubs = new WeakSet<object>();

/** True for the stand-ins made by `notAvailable`. */
export function isNotAvailable(value: unknown): boolean {
    return (typeof value === "function" || typeof value === "object") && value !== null && stubs.has(value);
}

// Markers the compatibility scan (scripts/compat/) reads to count a component as missing. They're
// non-enumerable symbol properties, so nothing an extension or React does with a component sees them.

/** On a component that renders but fails when used: an action Fudge can't perform yet (`Action.CreateQuicklink`). */
export const UNAVAILABLE = Symbol.for("fudge.unavailable");
/** On a component the extension host renders but the app can't draw yet (`Form.LinkAccessory`). */
export const NOT_DRAWN = Symbol.for("fudge.notDrawn");
/**
 * On an export that's there but left out by design: `OAuth`, whose client can be built but can't sign in (D-50).
 * The scan counts it, and everything under it, as missing, so it stays among the APIs left out on purpose.
 */
export const LEFT_OUT = Symbol.for("fudge.leftOut");

/** Sets `marker` on `component`, naming the API it stands for. */
export function mark(component: object, marker: symbol, name: string): void {
    Object.defineProperty(component, marker, { value: name, enumerable: false });
}
