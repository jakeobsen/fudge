import { Action, ActionPanel, getPreferenceValues, Grid, Icon, LocalStorage } from "@raycast/api";
import { release } from "node:os";
import { useEffect, useState } from "react";
import {
    drawable,
    forget,
    groups,
    macOSVersion,
    newestEmojiVersion,
    readRecent,
    recentEntries,
    recentKey,
    remember,
    toned,
    type EmojiEntry,
} from "./emoji.ts";

/** What this Mac draws, read once. */
const available = drawable(newestEmojiVersion(macOSVersion(release())));

export default function Command() {
    const { skinTone } = getPreferenceValues<{ skinTone?: string }>();
    // Null until Recently Used is read, so the first emoji shown, and selected, is the most recent.
    const [recent, setRecent] = useState<string[] | null>(null);

    useEffect(() => {
        LocalStorage.getItem<string>(recentKey).then(
            (stored) => setRecent(readRecent(stored)),
            () => setRecent([]),
        );
    }, []);

    const update = (change: (current: string[]) => string[]) =>
        setRecent((current) => {
            const next = change(current ?? []);
            LocalStorage.setItem(recentKey, JSON.stringify(next)).catch(() => {});
            return next;
        });

    const item = (entry: EmojiEntry, inRecent: boolean) => {
        const shown = toned(entry, skinTone);
        const used = () => update((current) => remember(current, entry.emoji));
        return (
            <Grid.Item
                key={inRecent ? `recent-${entry.emoji}` : entry.emoji}
                id={inRecent ? `recent-${entry.emoji}` : entry.emoji}
                content={shown}
                title={entry.name}
                keywords={entry.keywords}
                actions={
                    <ActionPanel>
                        <ActionPanel.Section>
                            <Action.Paste title="Paste Emoji" content={shown} onPaste={used} />
                            <Action.CopyToClipboard title="Copy Emoji" content={shown} onCopy={used} />
                            <Action.CopyToClipboard
                                title="Copy Name"
                                content={entry.name}
                                shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
                            />
                        </ActionPanel.Section>
                        {inRecent && (
                            <ActionPanel.Section>
                                <Action
                                    title="Remove from Recently Used"
                                    icon={Icon.XMarkCircle}
                                    shortcut={{ modifiers: ["ctrl"], key: "x" }}
                                    onAction={() => update((current) => forget(current, entry.emoji))}
                                />
                                <Action
                                    title="Clear Recently Used"
                                    icon={Icon.Trash}
                                    style={Action.Style.Destructive}
                                    shortcut={{ modifiers: ["ctrl", "shift"], key: "x" }}
                                    onAction={() => update(() => [])}
                                />
                            </ActionPanel.Section>
                        )}
                    </ActionPanel>
                }
            />
        );
    };

    if (recent === null) return <Grid columns={8} isLoading searchBarPlaceholder="Search emoji by name or keyword" />;
    const recentlyUsed = recentEntries(recent, available);
    return (
        <Grid columns={8} searchBarPlaceholder="Search emoji by name or keyword">
            {recentlyUsed.length > 0 && (
                <Grid.Section title="Recently Used">{recentlyUsed.map((entry) => item(entry, true))}</Grid.Section>
            )}
            {groups.map((group, index) => (
                <Grid.Section key={group} title={group}>
                    {available.filter((entry) => entry.group === index).map((entry) => item(entry, false))}
                </Grid.Section>
            ))}
        </Grid>
    );
}
