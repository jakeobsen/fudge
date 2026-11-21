// A no-view command that prints 2,000 errors in a tight loop, then crashes (SPEC-124): the count of the lines the host
// dropped, and then the crash, are still recorded.
"use strict";
exports.default = function Command() {
    for (let i = 1; i <= 2000; i++) console.error(`flood ${i}`);
    process.exit(3);
};
