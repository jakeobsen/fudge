// A no-view command that prints its preferences.
"use strict";
const { getPreferenceValues } = require("@raycast/api");
exports.default = async function Command() {
    const values = getPreferenceValues();
    values.mutated = true; // must not leak into the next call
    console.log(JSON.stringify(getPreferenceValues()));
};
