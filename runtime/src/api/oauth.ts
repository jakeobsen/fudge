// `OAuth`, within decision D-50: Fudge doesn't sign in with OAuth. An extension can still build its client and ask
// it for tokens (`@raycast/utils`' `OAuthService` builds one when the extension loads, even when the user has set a
// token in its settings); only signing in fails, saying what to do.

import { RAYCAST_ENUMS } from "./raycast-enums.generated.ts";
import { LEFT_OUT, mark } from "./stubs.ts";

/** What signing in rejects with. */
export const signInMessage =
    "Fudge doesn't support signing in with OAuth. If this extension takes a token in its settings (⌘⇧,), use that.";

/** Whether this worker has refused a sign-in. */
let refused = false;

function refuse(): never {
    refused = true;
    throw new Error(signInMessage);
}

/**
 * The error a view command's render reports, explained. `withAccessToken` suspends on its sign-in, and when that's
 * refused it forgets the failed attempt, so React retries with a new one each time until it gives up on the root
 * (React's error #482, "…is an async Client Component…"). After a refused sign-in, that error means the sign-in, so
 * the command fails with the sign-in message instead. Anything else is passed through.
 */
export function explainRenderError(error: unknown): unknown {
    if (!refused || !(error instanceof Error)) return error;
    const loop = error.message.includes("async Client Component") || /\berrors\/482\b|error #482\b/.test(error.message);
    return loop ? new Error(signInMessage) : error;
}

type Options = {
    redirectMethod: string;
    providerName: string;
    providerIcon?: unknown;
    providerId?: string;
    description?: string;
    revocationEndpoint?: string;
};

/** Raycast's `OAuth.PKCEClient`, with no tokens and no sign-in. Nothing here opens a browser or contacts a provider. */
class PKCEClient {
    redirectMethod: string;
    providerName: string;
    providerIcon?: unknown;
    providerId: string;
    description?: string;
    revocationEndpoint?: string;

    constructor(options: Options) {
        this.redirectMethod = options.redirectMethod;
        this.providerName = options.providerName;
        this.providerIcon = options.providerIcon;
        this.providerId = options.providerId ?? String(options.providerName ?? "").toLowerCase();
        this.description = options.description;
        this.revocationEndpoint = options.revocationEndpoint;
    }

    async authorizationRequest(_options?: unknown): Promise<never> {
        refuse();
    }

    async authorize(_options?: unknown): Promise<never> {
        refuse();
    }

    /** Fudge never holds a token from a sign-in. */
    async getTokens(): Promise<undefined> {
        return undefined;
    }

    async setTokens(_options?: unknown): Promise<void> {}

    async removeTokens(): Promise<void> {}
}

const oauth = { PKCEClient, RedirectMethod: Object.freeze({ ...RAYCAST_ENUMS.OAuthRedirectMethod }) };
// The compatibility scan keeps counting everything under OAuth as left out by design (D-50).
mark(oauth, LEFT_OUT, "OAuth");
export const OAuth = Object.freeze(oauth);
