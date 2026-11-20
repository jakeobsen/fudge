// A no-view command that reports what its launch context holds, and whether
// `environment.launchContext` sees the same values.
"use strict";
const { environment } = require("@raycast/api");
exports.default = async function Command(props) {
    const context = props.launchContext;
    const at = context.nested.at;
    const data = context.nested.list[0];
    console.log(
        JSON.stringify({
            from: context.from,
            at: at instanceof Date ? at.toISOString() : `not a Date: ${JSON.stringify(at)}`,
            data: Buffer.isBuffer(data) ? data.toString("utf8") : `not a Buffer: ${JSON.stringify(data)}`,
            environment: environment.launchContext === context,
        }),
    );
};
