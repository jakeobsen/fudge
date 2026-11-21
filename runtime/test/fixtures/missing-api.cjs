// Uses an API that isn't implemented (yet): the failure must name it.
"use strict";
const { captureMemorySnapshot } = require("@raycast/api");
exports.default = async function Command() {
    captureMemorySnapshot("launch");
};
