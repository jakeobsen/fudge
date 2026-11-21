import { Action, ActionPanel, Detail, Icon, useNavigation } from "@raycast/api";
import os from "node:os";
import { useEffect, useMemo, useRef, useState } from "react";
import { causeOf, cleanOutput, failureMarkdown, failureReport, type FailureDetails } from "./failure.ts";
import { spawnProgram } from "./git.ts";
import { systemProxy } from "./proxy.ts";

/**
 * A failed install or update (SPEC-116): the title, the likely cause in plain words, and the end of the output in a
 * code block. ↵ tries again, ⌘C copies everything (the command, its exit, Fudge's version and all the output), and the
 * extension's page on GitHub is one action away. Esc, or Back, goes back to the list.
 */
export function FailureView(props: {
    title: string;
    details: FailureDetails;
    /** The extension's folder on GitHub, when the list has loaded. */
    pageURL: string | undefined;
    /** The `fudge` tool, asked for its version only for Copy Error's text. */
    cli: string;
    retry: () => void;
}) {
    const { title, details, pageURL, cli, retry } = props;
    const { pop } = useNavigation();
    const home = os.homedir();
    const output = useMemo(() => cleanOutput(details.output, home), [details.output, home]);
    const command = details.command === undefined ? undefined : cleanOutput(details.command, home);
    const cause = useMemo(() => causeOf({ ...details, output }, systemProxy()), [details, output]);
    const [version, setVersion] = useState<string>();
    useEffect(() => {
        void spawnProgram(cli, ["version"], { timeout: 5000 }).then((result) => {
            const line = result.stdout.trim().split("\n")[0] ?? "";
            if (result.code === 0 && /^[\w.+-]{1,64}$/.test(line)) setVersion(line);
        });
    }, [cli]);
    // One retry per view: a second ↵ before it's gone does nothing.
    const retried = useRef(false);

    return (
        <Detail
            navigationTitle={title}
            markdown={failureMarkdown(title, cause, output)}
            actions={
                <ActionPanel>
                    <Action
                        title="Try Again"
                        icon={Icon.ArrowClockwise}
                        onAction={() => {
                            if (retried.current) return;
                            retried.current = true;
                            pop();
                            retry();
                        }}
                    />
                    <Action.CopyToClipboard
                        title="Copy Error"
                        shortcut={{ modifiers: ["cmd"], key: "c" }}
                        content={failureReport(title, cause, { ...details, command }, output, version)}
                    />
                    {pageURL && <Action.OpenInBrowser title="Open Extension Page on GitHub" url={pageURL} />}
                    <Action title="Back" icon={Icon.ArrowLeft} onAction={pop} />
                </ActionPanel>
            }
        />
    );
}
