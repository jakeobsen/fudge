// An old no-view command whose top-level code throws while it loads.
"use strict";
console.log("before");
throw new Error("top-level went wrong");
