// An old no-view command whose top-level promise rejects after the load.
"use strict";
(async () => {
    await new Promise((resolve) => setTimeout(resolve, 10));
    throw new Error("later went wrong");
})();
