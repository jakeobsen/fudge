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
import path from "node:path";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
import {
    checkFolder,
    CompatibilityChecks,
    compatibilityText,
    isNotCompatible,
    readCompatibility,
    rememberCompatibility,
    scannerIdentity,
    type Compatibility,
} from "./compatibility.ts";
import { gitAvailable, stopRunningGit, StoreRepository } from "./git.ts";
import { detailMarkdown, fetchReadme } from "./readme.ts";
import { RestingWork } from "./resting.ts";
import { install, oneAtATime, readInstalled, uninstall, type StoreContext } from "./store.ts";

type Loaded = { entries: StoreEntry[]; installed: Installed; trees: Map<string, string>; commit: string };
/** The cached scans this Fudge's scanner wrote, by tree id, and the trees whose check failed in this run. */
type Checked = { scanner: string; results: Map<string, Compatibility>; failed: Set<string> };

const tagColor = (tag: string) =>
    tag === "Not compatible" ? Color.Red : tag === "Update available" ? Color.Orange : Color.Green;

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
                    description="Fudge didn't say where its tool and extensions folder are."
                />
            </List>
        );
    }
    return <Store cli={cli} extensionsDir={extensionsDir} />;
}

function Store({ cli, extensionsDir }: { cli: string; extensionsDir: string }) {
    const repo = useMemo(() => new StoreRepository(path.join(environment.supportPath, "repo")), []);
    const [loaded, setLoaded] = useState<Loaded>();
    // Whether anything has loaded yet, for `refresh`, which mustn't change with every load.
    const hasLoaded = useRef(false);
    const [noGit, setNoGit] = useState(false);
    const [loadError, setLoadError] = useState<string>();
    const [filter, setFilter] = useState(allFilter);
    const [showingDetail, setShowingDetail] = useState(false);
    const [selected, setSelected] = useState<string | null>(null);
    // The READMEs fetched, by their folder's tree id, so a folder that hasn't changed is never fetched again.
    const [readmes, setReadmes] = useState<Record<string, string>>({});
    const readmesNow = useRef(readmes);
    readmesNow.current = readmes;
    const [checked, setChecked] = useState<Checked>({ scanner: "", results: new Map(), failed: new Set() });
    // The latest, for the checks' callbacks, which outlive a render.
    const checkedNow = useRef(checked);
    checkedNow.current = checked;

    const load = useCallback(async () => {
        const scanner = await scannerIdentity(cli);
        const [entries, installed, trees, commit, results] = await Promise.all([
            readCatalog(repo.path),
            readInstalled(environment.supportPath),
            repo.trees(),
            repo.commit(),
            readCompatibility(environment.supportPath, scanner),
        ]);
        setLoaded({ entries, installed, trees, commit });
        setChecked((current) => ({ scanner, results, failed: current.scanner === scanner ? current.failed : new Set() }));
        hasLoaded.current = true;
        setLoadError(undefined);
    }, [repo, cli]);

    /**
     * Clones the first time, refreshes after that; the list stays usable meanwhile. Like every git operation of the
     * store's, it waits its turn (`oneAtATime`), so it never runs during an install or a README fetch. A failure
     * before anything has loaded shows in the load-error view, whose Refresh tries again.
     */
    const refresh = useCallback(
        () =>
            oneAtATime(async () => {
                const first = !(await repo.exists());
                const toast = await showToast({
                    style: Toast.Style.Animated,
                    title: first ? "Downloading the store's list…" : "Updating the store's list…",
                });
                try {
                    if (first) await repo.clone();
                    else await repo.refresh();
                    await load();
                    await toast.hide();
                } catch (error) {
                    toast.style = Toast.Style.Failure;
                    toast.title = first ? "Couldn't download the store's list" : "Couldn't update the store's list";
                    toast.message = message(error);
                    if (!hasLoaded.current) setLoadError(message(error));
                }
            }),
        [repo, load],
    );

    /**
     * Opens the copy: clones it the first time, clones it again when it can't be read (a clone stopped halfway), and
     * refreshes it when it's a day old, or always when `retry` (the load-error view's Refresh).
     */
    const open = useCallback(
        async (retry: boolean) => {
            if (retry) setLoadError(undefined);
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
                await repo.remove();
                await refresh();
                return;
            }
            if (retry || (await repo.needsRefresh(new Date()))) await refresh();
        },
        [repo, load, refresh],
    );

    useEffect(() => {
        void open(false);
        // Unloading the store (leaving it, or turning it off) ends its git, which mustn't go on writing into `repo/`.
        return stopRunningGit;
    }, [open]);

    // The README of the row the selection rests on, with the detail pane open, as the compatibility check waits
    // (`RestingWork`): moving through rows fetches nothing, and a folder's README is fetched once per tree.
    const readmeFetches = useMemo(
        () =>
            new RestingWork<string>({
                done: (key) => readmesNow.current[key.split("\0")[1]!] !== undefined,
                run: (key, cancelled) =>
                    oneAtATime(async () => (cancelled() ? undefined : fetchReadme(repo, key.split("\0")[0]!))),
                changed: (key, readme) =>
                    setReadmes((current) => ({ ...current, [key.split("\0")[1]!]: readme === "failed" ? "" : readme })),
            }),
        [repo],
    );
    useEffect(() => () => readmeFetches.stop(), [readmeFetches]);

    const context: StoreContext = useMemo(
        () => ({
            repo,
            supportPath: environment.supportPath,
            cli,
            extensionsDir,
            confirm: (title, text, primary) => confirmAlert({ title, message: text, primaryAction: { title: primary } }),
            trash: (target) => trash(target),
        }),
        [repo, cli, extensionsDir],
    );

    // The detail's Compatibility line: the selected row is scanned once the selection rests on it, in the git queue,
    // and its result is cached by tree. Moving on cancels it.
    const checks = useMemo(
        () =>
            new CompatibilityChecks({
                cached: (tree) => checkedNow.current.results.get(tree),
                check: (dir, tree, cancelled) =>
                    oneAtATime(async () => {
                        const result = await checkFolder(dir, context, cancelled);
                        if (!result) return undefined;
                        await rememberCompatibility(environment.supportPath, checkedNow.current.scanner, tree, result);
                        return result;
                    }),
                changed: (_dir, tree, result) =>
                    setChecked((current) => {
                        if (result === "failed") return { ...current, failed: new Set(current.failed).add(tree) };
                        const results = new Map(current.results);
                        results.delete(tree);
                        return { ...current, results: results.set(tree, result) };
                    }),
            }),
        [context],
    );
    useEffect(() => () => checks.stop(), [checks]);

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

    const shown = loaded ? filterEntries(loaded.entries, filter, loaded.installed) : [];
    const { installed: installedRows, other } = sections(shown, loaded?.installed ?? {});
    // Only the selected row carries its actions (the first row until something is selected): 3,500 action panels
    // would make every render take seconds. Moving the selection renders the new row's.
    const actionsFor = selected ?? (installedRows[0] ?? other[0])?.dir;
    const checking = showingDetail ? actionsFor : undefined;
    const checkingTree = checking ? loaded?.trees.get(checking) : undefined;
    useEffect(() => checks.select(checking, checkingTree), [checks, checking, checkingTree]);
    // A row's id is its folder in the repository (`StoreEntry.dir`), which `readCatalog` checked.
    useEffect(
        () => readmeFetches.select(checking && checkingTree ? `${checking}\0${checkingTree}` : undefined),
        [readmeFetches, checking, checkingTree],
    );

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

    /** The detail's Compatibility line for a row: its cached result, or the check waiting, running or failed. */
    const compatibilityFor = (tree: string | undefined) => {
        if (!tree) return undefined;
        const result = checked.results.get(tree);
        return compatibilityText(result ?? (checked.failed.has(tree) ? "failed" : "checking"));
    };
    const item = (entry: StoreEntry) => {
        const state = loaded ? status(entry, loaded.installed, loaded.trees) : "available";
        const icon = loaded ? iconURL(entry, loaded.commit) : undefined;
        const tree = loaded?.trees.get(entry.dir);
        const notCompatible = tree !== undefined && isNotCompatible(checked.results.get(tree));
        return (
            <List.Item
                key={entry.dir}
                id={entry.dir}
                title={entry.title}
                subtitle={showingDetail ? undefined : entry.description}
                icon={icon ? { source: icon, fallback: Icon.Box } : Icon.Box}
                keywords={searchKeywords(entry)}
                accessories={
                    showingDetail
                        ? undefined
                        : accessoryTexts(entry, state, notCompatible).map((accessory) =>
                              "tag" in accessory
                                  ? { tag: { value: accessory.tag, color: tagColor(accessory.tag) } }
                                  : { text: accessory.text },
                          )
                }
                detail={
                    // Built only while the pane is open: 3,500 rows' markdown would slow every render.
                    showingDetail ? (
                        <List.Item.Detail
                            markdown={detailMarkdown(
                                entry,
                                loaded?.commit ?? "",
                                tree === undefined ? undefined : readmes[tree],
                                compatibilityFor(tree),
                            )}
                        />
                    ) : undefined
                }
                actions={
                    entry.dir !== actionsFor ? undefined : (
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
                            {loaded && <Action.OpenInBrowser url={folderURL(entry.dir, loaded.commit)} />}
                            <Action.CopyToClipboard title="Copy Name" content={entry.name} />
                            <Action
                                title="Refresh"
                                icon={Icon.ArrowClockwise}
                                shortcut={{ modifiers: ["cmd"], key: "r" }}
                                onAction={() => void refresh()}
                            />
                        </ActionPanel.Section>
                    </ActionPanel>
                    )
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
                <List.EmptyView
                    icon={Icon.ExclamationMark}
                    title="Couldn't load the store"
                    description={loadError}
                    actions={
                        <ActionPanel>
                            <Action
                                title="Refresh"
                                icon={Icon.ArrowClockwise}
                                shortcut={{ modifiers: ["cmd"], key: "r" }}
                                onAction={() => void open(true)}
                            />
                        </ActionPanel>
                    }
                />
            ) : (
                <List.EmptyView icon={Icon.MagnifyingGlass} title="No extensions found" />
            )}
            <List.Section title="Installed">{installedRows.map(item)}</List.Section>
            <List.Section title="Extensions">{other.map(item)}</List.Section>
        </List>
    );
}
