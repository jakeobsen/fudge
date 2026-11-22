// The `swift:` imports of an extension, which Fudge can't build yet: the build stops at the import, saying so, rather
// than with esbuild's "Could not resolve".

import type { Plugin } from "esbuild";

export const swiftNotYet = "this extension has a part written in Swift, which Fudge can't build yet";

export function swiftPlugin(): Plugin {
    return {
        name: "swift",
        setup(build) {
            build.onResolve({ filter: /^swift:/ }, (args) => ({
                errors: [{ text: `${swiftNotYet} (${JSON.stringify(args.path)})` }],
            }));
        },
    };
}
