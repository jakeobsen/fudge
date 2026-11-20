// Checks that the extension gets the host's React: a context created here
// must be readable through the host's hooks, which only works with one React.
"use strict";
const React = require("react");
const { Detail, useNavigation } = require("@raycast/api");
const { jsx } = require("react/jsx-runtime");
const { jsxDEV } = require("react/jsx-dev-runtime");

function Command() {
    const navigation = useNavigation();
    const Context = React.createContext("from the extension");
    const value = React.useContext(Context);
    return jsxDEV(Detail, { markdown: `${value}; can push: ${typeof navigation.push}` }, undefined);
}

exports.default = Command;
exports.jsx = jsx;
