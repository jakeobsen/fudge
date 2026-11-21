import { Action, ActionPanel, Detail, Icon, List, useNavigation } from "@raycast/api";
import os from "node:os";
import { useEffect, useMemo, useRef, useState } from "react";
import { causeOf, cleanOutput, failureMarkdown, failureReport, type FailureDetails } from "./failure.ts";
import { spawnProgram } from "./git.ts";
import { systemProxy } from "./proxy.ts";

/**
 * What a failure shows and copies: its output and command cleaned, its likely cause, and what Copy Error copies, with
 * Fudge's version once `fudge version` has said it.
 */
function useFailure(title: string, details: FailureDetails, cli: string) {
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
    const report = failureReport(title, cause, { ...details, command }, output, version);
    return { output, cause, report };
}

/**
 * A failed install or update (SPEC-116): the title, the likely cause in plain words, and the end of the output in a
 * code block. ↵ tries again, ⌘C copies everything (the command, its exit, Fudge's version and all the output), and the
 * extension's page on GitHub is one action away. Esc, or Back, goes back to the list.
 */
export function FailureView(props: {
    title: string;
    details: FailureDetails;
    /** The extension's folder on GitHub, when the list has loaded. */
    pageURL?: string;
    /** The `fudge` tool, asked for its version only for Copy Error's text. */
    cli: string;
    retry: () => void;
    /** What ↵ is called: Try Again, or the list's Refresh. */
    retryTitle?: string;
}) {
    const { title, details, pageURL, cli, retry, retryTitle = "Try Again" } = props;
    const { pop } = useNavigation();
    const { output, cause, report } = useFailure(title, details, cli);
    // One retry per view: a second ↵ before it's gone does nothing.
    const retried = useRef(false);

    return (
        <Detail
            navigationTitle={title}
            markdown={failureMarkdown(title, cause, output)}
            actions={
                <ActionPanel>
                    <Action
                        title={retryTitle}
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
                        content={report}
                    />
                    {pageURL && <Action.OpenInBrowser title="Open Extension Page on GitHub" url={pageURL} />}
                    <Action title="Back" icon={Icon.ArrowLeft} onAction={pop} />
                </ActionPanel>
            }
        />
    );
}

/**
 * The store's list failing to download before it has ever loaded (SPEC-116 §1), as the list's empty view: the title,
 * the likely cause (a clone that can't reach GitHub says so, with the proxy note), ↵ and ⌘R Refresh, ⌘C Copy Error, and
 * ⌘D Show Details, the failure view with the end of git's output.
 */
export function LoadFailure(props: { title: string; details: FailureDetails; cli: string; refresh: () => void }) {
    const { title, details, cli, refresh } = props;
    const { push } = useNavigation();
    const { cause, report } = useFailure(title, details, cli);
    return (
        <List.EmptyView
            icon={Icon.ExclamationMark}
            title={title}
            description={cause.text}
            actions={
                <ActionPanel>
                    <Action
                        title="Refresh"
                        icon={Icon.ArrowClockwise}
                        shortcut={{ modifiers: ["cmd"], key: "r" }}
                        onAction={refresh}
                    />
                    <Action.CopyToClipboard
                        title="Copy Error"
                        shortcut={{ modifiers: ["cmd"], key: "c" }}
                        content={report}
                    />
                    <Action
                        title="Show Details"
                        icon={Icon.Document}
                        shortcut={{ modifiers: ["cmd"], key: "d" }}
                        onAction={() =>
                            push(
                                <FailureView
                                    title={title}
                                    details={details}
                                    cli={cli}
                                    retry={refresh}
                                    retryTitle="Refresh"
                                />,
                            )
                        }
                    />
                </ActionPanel>
            }
        />
    );
}
