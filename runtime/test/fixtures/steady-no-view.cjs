// A no-view command that prints fifty numbered errors, a few milliseconds apart (SPEC-124).
"use strict";
exports.default = async function Command() {
    for (let i = 1; i <= 50; i++) {
        console.error(`steady ${i}`);
        await new Promise((resolve) => setTimeout(resolve, 2));
    }
};
