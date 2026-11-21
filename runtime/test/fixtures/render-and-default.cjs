// A module that has a default export and also calls render(): the default export wins.
"use strict";
const { Detail, render } = require("@raycast/api");
const { jsx } = require("react/jsx-runtime");

render(jsx(Detail, { markdown: "from render()" }));
exports.default = function Command() {
    return jsx(Detail, { markdown: "from the default export" });
};
