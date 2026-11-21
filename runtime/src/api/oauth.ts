// `OAuth`: signing in through a fudge-oauth relay (SPEC-056, decision D-63). `@raycast/utils`' `OAuthService` builds
// an `OAuth.PKCEClient` when the extension loads and asks it for tokens; signing in goes through the relay the user
// chose in Settings → Sign-in, never Raycast's servers. The app opens the browser, waits for the loopback callback
// and keeps the tokens in the Keychain, for the calling extension only.

import { createHash } from "node:crypto";
import { callApp } from "../bridge.ts";
import { markNotice, noticeOf } from "../notice.ts";
import { RAYCAST_ENUMS } from "./raycast-enums.generated.ts";
import { LEFT_OUT, mark } from "./stubs.ts";

/**
 * What signing in rejects with while sign-in is off, as the app's `oauth.prepare` does (`SignInRefusal.off`), marked
 * `signInOff` (SPEC-095). It's written to read well where an extension shows it in a toast of its own.
 */
export const signInOffMessage =
    "Sign-in is off. This extension needs to sign in with OAuth to work. " +
    "Turn on sign-in in Fudge's settings, or, if it takes a token, set it in its settings.";

/** The notice kind of a refusal while sign-in is off (`notice.ts`). */
export const signInOffNotice = "signInOff";

/** The last refused sign-in in this worker, if any: its message, and its notice when the app refused on purpose. */
let refusal: { message: string; notice?: string } | null = null;

/**
 * The error a view command's render reports, explained. `withAccessToken` suspends on its sign-in, and when that's
 * refused it forgets the failed attempt, so React retries with a new one each time until it gives up on the root
 * (React's error #482, "…is an async Client Component…"). After a refused sign-in, that error means the sign-in, so
 * the command fails with the refusal's message instead, once. Anything else is passed through.
 */
export function explainRenderError(error: unknown): unknown {
    if (refusal === null || !(error instanceof Error)) return error;
    const loop = error.message.includes("async Client Component") || /\berrors\/482\b|error #482\b/.test(error.message);
    if (!loop) return error;
    // Once: a later, unrelated #482 isn't the sign-in's.
    const { message, notice } = refusal;
    refusal = null;
    const explained = new Error(message);
    return notice === undefined ? explained : markNotice(explained, notice);
}

/** Runs a call to the app, remembering a rejection's message and notice for `explainRenderError`. */
async function signInStep<T>(call: () => Promise<T>): Promise<T> {
    try {
        const result = await call();
        refusal = null;
        return result;
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        refusal = { message, notice: noticeOf(error)?.notice };
        throw error instanceof Error ? error : new Error(message);
    }
}

// MARK: - PKCE

const unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

/** A PKCE code verifier: `length` (43–128) characters from RFC 7636's unreserved alphabet. */
export function codeVerifier(length = 64): string {
    if (!Number.isInteger(length) || length < 43 || length > 128) throw new RangeError("A verifier has 43–128 characters");
    // 66 symbols: reject bytes ≥ 198 (3 × 66) so every symbol is equally likely.
    let verifier = "";
    while (verifier.length < length) {
        for (const byte of crypto.getRandomValues(new Uint8Array(length * 2))) {
            if (byte < 198 && verifier.length < length) verifier += unreserved[byte % 66];
        }
    }
    return verifier;
}

/** The S256 challenge for a verifier: base64url(SHA-256(verifier)), unpadded. */
export function codeChallenge(verifier: string): string {
    return createHash("sha256").update(verifier, "ascii").digest("base64url");
}

/** A random `state`: 16 bytes, base64url. */
function randomState(): string {
    return Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64url");
}

// MARK: - Tokens

type TokenSetOptions = {
    accessToken?: string;
    refreshToken?: string;
    idToken?: string;
    expiresIn?: number;
    scope?: string | string[];
    access_token?: string;
    refresh_token?: string;
    id_token?: string;
    expires_in?: number;
};

/** The JSON the app keeps for a sign-in. */
type StoredTokenSet = {
    /** The `OAuthProviders` id of the relay sign-in that got these tokens; the app keeps it only for one it prepared. */
    relayProvider?: string;
    accessToken: string;
    refreshToken?: string;
    idToken?: string;
    expiresIn?: number;
    scope?: string;
    updatedAt: string;
    providerName?: string;
};

/** Raycast's `TokenSet`: a stored sign-in, with `isExpired()`. */
class TokenSet {
    accessToken: string;
    refreshToken?: string;
    idToken?: string;
    expiresIn?: number;
    scope?: string;
    updatedAt: Date;

    constructor(stored: StoredTokenSet) {
        this.accessToken = stored.accessToken;
        this.refreshToken = stored.refreshToken;
        this.idToken = stored.idToken;
        this.expiresIn = stored.expiresIn;
        this.scope = stored.scope;
        this.updatedAt = new Date(stored.updatedAt);
    }

    /** True from 10 seconds before the access token expires. Never without `expiresIn`, which 0 counts as: Raycast's
     * types say `isExpired()` needs it set, and `@raycast/utils` refreshes whenever this is true, so a token whose
     * provider sends `expires_in: 0` would otherwise be refreshed on every call. */
    isExpired(): boolean {
        if (typeof this.expiresIn !== "number" || !Number.isFinite(this.expiresIn) || this.expiresIn === 0) return false;
        return Date.now() >= this.updatedAt.getTime() + (this.expiresIn - 10) * 1000;
    }
}

/** A `TokenSetOptions` or a provider's `TokenResponse`, as the app stores it. */
export function storedTokens(
    options: TokenSetOptions,
    providerName: string,
    relayProvider?: string,
    now = new Date(),
): StoredTokenSet {
    const accessToken = options.accessToken ?? options.access_token;
    if (typeof accessToken !== "string" || accessToken === "") throw new Error("setTokens needs an access token");
    const scope = options.scope;
    const expiresIn = options.expiresIn ?? options.expires_in;
    return {
        accessToken,
        refreshToken: options.refreshToken ?? options.refresh_token,
        idToken: options.idToken ?? options.id_token,
        expiresIn: typeof expiresIn === "number" && Number.isFinite(expiresIn) ? expiresIn : undefined,
        scope: Array.isArray(scope) ? scope.join(" ") : scope,
        updatedAt: now.toISOString(),
        providerName,
        relayProvider,
    };
}

// MARK: - The client

type Options = {
    redirectMethod: string;
    providerName: string;
    providerIcon?: unknown;
    providerId?: string;
    description?: string;
    revocationEndpoint?: string;
};

type AuthorizationRequestOptions = {
    endpoint: string;
    clientId?: string;
    scope?: string;
    extraParameters?: Record<string, string>;
};

/** What the app answers `oauth.prepare` with. */
type Prepared = { provider: string; authorizeURL: string; redirectURI: string };

/** Raycast's `OAuth.PKCEClient`, signing in through the relay. */
class PKCEClient {
    redirectMethod: string;
    providerName: string;
    providerIcon?: unknown;
    providerId: string;
    description?: string;
    revocationEndpoint?: string;
    /** The provider of this client's last relay sign-in request, which marks the tokens it then stores. */
    #relayProvider?: string;

    constructor(options: Options) {
        this.redirectMethod = options.redirectMethod;
        this.providerName = options.providerName;
        this.providerIcon = options.providerIcon;
        this.providerId = options.providerId ?? String(options.providerName ?? "").toLowerCase();
        this.description = options.description;
        this.revocationEndpoint = options.revocationEndpoint;
    }

    /**
     * A sign-in request for one of the providers Fudge knows (by `endpoint`, its default authorize URL). The app
     * refuses while sign-in is off, and for any other endpoint.
     */
    async authorizationRequest(options: AuthorizationRequestOptions) {
        const prepared = await signInStep(() =>
            callApp<Prepared>("oauth.prepare", {
                endpoint: String(options?.endpoint ?? ""),
                providerName: this.providerName,
                providerId: this.providerId,
            }),
        );
        this.#relayProvider = prepared.provider;
        const codeVerifierValue = codeVerifier();
        const request = {
            clientId: String(options.clientId ?? ""),
            codeChallenge: codeChallenge(codeVerifierValue),
            codeVerifier: codeVerifierValue,
            state: randomState(),
            redirectURI: prepared.redirectURI,
            toURL(): string {
                const url = new URL(prepared.authorizeURL);
                const parameters: Record<string, string> = {
                    client_id: request.clientId,
                    redirect_uri: request.redirectURI,
                    response_type: "code",
                    scope: String(options.scope ?? ""),
                    state: request.state,
                    code_challenge: request.codeChallenge,
                    code_challenge_method: "S256",
                };
                for (const [key, value] of Object.entries(parameters)) url.searchParams.set(key, value);
                for (const [key, value] of Object.entries(options.extraParameters ?? {})) {
                    if (!(key in parameters)) url.searchParams.set(key, String(value));
                }
                return url.toString();
            },
        };
        return request;
    }

    /**
     * Signs in: the app shows "Sign in to <provider>", opens the URL in the browser on ↵, and waits for the loopback
     * callback with this request's `state`.
     */
    async authorize(options: { url?: string; state?: string; toURL?: () => string }) {
        const url = typeof options?.toURL === "function" ? options.toURL() : String(options?.url ?? "");
        const state = options?.state ?? stateOf(url);
        return signInStep(() =>
            callApp<{ authorizationCode: string }>("oauth.authorize", {
                url,
                state,
                providerName: this.providerName,
                providerId: this.providerId,
                providerIcon: this.providerIcon ?? null,
                description: this.description ?? null,
            }),
        );
    }

    async getTokens(): Promise<TokenSet | undefined> {
        const stored = await callApp<StoredTokenSet | null>("oauth.tokens.get", { providerId: this.providerId });
        return stored && typeof stored.accessToken === "string" ? new TokenSet(stored) : undefined;
    }

    async setTokens(options: TokenSetOptions): Promise<void> {
        await callApp("oauth.tokens.set", {
            providerId: this.providerId,
            tokens: storedTokens(options ?? {}, this.providerName, this.#relayProvider),
        });
    }

    async removeTokens(): Promise<void> {
        await callApp("oauth.tokens.remove", { providerId: this.providerId });
    }
}

function stateOf(url: string): string {
    try {
        return new URL(url).searchParams.get("state") ?? "";
    } catch {
        return "";
    }
}

const oauth = { PKCEClient, RedirectMethod: Object.freeze({ ...RAYCAST_ENUMS.OAuthRedirectMethod }) };
// The compatibility scan counts everything under OAuth apart: it works only for the sign-in server's providers.
mark(oauth, LEFT_OUT, "OAuth");
export const OAuth = Object.freeze(oauth);
