import { Action, ActionPanel, List, showToast, Toast, type LaunchProps } from "@raycast/api";

export default function Command(props: LaunchProps) {
    return (
        <List>
            <List.Item
                title={String(props.arguments)}
                actions={
                    <ActionPanel>
                        <Action.CopyToClipboard content="hello" />
                        <Action title="Toast" onAction={() => showToast({ style: Toast.Style.Success, title: "Hi" })} />
                    </ActionPanel>
                }
            />
        </List>
    );
}
