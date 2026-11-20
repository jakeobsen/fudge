// `environment`: facts about the running command. Every field reads the
// launch context, so it's right however early an extension looks.

import { RAYCAST_API_VERSION } from "./raycast-exports.generated.ts";
import { launchContext } from "./launch.ts";
import { isNotAvailable } from "./stubs.ts";

const env = () => launchContext().environment;

export const environment = {
    /** The @raycast/api version fudge implements, so version checks behave as with that Raycast release. */
    get raycastVersion() {
        return RAYCAST_API_VERSION;
    },
    get ownerOrAuthorName() {
        return env().ownerOrAuthorName;
    },
    get extensionName() {
        return env().extensionName;
    },
    get commandName() {
        return env().commandName;
    },
    get commandMode() {
        return env().commandMode;
    },
    get entryPointType() {
        return "command" as const;
    },
    get entryPointName() {
        return env().commandName;
    },
    get entryPointMode() {
        return env().commandMode;
    },
    get assetsPath() {
        return env().assetsPath;
    },
    get supportPath() {
        return env().supportPath;
    },
    get isDevelopment() {
        return env().isDevelopment;
    },
    get appearance() {
        return env().appearance;
    },
    /** @deprecated Raycast's old name for `appearance`. */
    get theme() {
        return env().appearance;
    },
    get textSize() {
        return "medium" as const;
    },
    get launchType() {
        return launchContext().launchProps.launchType ?? "userInitiated";
    },
    get launchContext() {
        return launchContext().launchProps.launchContext;
    },
    /** False for anything fudge doesn't implement (e.g. `AI`), so extensions can hide those features. */
    canAccess(api: unknown): boolean {
        return api !== undefined && api !== null && !isNotAvailable(api);
    },
};
