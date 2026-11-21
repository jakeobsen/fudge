// A view command that filters itself (`filtering: false`) and re-ranks its keyed rows when the search changes, each
// row with its own detail and actions, as Search Files does (FUD-107). Written the way esbuild compiles an extension.
"use strict";
const { Action, ActionPanel, List } = require("@raycast/api");
const { useState } = require("react");
const { jsx } = require("react/jsx-runtime");

const names = Array.from({ length: 30 }, (_, index) => `file-${index}`);

function Command() {
    const [query, setQuery] = useState("");
    // Any search reverses the rows: every row moves, and the first one changes.
    const files = query ? [...names].reverse() : names;
    return jsx(List, {
        filtering: false,
        isShowingDetail: true,
        onSearchTextChange: setQuery,
        children: files.map((name) =>
            jsx(
                List.Item,
                {
                    id: name,
                    title: name,
                    detail: jsx(List.Item.Detail, { markdown: `# ${name}` }),
                    actions: jsx(ActionPanel, { children: jsx(Action, { title: `Open ${name}`, onAction: () => {} }) }),
                },
                name,
            ),
        ),
    });
}

exports.default = Command;
