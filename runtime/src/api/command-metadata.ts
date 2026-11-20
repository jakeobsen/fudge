// updateCommandMetadata: a command changes how root search shows it. The app
// stores the subtitle in its support folder (`command.updateMetadata`, see
// LauncherModel); the manifest isn't touched.

import { callApp } from "../bridge.ts";

export type CommandMetadataUpdate = { subtitle?: string | null };

/** Sets the running command's subtitle in root search; `null` (or none) goes back to the manifest's. */
export async function updateCommandMetadata(metadata: CommandMetadataUpdate): Promise<void> {
    if (typeof metadata !== "object" || metadata === null) {
        throw new TypeError("updateCommandMetadata: metadata must be an object");
    }
    const subtitle = metadata.subtitle ?? null;
    if (subtitle !== null && typeof subtitle !== "string") {
        throw new TypeError("updateCommandMetadata: subtitle must be a string or null");
    }
    await callApp("command.updateMetadata", { subtitle });
}
