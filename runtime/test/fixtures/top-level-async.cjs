// An old no-view command whose top-level code is an async main(): calls into the app and a timer.
"use strict";
const { Clipboard, showHUD } = require("@raycast/api");

async function main() {
    console.log("start");
    await Clipboard.copy("copied");
    await new Promise((resolve) => setTimeout(resolve, 50));
    console.log("after the timer");
    await showHUD("Copied");
    console.log("done");
}

main();
