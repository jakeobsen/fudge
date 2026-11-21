// An old command module: it calls the deprecated render() while it loads and exports nothing.
"use strict";
const { Action, ActionPanel, Detail, List, render } = require("@raycast/api");
const { useState } = require("react");
const { jsx } = require("react/jsx-runtime");

function Command() {
    const [count, setCount] = useState(0);
    return jsx(List, {
        navigationTitle: "rendered",
        children: jsx(List.Item, {
            title: `count ${count}`,
            actions: jsx(ActionPanel, {
                children: jsx(Action, { title: "Add", onAction: () => setCount((c) => c + 1) }),
            }),
        }),
    });
}

render(jsx(Command, {}));
// Only the first call counts.
render(jsx(Detail, { markdown: "second" }));
