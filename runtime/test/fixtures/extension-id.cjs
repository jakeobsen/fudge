// A no-view command that reports the name it sees and whether its id reached it anywhere: `environment` or the
// worker's data, which the host builds from the launch message.
"use strict";
const { environment } = require("@raycast/api");
const { workerData } = require("node:worker_threads");
exports.default = async function Command() {
    console.log(
        JSON.stringify({
            name: environment.extensionName,
            idInEnvironment: JSON.stringify(environment).includes("someone+tools+github"),
            idInWorkerData: JSON.stringify(workerData).includes("someone+tools+github"),
        }),
    );
};
