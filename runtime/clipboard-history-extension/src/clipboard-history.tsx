import {
    Action,
    ActionPanel,
    Alert,
    confirmAlert,
    Icon,
    List,
    openExtensionPreferences,
    showHUD,
    showToast,
    Toast,
    type Image,
    type Keyboard,
} from "@raycast/api";
import {
    clearClipboardHistory,
    clipboardImage,
    copyClipboardEntry,
    deleteClipboardEntry,
    listClipboardHistory,
    pasteClipboardEntry,
    pinClipboardEntry,
    type ClipboardEntry,
    type ClipboardHistory,
} from "fudge:app";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { detailFields, detailMarkdown, keywords, sections, title, type DetailField } from "./entries.ts";

const shortcuts = {
    pin: { modifiers: ["cmd", "shift"], key: "p" },
    delete: { modifiers: ["ctrl"], key: "x" },
    deleteAll: { modifiers: ["ctrl", "shift"], key: "x" },
} satisfies Record<string, Keyboard.Shortcut>;

const icons: Record<ClipboardEntry["kind"], Image.ImageLike> = {
    text: Icon.Text,
    link: Icon.Link,
    image: Icon.Image,
    files: Icon.Document,
};

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

async function failed(title: string, error: unknown) {
    await showToast({ style: Toast.Style.Failure, title, message: message(error) });
}

/** What an entry shows, worked out once per load rather than on every render. */
type Shown = { entry: ClipboardEntry; title: string; keywords: string[]; markdown?: string; fields: DetailField[] };

export default function Command() {
    const [history, setHistory] = useState<ClipboardHistory | null>(null);
    // Why the history couldn't be read, while there's nothing to show instead.
    const [loadError, setLoadError] = useState<string | null>(null);
    const [selectedId, setSelectedId] = useState<string | null>(null);
    // An image entry's file, by id, once read; null when it couldn't be.
    const [images, setImages] = useState<Record<string, string | null>>({});
    const loads = useRef(0);
    const askedForImage = useRef(new Set<string>());

    const reload = useCallback(async () => {
        // Only the latest load's answer is shown.
        const load = ++loads.current;
        try {
            const answer = await listClipboardHistory();
            if (load !== loads.current) return;
            setHistory(answer);
            setLoadError(null);
        } catch (error) {
            if (load !== loads.current) return;
            setLoadError(message(error));
            setHistory((current) => current ?? { on: true, entries: [] });
            await failed("Couldn't read the clipboard history", error);
        }
    }, []);

    useEffect(() => {
        void reload();
    }, [reload]);

    const shown = useMemo(
        () =>
            sections(history?.entries ?? []).map((section) => ({
                title: section.title,
                entries: section.entries.map(
                    (entry): Shown => ({
                        entry,
                        title: title(entry),
                        keywords: keywords(entry),
                        markdown: entry.kind === "image" ? undefined : detailMarkdown(entry),
                        fields: detailFields(entry),
                    }),
                ),
            })),
        [history],
    );

    // The selected entry, or the first one until the app says which is selected. Only its image is read.
    const all = shown.flatMap((section) => section.entries.map((item) => item.entry));
    const selected = all.find((entry) => entry.id === selectedId) ?? all[0];
    const selectedImage = selected?.kind === "image" ? selected.id : undefined;
    useEffect(() => {
        if (selectedImage === undefined || askedForImage.current.has(selectedImage)) return;
        askedForImage.current.add(selectedImage);
        clipboardImage(selectedImage).then(
            ({ path }) => setImages((current) => ({ ...current, [selectedImage]: path })),
            (error: unknown) => {
                setImages((current) => ({ ...current, [selectedImage]: null }));
                void failed("Couldn't show the image", error);
            },
        );
    }, [selectedImage]);

    if (history && !history.on) {
        return (
            <List>
                <List.EmptyView
                    icon={Icon.Clipboard}
                    title="Clipboard history is off"
                    actions={
                        <ActionPanel>
                            <Action title="Open Clipboard History Settings" icon={Icon.Gear} onAction={openSettings} />
                        </ActionPanel>
                    }
                />
            </List>
        );
    }

    const empty = history !== null && history.entries.length === 0;
    return (
        <List
            isLoading={history === null}
            isShowingDetail={!empty}
            searchBarPlaceholder="Search what you copied"
            onSelectionChange={setSelectedId}
        >
            {empty &&
                (loadError === null ? (
                    <List.EmptyView icon={Icon.Clipboard} title="No Copies Yet" description="What you copy shows up here." />
                ) : (
                    <List.EmptyView icon={Icon.Warning} title="Couldn't read the clipboard history" description={loadError} />
                ))}
            {shown.map((section) => (
                <List.Section key={section.title} title={section.title}>
                    {section.entries.map((item) => (
                        <List.Item
                            key={item.entry.id}
                            id={item.entry.id}
                            title={item.title}
                            keywords={item.keywords}
                            icon={icons[item.entry.kind]}
                            accessories={[{ date: item.entry.copiedAt }]}
                            detail={<EntryDetail item={item} image={images[item.entry.id]} />}
                            actions={<EntryActions entry={item.entry} onChange={reload} />}
                        />
                    ))}
                </List.Section>
            ))}
        </List>
    );
}

/** `image`: an image entry's file; undefined while it's being read, null when it couldn't be. */
function EntryDetail({ item, image }: { item: Shown; image: string | null | undefined }) {
    const isImage = item.entry.kind === "image";
    return (
        <List.Item.Detail
            isLoading={isImage && image === undefined}
            markdown={isImage ? (image ? detailMarkdown(item.entry, image) : undefined) : item.markdown}
            metadata={
                <List.Item.Detail.Metadata>
                    {item.fields.map((field) => (
                        <List.Item.Detail.Metadata.Label key={field.title} title={field.title} text={field.text} />
                    ))}
                </List.Item.Detail.Metadata>
            }
        />
    );
}

function EntryActions({ entry, onChange }: { entry: ClipboardEntry; onChange: () => Promise<void> }) {
    /** Runs a change, then loads the history again; a failure is a toast titled `failure`. */
    const change = (failure: string, work: () => Promise<void>) => async () => {
        try {
            await work();
        } catch (error) {
            await failed(failure, error);
            return;
        }
        await onChange();
    };
    return (
        <ActionPanel>
            <ActionPanel.Section>
                <Action title="Paste" icon={Icon.Clipboard} onAction={change("Couldn't paste", () => pasteClipboardEntry(entry.id))} />
                <Action
                    title="Copy"
                    icon={Icon.CopyClipboard}
                    onAction={change("Couldn't copy", async () => {
                        await copyClipboardEntry(entry.id);
                        await showHUD("Copied");
                    })}
                />
            </ActionPanel.Section>
            <ActionPanel.Section>
                <Action
                    title={entry.pinned ? "Unpin" : "Pin"}
                    icon={entry.pinned ? Icon.PinDisabled : Icon.Pin}
                    shortcut={shortcuts.pin}
                    onAction={change(entry.pinned ? "Couldn't unpin" : "Couldn't pin", () => pinClipboardEntry(entry.id, !entry.pinned))}
                />
            </ActionPanel.Section>
            <ActionPanel.Section>
                <Action
                    title="Delete"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    shortcut={shortcuts.delete}
                    onAction={change("Couldn't delete", () => deleteClipboardEntry(entry.id))}
                />
                <Action
                    title="Delete All…"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    shortcut={shortcuts.deleteAll}
                    onAction={() => deleteAll(onChange)}
                />
            </ActionPanel.Section>
        </ActionPanel>
    );
}

async function deleteAll(onChange: () => Promise<void>) {
    const confirmed = await confirmAlert({
        title: "Delete All Copies?",
        message: "Pinned copies are deleted too.",
        primaryAction: { title: "Delete All", style: Alert.ActionStyle.Destructive },
    });
    if (!confirmed) return;
    try {
        await clearClipboardHistory();
    } catch (error) {
        await failed("Couldn't delete the history", error);
        return;
    }
    await onChange();
}

async function openSettings() {
    try {
        await openExtensionPreferences();
    } catch (error) {
        await failed("Couldn't open the settings", error);
    }
}
