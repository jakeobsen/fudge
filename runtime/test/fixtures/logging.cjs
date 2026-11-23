// A menu-bar command whose items log in each way a command can (SPEC-124), written the way esbuild compiles one.
"use strict";
const { MenuBarExtra, Toast, showToast } = require("@raycast/api");
const { jsx } = require("react/jsx-runtime");

const items = {
    Levels: () => {
        console.error("an error line");
        console.warn("a warning line");
        console.log("a log line");
        console.info("an info line");
        console.debug("a debug line");
    },
    Throw: () => {
        setTimeout(() => {
            throw new Error("thrown later");
        });
    },
    Reject: () => {
        void Promise.reject(new Error("rejected later"));
    },
    "Failure Toast": () => {
        void showToast({ style: Toast.Style.Failure, title: "Failed to fetch latest data", message: "ENOENT: no such file" });
    },
    "Animated Then Failure": () => {
        const toast = new Toast({ style: Toast.Style.Animated, title: "Loading" });
        void toast.show();
        toast.style = Toast.Style.Failure;
        toast.title = "Couldn't load";
        toast.message = "because";
    },
    Flood: () => {
        for (let i = 1; i <= 3000; i++) console.error(`flood ${i}`);
    },
    Steady: () => {
        for (let i = 1; i <= 50; i++) console.error(`steady ${i}`);
    },
};

exports.default = function Command() {
    return jsx(MenuBarExtra, {
        title: "Logging",
        children: Object.entries(items).map(([title, onAction]) => jsx(MenuBarExtra.Item, { title, onAction }, title)),
    });
};
