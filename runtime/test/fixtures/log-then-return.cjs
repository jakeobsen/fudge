// A no-view command that logs a burst of lines, the last one on each stream, and returns at once.
"use strict";
exports.default = function Command() {
    for (let i = 1; i <= 200; i++) console.log(`line ${i}`);
    console.error("last on stderr");
    console.log("last on stdout");
};
