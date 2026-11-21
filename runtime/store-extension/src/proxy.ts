// The Mac's proxy for the store's own npm and git (SPEC-116 §3). Opened from Finder or at login, Fudge has no
// HTTPS_PROXY, so the app reads the proxy set in System Settings and hands it to the host as FUDGE_SYSTEM_PROXY
// (`SystemProxy`, core). The store adds it to what it runs only where no proxy variable is set already, so the
// user's own always wins. A proxy auto-configuration file can't be passed on; it's only noted, for the cause line.

export type SystemProxy = { https?: string; http?: string; noProxy?: string; autoConfig: boolean };

const proxyURL = /^http:\/\/(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:.]+\]):\d{1,5}$/;
const bypassList = /^[A-Za-z0-9.:,-]+$/;
const proxyKeys = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"];

/** FUDGE_SYSTEM_PROXY, each value checked again; anything malformed is left out. */
export function systemProxy(env: NodeJS.ProcessEnv = process.env): SystemProxy {
    let parsed: unknown;
    try {
        parsed = JSON.parse(env.FUDGE_SYSTEM_PROXY ?? "{}");
    } catch {
        return { autoConfig: false };
    }
    if (typeof parsed !== "object" || parsed === null) return { autoConfig: false };
    const record = parsed as Record<string, unknown>;
    const url = (value: unknown) => (typeof value === "string" && proxyURL.test(value) ? value : undefined);
    return {
        https: url(record.https),
        http: url(record.http),
        noProxy: typeof record.noProxy === "string" && bypassList.test(record.noProxy) ? record.noProxy : undefined,
        autoConfig: record.autoConfig === true,
    };
}

/** Never sent through a proxy, whatever the Mac's bypass list says. */
export const alwaysDirect = ["localhost", "127.0.0.1"];

/**
 * The variables to add for npm and git: both letter cases, since curl (git) reads only `http_proxy` in lower case and
 * npm reads either. None when any proxy variable is set already. `NO_PROXY` is this Mac itself and its bypass list,
 * unless the user set their own.
 */
export function proxyVariables(env: NodeJS.ProcessEnv = process.env): Record<string, string> {
    if (proxyKeys.some((key) => env[key])) return {};
    const proxy = systemProxy(env);
    const variables: Record<string, string> = {};
    const set = (name: string, value: string | undefined) => {
        if (value) variables[name.toUpperCase()] = variables[name.toLowerCase()] = value;
    };
    set("https_proxy", proxy.https);
    set("http_proxy", proxy.http);
    if ((proxy.https || proxy.http) && !(env.NO_PROXY || env.no_proxy)) {
        const bypass = (proxy.noProxy ?? "").split(",").filter((entry) => entry.length > 0);
        set("no_proxy", [...new Set([...alwaysDirect, ...bypass])].join(","));
    }
    return variables;
}
