import { Action, ActionPanel, Detail, Icon, showToast, Toast, useNavigation } from "@raycast/api";
import { useEffect, useRef } from "react";
import { commandLineToolsReady, openDevelopmentSettings } from "fudge:app";
import { swiftPartsActions, swiftPartsMarkdown, type SwiftPartsChoice } from "./swift-parts.ts";

/**
 * Before installing an extension with a part written in Swift while Apple's Command Line Tools aren't set up (SPEC-145
 * §3): what it needs, and three choices, in order. Don't Install is ↵. Install with Command Line Tools
 * asks again whether the tools are set up: once they are it installs, and until then it opens Settings → Development
 * and the view stays, so coming back to it and picking it again installs. Leaving the view any other way is Don't
 * Install.
 */
export function SwiftPartsView({ title, choose }: { title: string; choose: (choice: SwiftPartsChoice) => void }) {
    const { pop } = useNavigation();
    const chosen = useRef(false);
    const answer = useRef(choose);
    answer.current = choose;
    const pick = (choice: SwiftPartsChoice) => {
        if (chosen.current) return;
        chosen.current = true;
        answer.current(choice);
        pop();
    };
    // Esc, or anything else that takes the view away, chooses nothing.
    useEffect(
        () => () => {
            if (!chosen.current) {
                chosen.current = true;
                answer.current("dont-install");
            }
        },
        [],
    );
    const build = async () => {
        if (await commandLineToolsReady().catch(() => false)) {
            pick("build");
            return;
        }
        await openDevelopmentSettings().catch((error: unknown) =>
            showToast({
                style: Toast.Style.Failure,
                title: "Couldn't open Settings",
                message: error instanceof Error ? error.message : String(error),
            }),
        );
    };
    return (
        <Detail
            navigationTitle={title}
            markdown={swiftPartsMarkdown(title)}
            actions={
                <ActionPanel>
                    <Action title={swiftPartsActions.dontInstall} icon={Icon.XMarkCircle} onAction={() => pick("dont-install")} />
                    <Action title={swiftPartsActions.leaveOut} icon={Icon.Download} onAction={() => pick("leave-out")} />
                    <Action title={swiftPartsActions.build} icon={Icon.Hammer} onAction={() => void build()} />
                </ActionPanel>
            }
        />
    );
}
