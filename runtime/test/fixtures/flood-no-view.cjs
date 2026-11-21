// A no-view command that prints errors in a tight loop (SPEC-124): the host keeps 1,000 a second and counts the rest.
"use strict";
exports.default = function Command() {
    for (let i = 1; i <= 20000; i++) console.error(`flood ${i}`);
};
