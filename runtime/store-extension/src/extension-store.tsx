import {
    Action,
    ActionPanel,
    Color,
    confirmAlert,
    environment,
    Icon,
    List,
    showToast,
    Toast,
    trash,
    useNavigation,
    type LaunchProps,
} from "@raycast/api";
import path from "node:path";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
    accessoryTexts,
    commandTitles,
    allFilter,
    categories,
    filterEntries,
    folderURL,
    iconURL,
    installedFilter,
    installingTag,
    failedInstallTag,
    failedUpdateTag,
    readCatalog,
    rowActions,
    searchKeywords,
    sections,
    status,
    updatingTag,
    type Installed,
    type StoreEntry,
} from "./catalog.ts";
import {
    checkFolder,
    CompatibilityChecks,
    compatibilityText,
    compatibilityTag,
    readCompatibility,
    rememberCompatibility,
    scannerIdentity,
    type Compatibility,
} from "./compatibility.ts";
import { gitAvailable, stopRunningGit, StoreRepository } from "./git.ts";
import { detailMarkdown, fetchReadme, refetching, shownReadme } from "./readme.ts";
import { RestingWork } from "./resting.ts";
import type { FailureDetails } from "./failure.ts";
import { FailureView, LoadFailure, NeedsGit } from "./failure-view.tsx";
import {
    failureDetails,
    failureLog,
    installPressed,
    InstallPresses,
    oneAtATime,
    readInstalled,
    uninstall,
    type InstallView,
    type StoreContext,
} from "./store.ts";
import { systemProbe } from "./build-records.ts";
import { heldRefresh, heldRefreshMessage, openCopy, OtherBuilds, settledNotice } from "./other-builds.ts";
import { askForNotifications, commandLineToolsReady, installEnded, logToFudge, nextNotificationClick } from "fudge:app";
import {
    followClicks,
    LaunchTarget,
    openNoticeTarget,
    pruneSavedFailures,
    removeSavedFailure,
    reportEnd,
    RowMarks,
    saveFailure,
    type FailureMark,
    type NoticeTarget,
} from "./notices.ts";
import { installedWithoutSwift, type SwiftPartsChoice } from "./swift-parts.ts";
import { SwiftPartsView } from "./swift-parts-view.tsx";

/** A failure the store had goes into `Fudge.log` too, with its output (SPEC-124); writing it never fails a step. */
const logFailure = (title: string, error: unknown) => void logToFudge("error", failureLog(title, failureDetails(error))).catch(() => {});
/** A line of the store's own in `Fudge.log`, such as a build's record it couldn't write; never fails a step. */
const logLine = (line: string) => void logToFudge("error", line).catch(() => {});

/** `withoutSwift`: the installed extensions built without their part written in Swift (SPEC-145 §3). */
type Loaded = {
    entries: StoreEntry[];
    installed: Installed;
    trees: Map<string, string>;
    commit: string;
    withoutSwift: ReadonlySet<string>;
};
/** The cached scans this Fudge's scanner wrote, by tree id, and the trees whose check failed in this run. */
type Checked = { scanner: string; results: Map<string, Compatibility>; failed: Set<string> };

const tagColor = (tag: string) =>
    tag === "Not compatible" || tag === failedInstallTag || tag === failedUpdateTag
        ? Color.Red
        : tag === "Update available" || tag === "Partly compatible"
          ? Color.Orange
          : tag === installingTag || tag === updatingTag
            ? Color.Blue
            : Color.Green;

const message = (error: unknown) => (error instanceof Error ? error.message : String(error));

export default function Command(props: LaunchProps) {
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
    return <Store cli={cli} extensionsDir={extensionsDir} launchContext={props.launchContext} />;
}

function Store({ cli, extensionsDir, launchContext }: { cli: string; extensionsDir: string; launchContext?: unknown }) {
    const { push } = useNavigation();
    const repo = useMemo(() => new StoreRepository(path.join(environment.supportPath, "repo")), []);
    const [loaded, setLoaded] = useState<Loaded>();
    // Whether anything has loaded yet, for `refresh`, which mustn't change with every load.
    const hasLoaded = useRef(false);
    const [noGit, setNoGit] = useState(false);
    // The list's download failing before anything has loaded: its title and what failed, for `LoadFailure`.
    const [loadError, setLoadError] = useState<{ title: string; details: FailureDetails }>();
    const [filter, setFilter] = useState(allFilter);
    const [showingDetail, setShowingDetail] = useState(false);
    const [selected, setSelected] = useState<string | null>(null);
    // The READMEs fetched, by their folder's tree id, so a folder that hasn't changed is never fetched again.
    const [readmes, setReadmes] = useState<Record<string, string>>({});
    const readmesNow = useRef(readmes);
    readmesNow.current = readmes;
    // The trees whose README couldn't be fetched (git failed), with no fetch waiting or running: the detail says so, and
    // ⌘R or coming back to the row fetches it again, showing it as loading meanwhile. Never kept.
    const [readmeFailed, setReadmeFailed] = useState<ReadonlySet<string>>(new Set());
    const [checked, setChecked] = useState<Checked>({ scanner: "", results: new Map(), failed: new Set() });
    // The latest, for the checks' callbacks, which outlive a render.
    const checkedNow = useRef(checked);
    checkedNow.current = checked;
    // The latest list, for a failure's link, which is made after the install's await.
    const loadedNow = useRef(loaded);
    loadedNow.current = loaded;
    // Drawn again when a name starts or stops installing (SPEC-153 B, C).
    const [, setBusyChanges] = useState(0);
    const busyChanged = useCallback(() => setBusyChanges((count) => count + 1), []);
    // `load`, for a settled record, which is made before it.
    const loadNow = useRef<() => Promise<void>>(async () => {});
    // The failed rows of this session (SPEC-156 D.3), kept in memory only.
    const marks = useMemo(() => new RowMarks(busyChanged), [busyChanged]);
    // The row to select once (SPEC-156 D.1, D.5, E.1), until the selection reaches it.
    const [selectOnce, setSelectOnce] = useState<string>();
    // `showFailure`, for a settled record and a click, which are made before it.
    const showFailureNow = useRef<(mark: FailureMark) => void>(() => {});

    // The builds an earlier store left running (SPEC-153 C): their rows say Installing…, one that ended is settled in
    // the queue, and nothing rewrites `repo/` under them.
    const others = useMemo(
        () =>
            new OtherBuilds({
                supportPath: environment.supportPath,
                extensionsDir,
                probe: systemProbe(),
                changed: busyChanged,
                log: logLine,
                settled: async (outcome) => {
                    await loadNow.current().catch(() => undefined);
                    await settledNotice(outcome, {
                        logFailure: (title, failure) =>
                            void logToFudge("error", failureLog(title, failure)).catch(() => {}),
                        marks,
                        report: (end) => reportEnd(installEnded, end),
                        select: (dir) => setSelectOnce(dir),
                        save: (mark) => saveFailure(environment.supportPath, mark, logLine),
                        toast: async (shown) => {
                            await showToast({
                                style: shown.failed ? Toast.Style.Failure : Toast.Style.Success,
                                title: shown.title,
                                ...(shown.message ? { message: shown.message } : {}),
                            });
                        },
                        show: (mark) => showFailureNow.current(mark),
                    });
                },
            }),
        [extensionsDir, busyChanged, marks],
    );
    useEffect(() => {
        others.start();
        return () => others.stop();
    }, [others]);
    // Failures saved for a click that nobody opened for a week go (SPEC-156 D.4).
    useEffect(() => void pruneSavedFailures(environment.supportPath), []);
    // The names this store is installing: a second press does nothing (SPEC-153 B).
    const presses = useMemo(
        () => new InstallPresses(busyChanged, (name) => others.busy(name) !== undefined),
        [busyChanged, others],
    );
    const busyOf = (name: string) => presses.state(name) ?? others.busy(name);

    const load = useCallback(async () => {
        // The records of builds from another session, read with each load, apart from the copy.
        await others.check();
        const scanner = await scannerIdentity(cli);
        const [entries, installed, trees, commit, results] = await Promise.all([
            readCatalog(repo.path),
            readInstalled(environment.supportPath),
            repo.trees(),
            repo.commit(),
            readCompatibility(environment.supportPath, scanner),
        ]);
        const withoutSwift = new Set<string>();
        for (const name of Object.keys(installed)) {
            if (await installedWithoutSwift(path.join(extensionsDir, name))) withoutSwift.add(name);
        }
        setLoaded({ entries, installed, trees, commit, withoutSwift });
        setChecked((current) => ({ scanner, results, failed: current.scanner === scanner ? current.failed : new Set() }));
        hasLoaded.current = true;
        setLoadError(undefined);
    }, [repo, cli, extensionsDir, others]);
    loadNow.current = load;

    /**
     * Clones the first time, refreshes after that; the list stays usable meanwhile. Like every git operation of the
     * store's, it waits its turn (`oneAtATime`), so it never runs during an install or a README fetch. While a build from
     * another session runs, it waits before it enters the queue, and runs once that build has settled (SPEC-153 C.7). A
     * failure before anything has loaded shows in the load-error view (`LoadFailure`: its cause and Copy Error), whose
     * Refresh tries again; one after that is a toast over the list, which stays usable.
     */
    const refresh = useCallback(
        () =>
            heldRefresh(others, async () => {
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
                    const title = first ? "Couldn't download the store's list" : "Couldn't update the store's list";
                    logFailure(title, error);
                    toast.style = Toast.Style.Failure;
                    toast.title = title;
                    toast.message = message(error);
                    if (!hasLoaded.current) setLoadError({ title, details: failureDetails(error) });
                }
            }),
        [repo, load, others],
    );

    /**
     * Opens the copy: clones it the first time, clones it again when it can't be read (a clone stopped halfway), and
     * refreshes it when it's a day old, or always when `retry` (the load-error view's Refresh, or the needs-Git view's).
     */
    const open = useCallback(
        async (retry: boolean) => {
            if (retry) setLoadError(undefined);
            if (!(await gitAvailable())) {
                setNoGit(true);
                return;
            }
            // Refresh after installing the Command Line Tools finds git now.
            setNoGit(false);
            await openCopy(retry, {
                others,
                exists: () => repo.exists(),
                load,
                remove: () => repo.remove(),
                refresh,
                needsRefresh: () => repo.needsRefresh(new Date()),
            });
        },
        [repo, load, refresh, others],
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
                changed: (key, readme) => {
                    const tree = key.split("\0")[1]!;
                    if (readme === "failed") setReadmeFailed((current) => new Set(current).add(tree));
                    else setReadmes((current) => ({ ...current, [tree]: readme }));
                },
                // A fetch on its way (⌘R, or the selection back on the row) shows as loading, not as the failure.
                scheduled: (key) => setReadmeFailed((current) => refetching(current, key.split("\0")[1]!)),
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
            log: logLine,
            // Asked each time an install needs it, never cached, so tools set up meanwhile count (SPEC-145 §3).
            commandLineToolsReady: () => commandLineToolsReady().catch(() => false),
            // macOS asks about notifications after the user confirms, never from a background path (SPEC-156 G).
            askForNotifications: () => askForNotifications(),
            chooseSwiftParts: (title) =>
                new Promise<SwiftPartsChoice>((resolve) => push(<SwiftPartsView title={title} choose={resolve} />)),
        }),
        [repo, cli, extensionsDir, push],
    );

    // The detail's Compatibility line: the selected row is scanned once the selection rests on it, in the git queue,
    // and its result is cached by tree. Moving on cancels it.
    const checks = useMemo(
        () =>
            new CompatibilityChecks({
                cached: (tree) => checkedNow.current.results.get(tree),
                check: (dir, tree, cancelled, signal) =>
                    oneAtATime(async () => {
                        const result = await checkFolder(dir, context, cancelled, signal);
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

    // ↵ Install, ⌘U Update and Try Again: one press per name at a time (SPEC-153 B), each in the queue.
    const runInstall = (entry: StoreEntry, updating: boolean): Promise<void> => {
        const view: InstallView = {
            toast: async (title) => {
                const toast = await showToast({ style: Toast.Style.Animated, title });
                return {
                    hide: () => toast.hide(),
                    // A toast, so the launcher stays open on the list (SPEC-130). Each setter shows the toast again, and
                    // with the window hidden a toast that isn't animated shows as a HUD, so the style changes last.
                    done: (title, message) => {
                        toast.title = title;
                        if (message) toast.message = message;
                        toast.style = Toast.Style.Success;
                    },
                    failed: (title, message) => {
                        toast.style = Toast.Style.Failure;
                        toast.title = title;
                        toast.message = message;
                    },
                };
            },
            load,
            failed: (title, error) => {
                logFailure(title, error);
                push(
                    <FailureView
                        title={title}
                        details={failureDetails(error)}
                        pageURL={loadedNow.current ? folderURL(entry.dir, loadedNow.current.commit) : undefined}
                        cli={cli}
                        retry={() => void runInstall(entry, updating)}
                    />,
                );
            },
            // Install notifications (SPEC-156 D.1): the app's answer decides the toast, the selection and the mark.
            notices: {
                report: (report) => installEnded(report),
                select: (dir) => setSelectOnce(dir),
                failedNotified: (title, error, mark) => {
                    logFailure(title, error);
                    marks.mark(mark);
                },
                succeeded: (name) => marks.clear(name),
            },
        };
        return presses.press(entry.name, updating, () => oneAtATime(() => installPressed(entry, updating, context, view)));
    };

    /** The failure view for a marked row, a click or the launch context, with Try Again. */
    const pushFailure = (mark: FailureMark) => {
        const entry = loadedNow.current?.entries.find((candidate) => candidate.dir === mark.dir);
        push(
            <FailureView
                title={`Couldn't ${mark.updating ? "update" : "install"} ${mark.title}`}
                details={mark.details}
                pageURL={loadedNow.current ? folderURL(mark.dir, loadedNow.current.commit) : undefined}
                cli={cli}
                retry={() => {
                    if (entry) void runInstall(entry, mark.updating);
                }}
            />,
        );
    };
    /** Show Error and a settled failure: the view, and the failure saved for its notification goes (D.4). */
    const showFailure = (mark: FailureMark) => {
        void removeSavedFailure(environment.supportPath, mark.name);
        pushFailure(mark);
    };
    showFailureNow.current = showFailure;

    /** A click or the launch context (SPEC-156 D.5, E.1): the row selected, and with `failed` its failure view. */
    const openTarget = (target: NoticeTarget) =>
        openNoticeTarget(target, {
            supportPath: environment.supportPath,
            select: (dir) => setSelectOnce(dir),
            marks,
            show: (mark) => pushFailure(mark),
        });
    const openTargetNow = useRef(openTarget);
    openTargetNow.current = openTarget;

    // The launch context a click opens the store with (D.5): once, after the first load and the records found at open.
    const [launch] = useState(() => new LaunchTarget(launchContext, others, (target) => openTargetNow.current(target)));
    useEffect(() => void launch.loaded(loaded !== undefined), [launch, loaded]);

    // A click while this session is loaded (E.1): one call waits at a time, made again after each answer.
    useEffect(() => {
        let stopped = false;
        void followClicks(nextNotificationClick, (target) => openTargetNow.current(target), () => stopped);
        return () => {
            stopped = true;
        };
    }, []);

    const runUninstall = (entry: StoreEntry) =>
        oneAtATime(async () => {
            try {
                if (!(await uninstall(entry, context))) return;
                await load();
                await showToast({ style: Toast.Style.Success, title: `Uninstalled ${entry.title}` });
            } catch (error) {
                logFailure(`Couldn't uninstall ${entry.title}`, error);
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
    // A row's id is its folder in the repository (`StoreEntry.dir`), which `readCatalog` checked. The README is
    // selected first: both wait the same half second and the git queue runs in order, so its quick fetch goes ahead of
    // the check's download and scan.
    useEffect(() => {
        readmeFetches.select(checking && checkingTree ? `${checking}\0${checkingTree}` : undefined);
        checks.select(checking, checkingTree);
    }, [readmeFetches, checks, checking, checkingTree]);

    if (noGit) {
        return (
            <List>
                <NeedsGit refresh={() => void open(true)} />
            </List>
        );
    }

    /** The detail's Compatibility line for a row: its cached result, or the check waiting, running or failed. */
    const compatibilityFor = (entry: StoreEntry, tree: string | undefined) => {
        if (!tree) return undefined;
        const result = checked.results.get(tree);
        return compatibilityText(result ?? (checked.failed.has(tree) ? "failed" : "checking"), commandTitles(entry));
    };
    const item = (entry: StoreEntry) => {
        const state = loaded ? status(entry, loaded.installed, loaded.trees) : "available";
        // Every row with a name that's being installed or updated, here or by an earlier store's build (SPEC-153 B, C).
        const busy = busyOf(entry.name);
        const mark = marks.get(entry.dir);
        const offered = rowActions(state, busy, mark);
        const icon = loaded ? iconURL(entry, loaded.commit) : undefined;
        const tree = loaded?.trees.get(entry.dir);
        const compatibility = tree === undefined ? undefined : compatibilityTag(checked.results.get(tree));
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
                        : accessoryTexts(entry, state, compatibility, busy, mark).map((accessory) =>
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
                                tree === undefined ? undefined : shownReadme(tree, readmes, readmeFailed),
                                compatibilityFor(entry, tree),
                                state !== "available" && loaded?.withoutSwift.has(entry.name) === true,
                            )}
                        />
                    ) : undefined
                }
                actions={
                    entry.dir !== actionsFor ? undefined : (
                    <ActionPanel>
                        <ActionPanel.Section>
                            {offered.tryAgain && mark && (
                                <Action
                                    title="Try Again"
                                    icon={Icon.ArrowClockwise}
                                    onAction={() => runInstall(entry, mark.updating)}
                                />
                            )}
                            {offered.showError && mark && (
                                <Action
                                    title="Show Error"
                                    icon={Icon.ExclamationMark}
                                    shortcut={{ modifiers: ["cmd"], key: "return" }}
                                    onAction={() => showFailure(mark)}
                                />
                            )}
                            {offered.install && (
                                <Action title="Install" icon={Icon.Download} onAction={() => runInstall(entry, false)} />
                            )}
                            {offered.update && (
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
                            {offered.uninstall && (
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
                                onAction={() => {
                                    // A README that couldn't be fetched is tried again too.
                                    readmeFetches.again();
                                    // Held while a build from another session runs, which the toast says (SPEC-153 C.7).
                                    const waiting = others.records();
                                    if (waiting.length > 0) {
                                        void showToast({ style: Toast.Style.Success, title: heldRefreshMessage(waiting) });
                                    }
                                    void refresh();
                                }}
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
            selectedItemId={selectOnce}
            onSelectionChange={(id) => {
                setSelected(id);
                // Selected once: from here the user moves it.
                if (id !== null && id === selectOnce) setSelectOnce(undefined);
            }}
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
                <LoadFailure
                    title={loadError.title}
                    details={loadError.details}
                    cli={cli}
                    refresh={() => void open(true)}
                />
            ) : (
                <List.EmptyView icon={Icon.MagnifyingGlass} title="No extensions found" />
            )}
            <List.Section title="Installed">{installedRows.map(item)}</List.Section>
            <List.Section title="Extensions">{other.map(item)}</List.Section>
        </List>
    );
}
