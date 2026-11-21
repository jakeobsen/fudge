// A no-view command that reaches an HTTPS server through fetch and through https (SPEC-081): it works only when the
// host trusts the server's CA.
"use strict";
const https = require("https");
exports.default = async function Command(props) {
    const url = props.arguments.url;
    const viaFetch = await fetch(url).then((response) => response.text(), (error) => `failed: ${error.cause?.code ?? error.message}`);
    const viaHttps = await new Promise((resolve) => {
        https
            .get(url, (response) => {
                let text = "";
                response.on("data", (chunk) => (text += chunk));
                response.on("end", () => resolve(text));
            })
            .on("error", (error) => resolve(`failed: ${error.code ?? error.message}`));
    });
    console.log(viaFetch, "|", viaHttps);
};
