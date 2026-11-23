// The app's sign-in table and Raycast's hosts, as the app hands them to every worker (SPEC-056, SPEC-132 §2). The
// provider table is core's (`OAuthProviders`), in `FUDGE_OAUTH_PROVIDERS`, and Raycast's domains are core's
// `OAuthProviders.raycastDomains`, in `FUDGE_RAYCAST_DOMAINS`, so neither exists twice. Nothing here imports anything,
// so the Extension Store can use it without the worker's sign-in code (`oauth-fetch.ts` re-exports it).

export type OAuthProvider = { id: string; name: string; authorizeURL: string; tokenURL: string; refreshURL: string };

export const providersVariable = "FUDGE_OAUTH_PROVIDERS";

/** The table the app passed; empty when it's missing or doesn't read. */
export function providersFromEnvironment(value = process.env[providersVariable]): OAuthProvider[] {
    try {
        const parsed: unknown = JSON.parse(value ?? "[]");
        if (!Array.isArray(parsed)) return [];
        return parsed.filter(
            (entry): entry is OAuthProvider =>
                typeof entry === "object" &&
                entry !== null &&
                ["id", "name", "authorizeURL", "tokenURL", "refreshURL"].every(
                    (key) => typeof (entry as Record<string, unknown>)[key] === "string",
                ),
        );
    } catch {
        return [];
    }
}

/** Raycast's sign-in proxies, `*.oauth.raycast.com`: Fudge never sends anything there. DNS ignores a trailing dot,
 * so `github.oauth.raycast.com.` is one of them too. */
export function isRaycastHost(hostname: string): boolean {
    const host = hostname.toLowerCase().replace(/\.+$/, "");
    return host === "oauth.raycast.com" || host.endsWith(".oauth.raycast.com");
}

/** The variable the app hands Raycast's domains in (core's `OAuthProviders.raycastDomains`, SPEC-132 §2). */
export const raycastDomainsVariable = "FUDGE_RAYCAST_DOMAINS";

/** Raycast's domains as the app passed them, lowercased; empty when the variable is missing or doesn't read. */
export function raycastDomainsFromEnvironment(value = process.env[raycastDomainsVariable]): string[] {
    try {
        const parsed: unknown = JSON.parse(value ?? "[]");
        if (!Array.isArray(parsed)) return [];
        return parsed
            .filter((entry): entry is string => typeof entry === "string" && entry.length > 0)
            .map((entry) => entry.toLowerCase());
    } catch {
        return [];
    }
}

let environmentDomains: { value: string | undefined; domains: string[] } | null = null;

/** This worker's Raycast domains, read once per value of the variable. */
function domainsInEnvironment(): string[] {
    const value = process.env[raycastDomainsVariable];
    if (environmentDomains === null || environmentDomains.value !== value) {
        environmentDomains = { value, domains: raycastDomainsFromEnvironment(value) };
    }
    return environmentDomains.domains;
}

/**
 * Whether `hostname` is one of Raycast's hosts (SPEC-132 §2): a domain the app passed (`raycast.com`) or any host
 * under it, ignoring case and trailing dots. That's broader than `isRaycastHost`: raycast.com's own sign-in and every
 * proxy (`*.oauth.raycast.com`, `*.oauth-proxy.raycast.com`, `apple-music-oauth.raycast.com`) are Raycast's. The one
 * definition is core's, so the app's `oauth.prepare` and the worker can't drift apart.
 */
export function isRaycastDomainHost(hostname: string, domains: readonly string[] = domainsInEnvironment()): boolean {
    const host = hostname.toLowerCase().replace(/\.+$/, "");
    return domains.some((domain) => host === domain || host.endsWith(`.${domain}`));
}
