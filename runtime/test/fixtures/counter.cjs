// A view command, written the way esbuild compiles an extension.
"use strict";
const { Action, ActionPanel, List } = require("@raycast/api");
const { useState } = require("react");
const { jsx } = require("react/jsx-runtime");

function Command(props) {
    const [count, setCount] = useState(0);
    return jsx(List, {
        navigationTitle: (props.arguments && props.arguments.name) || "counter",
        children: jsx(List.Item, {
            title: `count ${count}`,
            actions: jsx(ActionPanel, {
                children: jsx(Action, { title: "Add", onAction: () => setCount((c) => c + 1) }),
            }),
        }),
    });
}

exports.default = Command;
