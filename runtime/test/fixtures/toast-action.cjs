// A view command that shows a toast with an action, which prints when picked.
"use strict";
const { Detail, Toast, showToast } = require("@raycast/api");
const { useEffect } = require("react");
const { jsx } = require("react/jsx-runtime");

exports.default = function Command() {
    useEffect(() => {
        showToast({ title: "Saved", primaryAction: { title: "Undo", onAction: (toast) => console.log(`undo: ${toast.title}`) } });
    }, []);
    return jsx(Detail, { markdown: "toast" });
};
