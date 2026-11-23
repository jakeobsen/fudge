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
    openExtensionPreferences,
    type LaunchProps,
} from "@raycast/api";
import path from "node:path";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
    accessoryTexts,
    addedRepository,
    commandTitles,
    allFilter,
    categories,
    entryId,
    filterEntries,
    filterRepositories,
    folderURL,
    gitHubRepository,
    iconURL,
    installedFilter,
    installingTag,
    failedInstallTag,
    failedUpdateTag,
    namedRowId,
    repositoryFilter,
    repositoryHost,
    rowActions,
    rowId,
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
import { gitAvailable, stopRunningGit } from "./git.ts";
import { detailMarkdown, fetchReadme, readmeKey, readmeKeyParts, refetching, shownReadme, type RowRepository } from "./readme.ts";
import {
    developmentBuildAccessory,
    developmentDetailMarkdown,
    developmentRowId,
    developmentRowsShown,
    installOnlyRowActions,
    installOnlyRowsReady,
    readDevelopmentBuilds,
    uninstallDevelopmentBuild,
    type DevelopmentBuild,
} from "./development-builds.ts";
import {
    notUpdatedAccessory,
    notUpdatedDetailMarkdown,
    notUpdatedRowId,
    notUpdatedRowsShown,
    readNotUpdated,
    uninstallNotUpdated,
    type NotUpdatedInstall,
} from "./not-updated.ts";
import { RestingWork } from "./resting.ts";
import { causeOf, cleanOutput, failureMarkdown, type FailureDetails } from "./failure.ts";
import { FailureView, LoadFailure, NeedsGit } from "./failure-view.tsx";
import {
    failureDetails,
    failureLog,
    installPressed,
    InstallPresses,
    installsWithoutSwift,
    offOrRemovedMessage,
    oneAtATime,
    readInstalled,
    rowCopy,
    uninstall,
    type InstallView,
    type StoreContext,
} from "./store.ts";
import { systemProbe } from "./build-records.ts";
import { heldRefreshMessage, OtherBuilds, settledNotice } from "./other-builds.ts";
import { openCopies, refreshCopies, type CopySteps } from "./copy-turns.ts";
import { RAYCAST_COPY } from "./repository-address.ts";
import {
    problemReport,
    problemRows,
    problemSentence,
    raycastLoadFailure,
    readCopy,
    readRepositoryList,
    shownRows,
    type CopyState,
    type ProblemRow,
    type StoreCopy,
} from "./repositories.ts";
import {
    askForNotifications,
    commandLineToolsReady,
    extensionRepositories,
    installEnded,
    logToFudge,
    nextNotificationClick,
} from "fudge:app";
import {
    followClicks,
    LaunchTarget,
    openNoticeTarget,
    pruneSavedFailures,
    removeSavedFailure,
    reportEnd,
    RowMarks,
    RowSelection,
    saveFailure,
    type FailureMark,
    type NoticeTarget,
} from "./notices.ts";
import type { SwiftPartsChoice } from "./swift-parts.ts";
import { SwiftPartsView } from "./swift-parts-view.tsx";
import os from "node:os";

/** A failure the store had goes into `Fudge.log` too, with its output (SPEC-124); writing it never fails a step. */
const logFailure = (title: string, error: unknown) => void logToFudge("error", failureLog(title, failureDetails(error))).catch(() => {});
/** A line of the store's own in `Fudge.log`, such as a build's record it couldn't write; never fails a step. */
const logLine = (line: string) => void logToFudge("error", line).catch(() => {});

/** What each load reads besides the copies. `withoutSwift`: the installed extensions built without their part written
 * in Swift (SPEC-145 §3). */
type Shared = {
    installed: Installed;
    withoutSwift: ReadonlySet<string>;
    /** The builds in `fudgeapp/development`, read with `installed.json` (SPEC-157 E.9). */
    development: DevelopmentBuild[];
    /** The installs whose repository isn't on, read with `installed.json` (E.8). */
    notUpdated: NotUpdatedInstall[];
};
/** The list: the rows of every copy read so far, and each copy's trees and commit by copy id (SPEC-157 D.1). */
type Loaded = Shared & {
    entries: StoreEntry[];
    trees: Map<string, Map<string, string>>;
    commits: Map<string, string>;
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
    // A copy of each repository that's on, from the last read of the list (C.1), Raycast's first; none until it's read.
    const [copies, setCopies] = useState<StoreCopy[]>();
    const copiesNow = useRef(copies);
    copiesNow.current = copies;
    // Each copy's rows and problem, by copy id (C.6). The ref is the latest, for the end of an open or a ⌘R.
    const [copyStates, setCopyStates] = useState<ReadonlyMap<string, CopyState>>(new Map());
    const copyStatesNow = useRef<ReadonlyMap<string, CopyState>>(copyStates);
    const changeCopyState = useCallback((copyId: string, change: (state: CopyState | undefined) => CopyState) => {
        const next = new Map(copyStatesNow.current).set(copyId, change(copyStatesNow.current.get(copyId)));
        copyStatesNow.current = next;
        setCopyStates(next);
    }, []);
    // The installs, the scans' cache and the development builds, read with each load.
    const [shared, setShared] = useState<Shared>();
    // Opens and ⌘Rs still reading copies: the list shows as loading until the last copy is read (C.3).
    const [reading, setReading] = useState(0);
    // The rows of every copy read so far, once the installs are read.
    const loaded = useMemo<Loaded | undefined>(
        () => (shared ? { ...shared, ...shownRows(copies ?? [], copyStates) } : undefined),
        [shared, copies, copyStates],
    );
    const [noGit, setNoGit] = useState(false);
    // The list's download failing before anything has loaded: its title and what failed, for `LoadFailure`.
    const [loadError, setLoadError] = useState<{ title: string; details: FailureDetails }>();
    const [filter, setFilter] = useState(allFilter);
    const [showingDetail, setShowingDetail] = useState(false);
    const [selected, setSelected] = useState<string | null>(null);
    // The READMEs fetched, by their copy, folder and tree id (`readmeKey`), so a folder that hasn't changed is never
    // fetched again.
    const [readmes, setReadmes] = useState<Record<string, string>>({});
    const readmesNow = useRef(readmes);
    readmesNow.current = readmes;
    // The README keys whose fetch failed (git failed), with no fetch waiting or running: the detail says so, and
    // ⌘R or coming back to the row fetches it again, showing it as loading meanwhile. Never kept.
    const [readmeFailed, setReadmeFailed] = useState<ReadonlySet<string>>(new Set());
    const [checked, setChecked] = useState<Checked>({ scanner: "", results: new Map(), failed: new Set() });
    // The latest, for the checks' callbacks, which outlive a render.
    const checkedNow = useRef(checked);
    checkedNow.current = checked;
    // The latest list, for a failure's link, which is made after the install's await.
    const loadedNow = useRef(loaded);
    loadedNow.current = loaded;
    // A row's copy, as the list now has it: none once its repository is off or removed (SPEC-157 D.6).
    const copyOf = useCallback(
        (copyId: string) => copiesNow.current?.find((candidate) => candidate.entry.copyId === copyId),
        [],
    );
    // The repository a row is from, as its accessory, detail and links name it (D.2, D.4).
    const repositoryOf = (copyId: string): RowRepository | undefined => {
        const copy = copyOf(copyId);
        if (!copy) return undefined;
        const gitHub = gitHubRepository(copy.entry.identity);
        return { name: copy.entry.name, ...(gitHub ? { gitHub } : {}) };
    };
    // A failure of a row's work names its repository's host when "couldn't reach" applies and it isn't GitHub (C.6).
    const withHost = (details: FailureDetails, copyId: string): FailureDetails => {
        const identity = copyOf(copyId)?.entry.identity;
        const host = identity === undefined ? undefined : repositoryHost(identity);
        return host === undefined ? details : { ...details, host };
    };
    // The page of a row's folder at its copy's commit, for the failure view; none before its copy has loaded, or for a
    // repository that isn't on github.com (D.4).
    const pageURL = (dir: string, copyId: string) => {
        const commit = loadedNow.current?.commits.get(copyId);
        const gitHub = repositoryOf(copyId)?.gitHub;
        return commit === undefined || gitHub === undefined ? undefined : folderURL(gitHub, dir, commit);
    };
    // Drawn again when a name starts or stops installing (SPEC-153 B, C).
    const [, setBusyChanges] = useState(0);
    const busyChanged = useCallback(() => setBusyChanges((count) => count + 1), []);
    // `load`, for a settled record, which is made before it.
    const loadNow = useRef<() => Promise<void>>(async () => {});
    // The failed rows of this session (SPEC-156 D.3), kept in memory only.
    const marks = useMemo(() => new RowMarks(busyChanged), [busyChanged]);
    // The row to select once (SPEC-156 D.1, D.5, E.1), until the selection reaches it.
    const [selectOnce, setSelectOnce] = useState<string>();
    const rows = useMemo(() => new RowSelection(setSelectOnce), []);
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
                        select: (dir, repository) => rows.select(namedRowId(dir, repository)),
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
        [extensionsDir, busyChanged, marks, rows],
    );
    useEffect(() => {
        others.start();
        return () => others.stop();
    }, [others]);
    // Failures saved for a click that nobody opened for a week go (SPEC-156 D.4).
    useEffect(() => void pruneSavedFailures(environment.supportPath), []);
    // The extensions this store is installing, by id: a second press does nothing (SPEC-153 B, SPEC-157 E.7).
    const presses = useMemo(
        () => new InstallPresses(busyChanged, (id) => others.busy(id) !== undefined),
        [busyChanged, others],
    );
    const busyOf = (id: string) => presses.state(id) ?? others.busy(id);

    /**
     * The installs, the scans' cache, the development builds and the installs whose repository isn't on: at open, on ⌘R
     * (with the copies of the list just read, `on`), and after each install and uninstall (with the copies shown).
     */
    const load = useCallback(async (on?: StoreCopy[]) => {
        // The records of builds from another session, read with each load, apart from the copies.
        await others.check();
        const scanner = await scannerIdentity(cli);
        const [installed, results, development] = await Promise.all([
            readInstalled(environment.supportPath),
            readCompatibility(environment.supportPath, scanner),
            readDevelopmentBuilds(extensionsDir),
        ]);
        const withoutSwift = await installsWithoutSwift(extensionsDir, Object.keys(installed));
        // None while the list of repositories hasn't been read, since which are on isn't known yet.
        const copiesOn = on ?? copiesNow.current;
        const notUpdated = copiesOn
            ? await readNotUpdated(installed, new Set(copiesOn.map((copy) => copy.entry.folder)), extensionsDir)
            : [];
        setShared({ installed, withoutSwift, development, notUpdated });
        setChecked((current) => ({ scanner, results, failed: current.scanner === scanner ? current.failed : new Set() }));
    }, [cli, extensionsDir, others]);
    loadNow.current = load;

    /**
     * A copy's turns (C.3, C.6): its rows shown as soon as it's read, so a copy read later adds its rows without moving
     * the selection; its problem shown as a row; and a toast while it's fetched, which says what failed.
     */
    const copySteps: CopySteps = useMemo(
        () => ({
            others,
            now: () => new Date(),
            read: async (copy) => {
                const [trees, commit] = await Promise.all([copy.repo.trees(), copy.repo.commit()]);
                const entries = await readCopy(copy.repo.path, copy.copy);
                changeCopyState(copy.entry.copyId, () => ({ rows: { entries, trees, commit } }));
                return entries.length;
            },
            problem: (copy, kind, error) =>
                changeCopyState(copy.entry.copyId, (state) => ({ ...state, problem: { kind, error } })),
            fetching: (copy, first) => {
                const name = copy.entry.name;
                const shown = showToast({
                    style: Toast.Style.Animated,
                    title: first ? `Downloading the list from ${name}…` : `Updating the list from ${name}…`,
                });
                return (failure) =>
                    void shown
                        .then(async (toast) => {
                            if (!failure) return toast.hide();
                            const title = first
                                ? `Couldn't download the list from ${name}`
                                : `Couldn't update the list from ${name}`;
                            logFailure(title, failure.error);
                            toast.style = Toast.Style.Failure;
                            toast.title = title;
                            toast.message = problemSentence(failure.kind, copy.entry.branch);
                        })
                        .catch(() => {});
            },
        }),
        [others, changeCopyState],
    );

    /**
     * Reads the list of repositories (C.1), before anything else at open and on ⌘R: a copy of each one that's on, the
     * rows of copies no longer on gone, and the copies of repositories no longer listed deleted (C.5). Undefined when
     * the app couldn't answer, which the load-error view says.
     */
    const readList = useCallback(async (): Promise<StoreCopy[] | undefined> => {
        let on: StoreCopy[];
        try {
            ({ copies: on } = await readRepositoryList(extensionRepositories, environment.supportPath, (key, step) =>
                others.hold(key, () => oneAtATime(step)),
            ));
        } catch (error) {
            const title = "Couldn't read the Extension Store's repositories";
            logFailure(title, error);
            setLoadError({ title, details: failureDetails(error) });
            return undefined;
        }
        setCopies(on);
        const kept = new Map([...copyStatesNow.current].filter(([copyId]) => on.some((copy) => copy.entry.copyId === copyId)));
        copyStatesNow.current = kept;
        setCopyStates(kept);
        return on;
    }, [others]);

    /**
     * Reads the list, the installs, then runs `work` on the copies, with the list showing as loading throughout (C.3).
     * Raycast's load-error view shows afterwards only when no copy at all could be read (C.6); otherwise every problem
     * is a row.
     */
    const readCopies = useCallback(
        async (work: (copies: StoreCopy[]) => Promise<void>) => {
            setReading((count) => count + 1);
            let on: StoreCopy[] | undefined;
            try {
                on = await readList();
                await load(on);
                if (on) await work(on);
            } finally {
                setReading((count) => count - 1);
            }
            if (!on) return;
            const failure = raycastLoadFailure(on, copyStatesNow.current);
            setLoadError(
                failure
                    ? { title: `Couldn't download the list from ${RAYCAST_COPY.name}`, details: failureDetails(failure.error) }
                    : undefined,
            );
        },
        [readList, load],
    );

    /**
     * ⌘R (C.1, C.3): the list read again, the installs read again, then every copy that's on fetched once, in the
     * list's order, each in its own turn, one waiting for ⌘R included. Like every git operation of the store's, each
     * turn waits its turn (`oneAtATime`), and while a build from another session runs, it waits before it enters the
     * queue, and runs once that build has settled (SPEC-153 C.7). The list stays usable meanwhile.
     */
    const refresh = useCallback(
        () => readCopies((on) => refreshCopies(on, copySteps)),
        [readCopies, copySteps],
    );

    /**
     * Opens the store: the list of repositories, the installs, then each copy that's on in its own turns (C.3): cloned
     * the first time, cloned again when it can't be read, and refreshed when it's a day old, or always when `retry`
     * (the load-error view's Refresh, or the needs-Git view's).
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
            await readCopies((on) => openCopies(on, retry, copySteps));
        },
        [readCopies, copySteps],
    );

    useEffect(() => {
        void open(false);
        // Unloading the store (leaving it, or turning it off) ends its git, which mustn't go on writing into a copy.
        return stopRunningGit;
    }, [open]);

    // The README of the row the selection rests on, with the detail pane open, as the compatibility check waits
    // (`RestingWork`): moving through rows fetches nothing, and a folder's README is fetched once per tree, from the
    // row's own copy (`readmeKey`).
    const readmeFetches = useMemo(
        () =>
            new RestingWork<string>({
                done: (key) => readmesNow.current[key] !== undefined,
                run: (key, cancelled) =>
                    oneAtATime(async () => {
                        if (cancelled()) return undefined;
                        const { copyId, dir } = readmeKeyParts(key);
                        // The row's own copy, as the list now has it (D.6).
                        const copy = copiesNow.current?.find((candidate) => candidate.entry.copyId === copyId);
                        if (!copy) throw new Error(offOrRemovedMessage);
                        return fetchReadme(copy.repo, dir);
                    }),
                changed: (key, readme) => {
                    if (readme === "failed") setReadmeFailed((current) => new Set(current).add(key));
                    else setReadmes((current) => ({ ...current, [key]: readme }));
                },
                // A fetch on its way (⌘R, or the selection back on the row) shows as loading, not as the failure.
                scheduled: (key) => setReadmeFailed((current) => refetching(current, key)),
            }),
        [],
    );
    useEffect(() => () => readmeFetches.stop(), [readmeFetches]);

    const context: StoreContext = useMemo(
        () => ({
            // Each row's work takes its own copy by its copy id (D.6), as the list now has it.
            copyOf,
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
        [copyOf, cli, extensionsDir, push],
    );

    // The detail's Compatibility line: the selected row is scanned once the selection rests on it, in the git queue,
    // and its result is cached by tree. Moving on cancels it.
    const checks = useMemo(
        () =>
            new CompatibilityChecks({
                cached: (tree) => checkedNow.current.results.get(tree),
                check: (copyId, dir, tree, cancelled, signal) =>
                    oneAtATime(async () => {
                        // The row's own copy (D.6): one switched off or removed since is checked nowhere.
                        const result = await checkFolder(rowCopy(context, copyId).repo, dir, context, cancelled, signal);
                        if (!result) return undefined;
                        await rememberCompatibility(environment.supportPath, checkedNow.current.scanner, tree, result);
                        return result;
                    }),
                changed: (_copyId, _dir, tree, result) =>
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

    // ↵ Install, ⌘U Update and Try Again: one press per extension id at a time (SPEC-153 B), each in the queue.
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
                        details={withHost(failureDetails(error), entry.copyId)}
                        pageURL={pageURL(entry.dir, entry.copyId)}
                        cli={cli}
                        retry={() => void runInstall(entry, updating)}
                    />,
                );
            },
            // Install notifications (SPEC-156 D.1): the app's answer decides the toast, the selection and the mark.
            notices: {
                report: (report) => installEnded(report),
                select: (dir, repository) => rows.select(namedRowId(dir, repository)),
                failedNotified: (title, error, mark) => {
                    logFailure(title, error);
                    marks.mark(mark);
                },
                succeeded: (name, repository) => marks.clear(name, repository),
            },
        };
        return presses.press(entryId(entry), updating, () =>
            oneAtATime(() => installPressed(entry, updating, context, view)),
        );
    };

    /** The failure view for a marked row, a click or the launch context, with Try Again. */
    const pushFailure = (mark: FailureMark) => {
        // The mark's own row: its folder in its repository, Raycast's when the mark names none.
        const entry = loadedNow.current?.entries.find(
            (candidate) => candidate.dir === mark.dir && addedRepository(candidate) === mark.repository,
        );
        push(
            <FailureView
                title={`Couldn't ${mark.updating ? "update" : "install"} ${mark.title}`}
                details={entry ? withHost(mark.details, entry.copyId) : mark.details}
                pageURL={entry ? pageURL(entry.dir, entry.copyId) : undefined}
                cli={cli}
                retry={() => {
                    if (entry) void runInstall(entry, mark.updating);
                }}
            />,
        );
    };
    /** Show Error and a settled failure: the view, and the failure saved for its notification goes (D.4). */
    const showFailure = (mark: FailureMark) => {
        void removeSavedFailure(environment.supportPath, mark);
        pushFailure(mark);
    };
    showFailureNow.current = showFailure;

    /** A click or the launch context (SPEC-156 D.5, E.1): the row selected, and with `failed` its failure view. */
    const openTarget = (target: NoticeTarget) =>
        openNoticeTarget(target, {
            supportPath: environment.supportPath,
            select: (dir, repository) => rows.select(namedRowId(dir, repository)),
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

    /** Uninstall on a development build's row (E.9): its folder to the Trash, no record read or written. */
    const runUninstallDevelopment = (build: DevelopmentBuild) =>
        oneAtATime(async () => {
            try {
                if (!(await uninstallDevelopmentBuild(build, context))) return;
                await load();
                await showToast({ style: Toast.Style.Success, title: `Uninstalled ${build.title}` });
            } catch (error) {
                logFailure(`Couldn't uninstall ${build.title}`, error);
                await showToast({
                    style: Toast.Style.Failure,
                    title: `Couldn't uninstall ${build.title}`,
                    message: message(error),
                });
            }
        });

    /** Uninstall on the row of an install whose repository isn't on (E.8): its folder to the Trash, and its record gone. */
    const runUninstallNotUpdated = (install: NotUpdatedInstall) =>
        oneAtATime(async () => {
            try {
                if (!(await uninstallNotUpdated(install, context))) return;
                await load();
                await showToast({ style: Toast.Style.Success, title: `Uninstalled ${install.title}` });
            } catch (error) {
                logFailure(`Couldn't uninstall ${install.title}`, error);
                await showToast({
                    style: Toast.Style.Failure,
                    title: `Couldn't uninstall ${install.title}`,
                    message: message(error),
                });
            }
        });

    /** ⌘R on any row: a README that couldn't be fetched is tried again too, and the list and every copy are read again. */
    const refreshPressed = () => {
        readmeFetches.again();
        // Held while a build from another session runs, which the toast says (SPEC-153 C.7).
        const waiting = others.records();
        if (waiting.length > 0) void showToast({ style: Toast.Style.Success, title: heldRefreshMessage(waiting) });
        void refresh();
    };

    const shown = loaded ? filterEntries(loaded.entries, filter, loaded.installed) : [];
    const { installed: installedRows, other } = sections(shown, loaded?.installed ?? {});
    // A row's id is its repository's folder and its folder there (`rowId`), which `readCatalog` checked.
    const entryRowId = (entry: StoreEntry) => rowId(entry.repositoryFolder, entry.dir);
    const byRowId = useMemo(() => new Map((loaded?.entries ?? []).map((entry) => [entryRowId(entry), entry])), [loaded]);
    const treeOf = (entry: StoreEntry) => loaded?.trees.get(entry.copyId)?.get(entry.dir);
    const commitOf = (entry: StoreEntry) => loaded?.commits.get(entry.copyId);
    // Only the selected row carries its actions (the first row until something is selected): 3,500 action panels
    // would make every render take seconds. Moving the selection renders the new row's.
    const firstRow = installedRows[0] ?? other[0];
    const actionsFor = selected ?? (firstRow ? entryRowId(firstRow) : undefined);
    const checking = showingDetail && actionsFor !== undefined ? byRowId.get(actionsFor) : undefined;
    const checkingTree = checking ? treeOf(checking) : undefined;
    // The README is selected first: both wait the same half second and the git queue runs in order, so its quick fetch
    // goes ahead of the check's download and scan.
    useEffect(() => {
        readmeFetches.select(checking && checkingTree ? readmeKey(checking.copyId, checking.dir, checkingTree) : undefined);
        checks.select(checking?.copyId, checking?.dir, checkingTree);
    }, [readmeFetches, checks, checking, checkingTree]);

    // A repository's filter goes back to All once its item has left the dropdown (D.3): switched off or removed, or the
    // only repository still on.
    useEffect(() => {
        if (!filter.startsWith("repository:")) return;
        if (!filterRepositories(copies ?? []).some((copy) => repositoryFilter(copy.entry.copyId) === filter)) setFilter(allFilter);
    }, [copies, filter]);

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
        const id = entryRowId(entry);
        const state = loaded ? status(entry, loaded.installed, loaded.trees.get(entry.copyId) ?? new Map()) : "available";
        // The row whose extension is being installed or updated, here or by an earlier store's build (SPEC-153 B, C), by
        // its id, so the same name from another repository isn't (SPEC-157 E.7).
        const busy = busyOf(entryId(entry));
        const mark = marks.get(entry.dir, addedRepository(entry));
        const offered = rowActions(state, busy, mark);
        const commit = commitOf(entry);
        // Its repository (D.2, D.4): rows show only while their copy is on, so it's there.
        const repository = repositoryOf(entry.copyId) ?? { name: "" };
        const icon = commit === undefined ? undefined : iconURL(entry, repository.gitHub, commit);
        const tree = treeOf(entry);
        const compatibility = tree === undefined ? undefined : compatibilityTag(checked.results.get(tree));
        return (
            <List.Item
                key={id}
                id={id}
                title={entry.title}
                subtitle={showingDetail ? undefined : entry.description}
                icon={icon ? { source: icon, fallback: Icon.Box } : Icon.Box}
                keywords={searchKeywords(entry)}
                accessories={
                    showingDetail
                        ? undefined
                        : accessoryTexts(entry, state, compatibility, busy, mark, repository.name).map((accessory) =>
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
                                repository,
                                commit ?? "",
                                tree === undefined
                                    ? undefined
                                    : shownReadme(readmeKey(entry.copyId, entry.dir, tree), readmes, readmeFailed),
                                compatibilityFor(entry, tree),
                                state !== "available" && loaded?.withoutSwift.has(entryId(entry)) === true,
                            )}
                        />
                    ) : undefined
                }
                actions={
                    id !== actionsFor ? undefined : (
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
                            {commit !== undefined && repository.gitHub !== undefined && (
                                <Action.OpenInBrowser url={folderURL(repository.gitHub, entry.dir, commit)} />
                            )}
                            <Action.CopyToClipboard title="Copy Name" content={entry.name} />
                            <Action
                                title="Refresh"
                                icon={Icon.ArrowClockwise}
                                shortcut={{ modifiers: ["cmd"], key: "r" }}
                                onAction={refreshPressed}
                            />
                        </ActionPanel.Section>
                    </ActionPanel>
                    )
                }
            />
        );
    };

    /** The actions of a row built from an install alone (E.8, E.9): Copy Name (↵), then Uninstall (⌃X), in that order. */
    const installOnlyActions = (name: string, uninstall: () => void) => (
        <ActionPanel>
            {installOnlyRowActions.map((action) => (
                <ActionPanel.Section key={action}>
                    {action === "copyName" ? (
                        <Action.CopyToClipboard title="Copy Name" content={name} />
                    ) : (
                        <Action
                            title="Uninstall"
                            icon={Icon.Trash}
                            style={Action.Style.Destructive}
                            shortcut={{ modifiers: ["ctrl"], key: "x" }}
                            onAction={uninstall}
                        />
                    )}
                </ActionPanel.Section>
            ))}
        </ActionPanel>
    );
    /** A development build's row (E.9): its own id, the default icon, and only Copy Name and Uninstall. */
    const developmentItem = (build: DevelopmentBuild) => (
        <List.Item
            key={developmentRowId(build.name)}
            id={developmentRowId(build.name)}
            icon={Icon.Box}
            title={build.title}
            subtitle={showingDetail ? undefined : build.description}
            keywords={[build.name]}
            accessories={showingDetail ? undefined : [{ text: developmentBuildAccessory }]}
            detail={showingDetail ? <List.Item.Detail markdown={developmentDetailMarkdown(build)} /> : undefined}
            actions={installOnlyActions(build.name, () => runUninstallDevelopment(build))}
        />
    );
    /** The row of an install whose repository isn't on (E.8): the default icon, "Not updated", and only Copy Name and
     * Uninstall. */
    const notUpdatedItem = (install: NotUpdatedInstall) => (
        <List.Item
            key={notUpdatedRowId(install.id)}
            id={notUpdatedRowId(install.id)}
            icon={Icon.Box}
            title={install.title}
            subtitle={showingDetail ? undefined : install.description}
            keywords={[install.name]}
            accessories={showingDetail ? undefined : [{ text: notUpdatedAccessory }]}
            detail={showingDetail ? <List.Item.Detail markdown={notUpdatedDetailMarkdown(install)} /> : undefined}
            actions={installOnlyActions(install.name, () => runUninstallNotUpdated(install))}
        />
    );
    /** A repository's problem row (C.6): Show Details, ⌘R Refresh and ⌘C Copy Error, git's output cleaned. */
    const problemItem = (row: ProblemRow) => {
        const id = `problem:${row.copyId}`;
        return (
            <List.Item
                key={id}
                id={id}
                title={row.title}
                icon={{ source: Icon.Warning, tintColor: Color.Orange }}
                detail={
                    showingDetail ? (
                        <List.Item.Detail
                            markdown={failureMarkdown(row.title, causeOf(row.details), cleanOutput(row.details.output, os.homedir()))}
                        />
                    ) : undefined
                }
                actions={
                    <ActionPanel>
                        <ActionPanel.Section>
                            <Action
                                title="Show Details"
                                icon={Icon.Document}
                                onAction={() =>
                                    push(
                                        <FailureView
                                            title={row.title}
                                            details={row.details}
                                            cli={cli}
                                            retry={refreshPressed}
                                            retryTitle="Refresh"
                                        />,
                                    )
                                }
                            />
                            <Action
                                title="Refresh"
                                icon={Icon.ArrowClockwise}
                                shortcut={{ modifiers: ["cmd"], key: "r" }}
                                onAction={refreshPressed}
                            />
                            <Action.CopyToClipboard
                                title="Copy Error"
                                shortcut={{ modifiers: ["cmd"], key: "c" }}
                                content={problemReport(row, os.homedir())}
                            />
                        </ActionPanel.Section>
                    </ActionPanel>
                }
            />
        );
    };
    // The load-error view while no copy has rows (C.6): Raycast's failure, in place of the whole list, as today. Any copy
    // read since makes every problem a row, Raycast's too.
    const loadFailureShown = loadError !== undefined && (loaded?.entries.length ?? 0) === 0;
    const problems = loadFailureShown ? [] : problemRows(copies ?? [], copyStates);
    // The dropdown's repositories (D.3), when more than one is on.
    const filteredRepositories = filterRepositories(copies ?? []);

    // The Installed section: the store's installs, the development builds and the installs whose repository isn't on,
    // by title. The last two come with the first copy's rows, so the list opens on its first row.
    const installOnly =
        loaded && !loadFailureShown && installOnlyRowsReady(loaded.entries.length, reading) ? loaded : undefined;
    const installedItems = [
        ...installedRows.map((entry) => ({ title: entry.title, node: item(entry) })),
        ...(installOnly && developmentRowsShown(filter) ? installOnly.development : []).map((build) => ({
            title: build.title,
            node: developmentItem(build),
        })),
        ...(installOnly && notUpdatedRowsShown(filter) ? installOnly.notUpdated : []).map((install) => ({
            title: install.title,
            node: notUpdatedItem(install),
        })),
    ].sort((a, b) => a.title.localeCompare(b.title, "en", { sensitivity: "base" }));

    return (
        <List
            isLoading={(!loaded && !loadError) || reading > 0}
            isShowingDetail={showingDetail}
            searchBarPlaceholder="Search extensions"
            selectedItemId={selectOnce}
            onSelectionChange={(id) => {
                setSelected(id);
                rows.reported(id);
            }}
            searchBarAccessory={
                <List.Dropdown tooltip="Category" value={filter} onChange={setFilter}>
                    <List.Dropdown.Item title="All" value={allFilter} />
                    <List.Dropdown.Item title="Installed" value={installedFilter} />
                    {filteredRepositories.length > 0 && (
                        <List.Dropdown.Section title="Repositories">
                            {filteredRepositories.map((copy) => (
                                <List.Dropdown.Item
                                    key={copy.entry.copyId}
                                    title={copy.entry.name}
                                    value={repositoryFilter(copy.entry.copyId)}
                                />
                            ))}
                        </List.Dropdown.Section>
                    )}
                    <List.Dropdown.Section title="Categories">
                        {categories(loaded?.entries ?? []).map((category) => (
                            <List.Dropdown.Item key={category} title={category} value={`category:${category}`} />
                        ))}
                    </List.Dropdown.Section>
                </List.Dropdown>
            }
        >
            {/* The load-error view while no copy has rows (C.6); a copy read since makes every problem a row. */}
            {loadError && loadFailureShown ? (
                <LoadFailure
                    title={loadError.title}
                    details={loadError.details}
                    cli={cli}
                    refresh={() => void open(true)}
                />
            ) : copies?.length === 0 ? (
                // No repository on (C.8): nothing is read, and Settings is where one is switched on.
                <List.EmptyView
                    icon={Icon.Box}
                    title="No extension repositories are on."
                    actions={
                        <ActionPanel>
                            <Action
                                title="Open Extension Store Settings"
                                icon={Icon.Gear}
                                onAction={() => void openExtensionPreferences()}
                            />
                        </ActionPanel>
                    }
                />
            ) : (
                <List.EmptyView icon={Icon.MagnifyingGlass} title="No extensions found" />
            )}
            <List.Section title="Repositories">{problems.map(problemItem)}</List.Section>
            <List.Section title="Installed">{installedItems.map((row) => row.node)}</List.Section>
            <List.Section title="Extensions">{other.map(item)}</List.Section>
        </List>
    );
}
