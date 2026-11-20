// Preferences: values come from the app with the launch (see launch.ts).

import { callApp } from "../bridge.ts";
import { launchContext } from "./launch.ts";

/** The command's preference values. Each call returns a fresh copy. */
export function getPreferenceValues<Values extends Record<string, unknown> = Record<string, unknown>>(): Values {
    return { ...launchContext().preferences } as Values;
}

export async function openExtensionPreferences(): Promise<void> {
    await callApp("preferences.openExtension");
}

export async function openCommandPreferences(): Promise<void> {
    await callApp("preferences.openCommand");
}
