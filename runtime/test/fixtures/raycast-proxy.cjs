// A no-view command that keeps https.request at load (as bundled HTTP clients do), then reaches for Raycast's
// sign-in proxy through it and through a raw socket (SPEC-075). Both are refused in the worker.
"use strict";
const { request } = require("https");
const net = require("net");
exports.default = async function Command() {
    const viaHttps = await new Promise((resolve) => {
        const sent = request("https://github.oauth.raycast.com/token", { method: "POST" });
        sent.on("error", (error) => resolve(error.message));
        sent.on("response", () => resolve("answered"));
        sent.end('{"grant_type":"client_credentials"}');
    });
    const viaSocket = await new Promise((resolve) => {
        const socket = new net.Socket();
        socket.on("error", (error) => resolve(error.message));
        socket.on("connect", () => resolve("connected"));
        socket.connect(443, "X.OAUTH.RAYCAST.COM.");
    });
    console.log(viaHttps, "|", viaSocket);
};
