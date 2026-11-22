// Extensions with a part written in Swift (SPEC-145 §3). With Apple's Command Line Tools set up, the store installs
// them exactly as any other, building the part (`fudge build --swift-parts build`). Without them, before anything is
// installed, a view says so and offers three choices. This module holds the words and the choices; it
// doesn't import `@raycast/api`, so the tests read it directly.

import { readFile } from "node:fs/promises";
import path from "node:path";

/** What `fudge build --swift-parts` is told. */
export type SwiftParts = "build" | "leave-out";

/** The view's answer: nothing changes, install without the part, or build it with the Command Line Tools. */
export type SwiftPartsChoice = "dont-install" | SwiftParts;

/** What the view says, before its actions. */
export function swiftPartsMessage(title: string): string {
    return (
        `${title} has a part written in Swift, and building it needs Apple's Command Line Tools, which aren't set up. ` +
        "To install it with that part, set them up in Settings → Development."
    );
}

/** The view's three actions, in this order; ↵ is the first. */
export const swiftPartsActions = {
    dontInstall: "Don't Install",
    leaveOut: "Install Without the Swift Part",
    build: "Install with Command Line Tools",
} as const;

/** The line beside Install Without the Swift Part. */
export const leaveOutLine = "Some commands might not work, or the extension may crash.";

/** The view's markdown: its message, then the three actions with the line beside the second. */
export function swiftPartsMarkdown(title: string): string {
    return [
        swiftPartsMessage(title),
        "",
        `- **${swiftPartsActions.dontInstall}**`,
        `- **${swiftPartsActions.leaveOut}**: ${leaveOutLine}`,
        `- **${swiftPartsActions.build}**`,
    ].join("\n");
}

/** What the detail page of an extension installed without its Swift part says. */
export const installedWithoutSwiftLine = "Installed without its part written in Swift.";

/** The file `fudge build` writes into an install with a part written in Swift, saying what it did with it. */
export const swiftPartsFile = "swift-parts.json";

/** What `fudge build` says when an extension has a part written in Swift and wasn't told what to do with it, word for
 * word as the bundling script's `swift:` plugin says it (`chooseSwiftParts` in `scripts/compile/swift.ts`). */
export const chooseSwiftPartsMessage =
    "this extension has a part written in Swift: choose --swift-parts build or --swift-parts leave-out";

/**
 * What the store tells `fudge build` about parts written in Swift, before it asks to install (SPEC-145 §3). The tools
 * are asked about each time, never cached. Set up, it's always `build`, with nothing more shown (D-118), which changes
 * nothing for an extension without such a part. Not set up, an extension with one gets the view's choice, and one
 * without gets nothing. Undefined means don't install.
 */
export async function decideSwiftParts(
    hasSwiftPart: boolean,
    ready: () => Promise<boolean>,
    choose: () => Promise<SwiftPartsChoice>,
): Promise<{ swiftParts?: SwiftParts } | undefined> {
    if (await ready()) return { swiftParts: "build" };
    if (!hasSwiftPart) return {};
    const choice = await choose();
    return choice === "dont-install" ? undefined : { swiftParts: choice };
}

/** Whether a failed build stopped at a `swift:` import the store's check missed, asking for `--swift-parts`. */
export function askedForSwiftParts(output: string): boolean {
    return output.includes(chooseSwiftPartsMessage);
}

/** Whether the install in `folder` was built without its part written in Swift: its `swift-parts.json` says
 * `leave-out`. */
export async function installedWithoutSwift(folder: string): Promise<boolean> {
    try {
        const text = await readFile(path.join(folder, swiftPartsFile), "utf8");
        return (JSON.parse(text) as { swiftParts?: unknown }).swiftParts === "leave-out";
    } catch {
        return false;
    }
}
