// A no-view command: runs, prints, finishes.
"use strict";
exports.default = async function Command(props) {
    await new Promise((resolve) => setTimeout(resolve, 5));
    console.log("ran with", JSON.stringify(props.arguments));
};
