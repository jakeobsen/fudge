// Stand-ins for the parts of @raycast/api that fudge doesn't implement.

/**
 * The APIs Fudge doesn't support, by decision (FUD-118): Raycast AI and the Raycast Browser Extension, which depend on
 * Raycast's own services. Using one says so, with no "yet". The compatibility scan counts them by these categories.
 */
export const unsupported: readonly { category: string; api: RegExp; name: string; message: string }[] = [
    { category: "AI", api: /^AI(\.|$)/, name: "Raycast AI", message: "Raycast AI isn't supported in Fudge." },
    {
        category: "Browser Extension",
        api: /^BrowserExtension(\.|$)/,
        name: "the Raycast Browser Extension",
        message: "The Raycast Browser Extension isn't supported in Fudge.",
    },
];

export class NotAvailableError extends Error {
    readonly api: string;
    constructor(api: string) {
        super(unsupported.find((group) => group.api.test(api))?.message ?? `${api} isn't available in Fudge yet`);
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

/**
 * Exports that are records of the extension's own data, keyed by its names (the deprecated `preferences`), not
 * namespaces: `createApiModule` leaves their members alone.
 */
export const plainRecords = new WeakSet<object>();

/** True for the stand-ins made by `notAvailable`. */
export function isNotAvailable(value: unknown): boolean {
    return (typeof value === "function" || typeof value === "object") && value !== null && stubs.has(value);
}

// Markers the compatibility scan (scripts/compat/) reads to count a component as missing. They're
// non-enumerable symbol properties, so nothing an extension or React does with a component sees them.

/** On a component that renders but fails when used: an action Fudge can't perform yet (`Action.CreateSnippet`). */
export const UNAVAILABLE = Symbol.for("fudge.unavailable");
/** On a component the extension host renders but the app can't draw yet (listed at the end of `components.ts`). */
export const NOT_DRAWN = Symbol.for("fudge.notDrawn");
/**
 * On an export that's there but counted apart: `OAuth`, which signs in through a sign-in server, only for the
 * providers that server supports (D-63), which a scan can't tell from an extension's own. The scan counts it, and
 * everything under it, as missing, so it stays in its own category.
 */
export const LEFT_OUT = Symbol.for("fudge.leftOut");

/** Sets `marker` on `component`, naming the API it stands for. */
export function mark(component: object, marker: symbol, name: string): void {
    Object.defineProperty(component, marker, { value: name, enumerable: false });
}
