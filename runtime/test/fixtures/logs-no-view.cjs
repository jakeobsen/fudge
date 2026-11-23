// A no-view command that logs at every level, shows a failure toast, leaves a rejection unhandled and then throws
// (SPEC-124). Its argument and preference are seeds a test looks for in the log files: they must never be there.
"use strict";
const { getPreferenceValues, showToast, Toast } = require("@raycast/api");

exports.default = async function Command(props) {
    const typed = props.arguments.query === undefined ? "nothing" : "something";
    const key = getPreferenceValues().apiKey === undefined ? "no key" : "a key";
    console.error(`an error line, with ${typed} typed and ${key}`);
    console.warn("a warning line");
    console.log("a log line");
    console.debug("a debug line");
    void showToast({ style: Toast.Style.Failure, title: "Failed to fetch latest data", message: "ENOENT: no such file" });
    void Promise.reject(new Error("rejected"));
    await new Promise((resolve) => setTimeout(resolve, 20));
    throw new Error("thrown at the end");
};
