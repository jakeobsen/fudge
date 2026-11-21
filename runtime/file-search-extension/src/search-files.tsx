import {
    Action,
    ActionPanel,
    Alert,
    Clipboard,
    confirmAlert,
    getPreferenceValues,
    Icon,
    List,
    LocalStorage,
    showHUD,
    showToast,
    Toast,
    trash,
    type Keyboard,
} from "@raycast/api";
import { searchFiles, type FoundFile } from "fudge:app";
import { homedir } from "node:os";
import { useEffect, useState } from "react";
import { detailFields, emptyView, searchLimit, whereText } from "./files.ts";

const shortcuts = {
    quickLook: { modifiers: ["cmd"], key: "y" },
    openWith: { modifiers: ["cmd"], key: "o" },
    copyPath: { modifiers: ["cmd", "shift"], key: "c" },
    copyFile: { modifiers: ["cmd", "opt"], key: "c" },
    trash: { modifiers: ["ctrl"], key: "x" },
    toggleDetail: { modifiers: ["cmd", "shift"], key: "d" },
} satisfies Record<string, Keyboard.Shortcut>;

/** The LocalStorage key that remembers whether the detail pane is shown. */
const showingDetailKey = "showingDetail";

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

export default function Command() {
    const home = homedir();
    const { searchIn } = getPreferenceValues<{ searchIn?: string }>();
    const [query, setQuery] = useState("");
    const [files, setFiles] = useState<FoundFile[]>([]);
    const [isLoading, setIsLoading] = useState(true);
    const [showingDetail, setShowingDetail] = useState(true);

    useEffect(() => {
        LocalStorage.getItem<boolean>(showingDetailKey).then(
            (stored) => typeof stored === "boolean" && setShowingDetail(stored),
            () => {},
        );
    }, []);

    useEffect(() => {
        // A newer search makes this one's answer stale, and it's dropped. The list keeps the last answer meanwhile.
        let current = true;
        setIsLoading(true);
        searchFiles(query, searchLimit).then(
            (found) => {
                if (!current) return;
                setFiles(found);
                setIsLoading(false);
            },
            (error: unknown) => {
                if (!current) return;
                setFiles([]);
                setIsLoading(false);
                void showToast({ style: Toast.Style.Failure, title: "Couldn't search files", message: message(error) });
            },
        );
        return () => {
            current = false;
        };
    }, [query]);

    const toggleDetail = () => {
        setShowingDetail(!showingDetail);
        LocalStorage.setItem(showingDetailKey, !showingDetail).catch(() => {});
    };
    const trashed = (file: FoundFile) => setFiles((current) => current.filter((other) => other.path !== file.path));
    const empty = emptyView(query, searchIn);

    return (
        <List
            filtering={false}
            throttle
            isLoading={isLoading}
            isShowingDetail={showingDetail}
            onSearchTextChange={setQuery}
            searchBarPlaceholder="Search files and folders by name"
        >
            {!isLoading && files.length === 0 && (
                <List.EmptyView icon={Icon.MagnifyingGlass} title={empty.title} description={empty.description} />
            )}
            {files.map((file) => (
                <List.Item
                    key={file.path}
                    id={file.path}
                    title={file.name}
                    subtitle={whereText(file, home)}
                    icon={{ fileIcon: file.path }}
                    accessories={[{ date: file.modified }]}
                    quickLook={{ path: file.path, name: file.name }}
                    detail={<FileDetail file={file} home={home} />}
                    actions={
                        <FileActions
                            file={file}
                            showingDetail={showingDetail}
                            onToggleDetail={toggleDetail}
                            onTrashed={trashed}
                        />
                    }
                />
            ))}
        </List>
    );
}

function FileDetail({ file, home }: { file: FoundFile; home: string }) {
    return (
        <List.Item.Detail
            metadata={
                <List.Item.Detail.Metadata>
                    {detailFields(file, home).map((field) => (
                        <List.Item.Detail.Metadata.Label key={field.title} title={field.title} text={field.text} />
                    ))}
                </List.Item.Detail.Metadata>
            }
        />
    );
}

function FileActions({
    file,
    showingDetail,
    onToggleDetail,
    onTrashed,
}: {
    file: FoundFile;
    showingDetail: boolean;
    onToggleDetail: () => void;
    onTrashed: (file: FoundFile) => void;
}) {
    return (
        <ActionPanel>
            <ActionPanel.Section>
                <Action.Open title="Open" target={file.path} />
                <Action.ShowInFinder path={file.path} />
                <Action.ToggleQuickLook shortcut={shortcuts.quickLook} />
                <Action.OpenWith title="Open With…" path={file.path} shortcut={shortcuts.openWith} />
            </ActionPanel.Section>
            <ActionPanel.Section>
                <Action.CopyToClipboard title="Copy Path" content={file.path} shortcut={shortcuts.copyPath} />
                <Action title="Copy File" icon={Icon.Clipboard} shortcut={shortcuts.copyFile} onAction={() => copyFile(file)} />
            </ActionPanel.Section>
            <ActionPanel.Section>
                <Action
                    title="Move to Trash"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    shortcut={shortcuts.trash}
                    onAction={() => moveToTrash(file, onTrashed)}
                />
            </ActionPanel.Section>
            <ActionPanel.Section>
                <Action
                    title={showingDetail ? "Hide Details" : "Show Details"}
                    icon={Icon.Sidebar}
                    shortcut={shortcuts.toggleDetail}
                    onAction={onToggleDetail}
                />
            </ActionPanel.Section>
        </ActionPanel>
    );
}

async function copyFile(file: FoundFile) {
    await Clipboard.copy({ file: file.path });
    await showHUD("Copied File");
}

async function moveToTrash(file: FoundFile, onTrashed: (file: FoundFile) => void) {
    const confirmed = await confirmAlert({
        title: `Move “${file.name}” to the Trash?`,
        primaryAction: { title: "Move to Trash", style: Alert.ActionStyle.Destructive },
    });
    if (!confirmed) return;
    try {
        await trash(file.path);
    } catch (error) {
        await showToast({ style: Toast.Style.Failure, title: "Couldn't move it to the Trash", message: message(error) });
        return;
    }
    onTrashed(file);
    await showToast({ style: Toast.Style.Success, title: "Moved to Trash" });
}
