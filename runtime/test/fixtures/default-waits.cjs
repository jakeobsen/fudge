// A no-view command with a default export that waits on something nothing else keeps alive.
"use strict";
exports.default = function Command() {
    return new Promise(() => {});
};
