// Uses an API that isn't implemented (yet): the failure must name it.
"use strict";
const { WindowManagement } = require("@raycast/api");
exports.default = async function Command() {
    await WindowManagement.getActiveWindow();
};
