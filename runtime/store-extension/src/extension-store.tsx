import {
    Action,
    ActionPanel,
    Color,
    confirmAlert,
    environment,
    Icon,
    List,
    showHUD,
    showToast,
    Toast,
    trash,
} from "@raycast/api";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
    accessoryTexts,
    allFilter,
    categories,
    filterEntries,
    folderURL,
    iconURL,
    installedFilter,
    readCatalog,
    searchKeywords,
    sections,
    status,
    type Installed,
    type StoreEntry,
} from "./catalog.ts";
import { gitAvailable, stopRunningGit, StoreRepository } from "./git.ts";
import { filterImages } from "./readme.ts";
import { install, oneAtATime, readInstalled, uninstall, type StoreContext } from "./store.ts";

type Loaded = { entries: StoreEntry[]; installed: Installed; trees: Map<string, string>; commit: string };

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

export default function Command() {
    const cli = process.env.FUDGE_CLI;
    const extensionsDir = process.env.FUDGE_EXTENSIONS_DIR;
    if (!cli || !extensionsDir) {
        return (
            <List>
                <List.EmptyView
                    icon={Icon.ExclamationMark}
                    title="The Extension Store can't run here"
                    description="fudge didn't say where its tool and extensions folder are."
                />
            </List>
        );
    }
    return <Store cli={cli} extensionsDir={extensionsDir} />;
}

function Store({ cli, extensionsDir }: { cli: string; extensionsDir: string }) {
    const repo = useMemo(() => new StoreRepository(path.join(environment.supportPath, "repo")), []);
    const [loaded, setLoaded] = useState<Loaded>();
    const [noGit, setNoGit] = useState(false);
    const [loadError, setLoadError] = useState<string>();
    const [filter, setFilter] = useState(allFilter);
    const [showingDetail, setShowingDetail] = useState(false);
    const [selected, setSelected] = useState<string | null>(null);
    const [readmes, setReadmes] = useState<Record<string, string>>({});

    const load = useCallback(async () => {
        const [entries, installed, trees, commit] = await Promise.all([
            readCatalog(repo.path),
            readInstalled(environment.supportPath),
            repo.trees(),
            repo.commit(),
        ]);
        setLoaded({ entries, installed, trees, commit });
    }, [repo]);

    /** Clones the first time, refreshes after that; the list stays usable meanwhile. */
    const refresh = useCallback(async () => {
        const first = !(await repo.exists());
        const toast = await showToast({
            style: Toast.Style.Animated,
            title: first ? "Downloading the store's list…" : "Updating the store's list…",
        });
        try {
            if (first) await repo.clone();
            else await repo.refresh();
            await load();
            setReadmes({});
            await toast.hide();
        } catch (error) {
            toast.style = Toast.Style.Failure;
            toast.title = first ? "Couldn't download the store's list" : "Couldn't update the store's list";
            toast.message = message(error);
            if (first) setLoadError(message(error));
        }
    }, [repo, load]);

    useEffect(() => {
        void (async () => {
            if (!(await gitAvailable())) {
                setNoGit(true);
                return;
            }
            if (!(await repo.exists())) {
                await refresh();
                return;
            }
            try {
                await load();
            } catch {
                // A copy that can't be read (a clone stopped halfway) is downloaded again.
                await repo.remove();
                await refresh();
                return;
            }
            if (await repo.needsRefresh(new Date())) await refresh();
        })();
        // Unloading the store (leaving it, or turning it off) ends its git, which mustn't go on writing into `repo/`.
        return stopRunningGit;
    }, [repo, load, refresh]);

    // The README of the selected extension, fetched on demand while the detail pane is open.
    useEffect(() => {
        if (!showingDetail || !selected || !loaded || readmes[selected] !== undefined) return;
        const name = selected;
        void (async () => {
            let readme = "";
            try {
                await repo.add(`/extensions/${name}/README.md`);
                const text = await readFile(path.join(repo.path, "extensions", name, "README.md"), "utf8");
                readme = filterImages(text, name, loaded.commit);
            } catch {
                // No README, or it couldn't be fetched: the detail shows the manifest alone.
            }
            setReadmes((current) => ({ ...current, [name]: readme }));
        })();
    }, [showingDetail, selected, loaded, readmes, repo]);

    const context: StoreContext = {
        repo,
        supportPath: environment.supportPath,
        cli,
        extensionsDir,
        confirm: (title, text, primary) => confirmAlert({ title, message: text, primaryAction: { title: primary } }),
        trash: (target) => trash(target),
    };

    const runInstall = (entry: StoreEntry, updating: boolean) =>
        oneAtATime(async () => {
            const toast = await showToast({
                style: Toast.Style.Animated,
                title: `${updating ? "Updating" : "Installing"} ${entry.title}…`,
            });
            try {
                if (!(await install(entry, context))) {
                    await toast.hide();
                    return;
                }
                await load();
                await toast.hide();
                await showHUD(`${updating ? "Updated" : "Installed"} ${entry.title}`);
            } catch (error) {
                toast.style = Toast.Style.Failure;
                toast.title = `Couldn't ${updating ? "update" : "install"} ${entry.title}`;
                toast.message = message(error);
            }
        });

    const runUninstall = (entry: StoreEntry) =>
        oneAtATime(async () => {
            try {
                if (!(await uninstall(entry, context))) return;
                await load();
                await showToast({ style: Toast.Style.Success, title: `Uninstalled ${entry.title}` });
            } catch (error) {
                await showToast({
                    style: Toast.Style.Failure,
                    title: `Couldn't uninstall ${entry.title}`,
                    message: message(error),
                });
            }
        });

    if (noGit) {
        return (
            <List>
                <List.EmptyView
                    icon={Icon.ExclamationMark}
                    title="The Extension Store needs Git"
                    description="Install Apple's Command Line Tools: run `xcode-select --install` in Terminal."
                />
            </List>
        );
    }

    const shown = loaded ? filterEntries(loaded.entries, filter, loaded.installed) : [];
    const { installed: installedRows, other } = sections(shown, loaded?.installed ?? {});
    const item = (entry: StoreEntry) => {
        const state = loaded ? status(entry, loaded.installed, loaded.trees) : "available";
        const icon = loaded ? iconURL(entry, loaded.commit) : undefined;
        return (
            <List.Item
                key={entry.name}
                id={entry.name}
                title={entry.title}
                subtitle={showingDetail ? undefined : entry.description}
                icon={icon ? { source: icon, fallback: Icon.Box } : Icon.Box}
                keywords={searchKeywords(entry)}
                accessories={
                    showingDetail
                        ? undefined
                        : accessoryTexts(entry, state).map((accessory) =>
                              "tag" in accessory
                                  ? {
                                        tag: {
                                            value: accessory.tag,
                                            color: state === "update" ? Color.Orange : Color.Green,
                                        },
                                    }
                                  : { text: accessory.text },
                          )
                }
                detail={<List.Item.Detail markdown={detailMarkdown(entry, loaded?.commit ?? "", readmes[entry.name])} />}
                actions={
                    <ActionPanel>
                        <ActionPanel.Section>
                            {state === "available" && (
                                <Action title="Install" icon={Icon.Download} onAction={() => runInstall(entry, false)} />
                            )}
                            {state === "update" && (
                                <Action
                                    title="Update"
                                    icon={Icon.ArrowClockwise}
                                    shortcut={{ modifiers: ["cmd"], key: "u" }}
                                    onAction={() => runInstall(entry, true)}
                                />
                            )}
                            <Action
                                title={showingDetail ? "Hide Details" : "Show Details"}
                                icon={Icon.Sidebar}
                                shortcut={{ modifiers: ["cmd"], key: "d" }}
                                onAction={() => setShowingDetail((value) => !value)}
                            />
                            {state !== "available" && (
                                <Action
                                    title="Uninstall"
                                    icon={Icon.Trash}
                                    style={Action.Style.Destructive}
                                    shortcut={{ modifiers: ["ctrl"], key: "x" }}
                                    onAction={() => runUninstall(entry)}
                                />
                            )}
                        </ActionPanel.Section>
                        <ActionPanel.Section>
                            {loaded && <Action.OpenInBrowser url={folderURL(entry.name, loaded.commit)} />}
                            <Action.CopyToClipboard title="Copy Name" content={entry.name} />
                            <Action
                                title="Refresh"
                                icon={Icon.ArrowClockwise}
                                shortcut={{ modifiers: ["cmd"], key: "r" }}
                                onAction={() => void refresh()}
                            />
                        </ActionPanel.Section>
                    </ActionPanel>
                }
            />
        );
    };

    return (
        <List
            isLoading={!loaded && !loadError}
            isShowingDetail={showingDetail}
            searchBarPlaceholder="Search extensions"
            onSelectionChange={setSelected}
            searchBarAccessory={
                <List.Dropdown tooltip="Category" value={filter} onChange={setFilter}>
                    <List.Dropdown.Item title="All" value={allFilter} />
                    <List.Dropdown.Item title="Installed" value={installedFilter} />
                    <List.Dropdown.Section title="Categories">
                        {categories(loaded?.entries ?? []).map((category) => (
                            <List.Dropdown.Item key={category} title={category} value={`category:${category}`} />
                        ))}
                    </List.Dropdown.Section>
                </List.Dropdown>
            }
        >
            {loadError && !loaded ? (
                <List.EmptyView icon={Icon.ExclamationMark} title="Couldn't load the store" description={loadError} />
            ) : (
                <List.EmptyView icon={Icon.MagnifyingGlass} title="No extensions found" />
            )}
            <List.Section title="Installed">{installedRows.map(item)}</List.Section>
            <List.Section title="Extensions">{other.map(item)}</List.Section>
        </List>
    );
}

/** The detail pane: the manifest's facts, then the README once it's fetched. */
function detailMarkdown(entry: StoreEntry, commit: string, readme: string | undefined): string {
    const commands = entry.commands
        .map((command) => `- **${command.title}**${command.description ? `: ${command.description}` : ""}`)
        .join("\n");
    const facts = [
        entry.author && `**Author:** ${entry.author}`,
        entry.categories.length > 0 && `**Categories:** ${entry.categories.join(", ")}`,
        entry.license && `**License:** ${entry.license}`,
        commit && `[Source on GitHub](${folderURL(entry.name, commit)})`,
    ].filter(Boolean);
    return [
        `# ${entry.title}`,
        entry.description,
        `## Commands\n\n${commands}`,
        facts.join("  \n"),
        readme === undefined ? "_Loading the README…_" : readme && `---\n\n${readme}`,
    ]
        .filter(Boolean)
        .join("\n\n");
}
