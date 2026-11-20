// A menu-bar command, written the way esbuild compiles an extension.
"use strict";
const { MenuBarExtra, environment } = require("@raycast/api");
const { useState } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");

function Command() {
    const [count, setCount] = useState(0);
    return jsxs(MenuBarExtra, {
        title: `${count}`,
        tooltip: environment.launchType,
        isLoading: false,
        children: [
            jsx(MenuBarExtra.Item, { title: "Heading" }),
            jsxs(MenuBarExtra.Section, {
                title: "Counter",
                children: [
                    jsx(MenuBarExtra.Item, {
                        title: "Add",
                        subtitle: "one",
                        shortcut: { modifiers: ["cmd"], key: "a" },
                        onAction: () => setCount((c) => c + 1),
                        alternate: jsx(MenuBarExtra.Item, {
                            title: "Add Later",
                            onAction: () => new Promise((resolve) => setTimeout(() => {
                                setCount((c) => c + 10);
                                resolve();
                            }, 50)),
                        }),
                    }),
                    jsx(MenuBarExtra.Item, {
                        title: "Fail",
                        onAction: async () => {
                            throw new Error("nope");
                        },
                    }),
                ],
            }),
            jsx(MenuBarExtra.Separator, {}),
            jsx(MenuBarExtra.Submenu, { title: "More", children: jsx(MenuBarExtra.Item, { title: "Deep", onAction: () => {} }) }),
        ],
    });
}

exports.default = Command;
