// A view command that throws while rendering.
"use strict";
exports.default = function Command() {
    throw new Error("render went wrong");
};
