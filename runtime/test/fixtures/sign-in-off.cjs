// A no-view command that signs in, and wraps the refusal in an error of its own, as extensions often do.
"use strict";
const { OAuth } = require("@raycast/api");

module.exports = async () => {
    const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "GitHub" });
    try {
        await client.authorizationRequest({ endpoint: "https://github.oauth.raycast.com/authorize" });
    } catch (error) {
        throw new Error("Couldn't search repositories", { cause: error });
    }
};
