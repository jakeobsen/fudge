import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement as h, useState } from "react";
import { Action, ActionPanel, Detail, Form, Grid, List } from "../src/api/index.ts";
import { StaleCallbackError } from "../src/renderer/root.ts";
import type { UINode } from "../src/renderer/serialize.ts";
import { find, mount } from "./support/mount.ts";

test("a List renders as a tree of host nodes, with element props as nodes", async () => {
    const { first } = await mount(
        h(
            List,
            { searchBarPlaceholder: "Search folders", isLoading: false },
            h(
                List.Section,
                { title: "Recent" },
                h(List.Item, {
                    id: "a",
                    title: "alpha",
                    subtitle: "~/scratch/alpha",
                    accessories: [{ text: "2d" }, { icon: { source: "pin.png", tintColor: "raycast-orange" } }],
                    actions: h(ActionPanel, null, h(Action, { title: "Open", onAction: () => {} })),
                }),
            ),
        ),
    );

    assert.equal(first.depth, 1);
    const list = first.view!;
    assert.equal(list.type, "List");
    assert.deepEqual(list.props, { searchBarPlaceholder: "Search folders", isLoading: false });

    const item = find(list, "List.Item")!;
    assert.deepEqual(item.props.accessories, [
        { text: "2d" },
        { icon: { source: "pin.png", tintColor: "raycast-orange" } },
    ]);
    assert.equal(item.children.length, 0, "the action panel is a prop, not a child");

    const panel = item.props.actions as unknown as { type: string; children: { type: string; props: object }[] };
    assert.equal(panel.type, "ActionPanel");
    assert.deepEqual(panel.children[0]!.props, { title: "Open", onAction: { $fn: ["onAction"] } });
});

test("only the first item and the ones the app asked for carry their actions and detail", async () => {
    const item = (n: number) =>
        h(List.Item, {
            key: n,
            title: `item ${n}`,
            actions: h(ActionPanel, null, h(Action, { title: `Open ${n}`, onAction: () => {} })),
            detail: h(List.Item.Detail, { markdown: `# ${n}` }),
        });
    const Nothing = () => null;
    const mounted = await mount(
        h(
            List,
            { actions: h(ActionPanel, null, h(Action, { title: "List's own", onAction: () => {} })) },
            h(List.Section, { title: "Projects" }, item(1), item(2), item(3)),
            h(List.Item, { title: "no actions" }),
            h(List.Item, { title: "actions that render nothing", actions: h(Nothing) }),
        ),
    );
    const items = (view: UINode | null) => [...view!.children[0]!.children, ...view!.children.slice(1)];
    const [one, two, three, none, nothing] = items(mounted.first.view);

    assert.equal(find(mounted.first.view, "ActionPanel")?.children[0]?.props.title, "List's own");
    assert.equal((one!.props.actions as unknown as UINode).type, "ActionPanel");
    assert.equal((one!.props.detail as unknown as UINode).type, "List.Item.Detail");
    assert.deepEqual(two!.props.actions, { $deferred: true });
    assert.deepEqual(two!.props.detail, { $deferred: true });
    assert.deepEqual(three!.props.actions, { $deferred: true });
    assert.equal("actions" in none!.props, false);
    assert.equal(nothing!.props.actions, null);

    // The app asks for item 3, an id that isn't mounted and an item without slots. It gets what a snapshot would
    // carry, nothing for the other two, and later snapshots carry item 3's slots too.
    const answered = mounted.root.slots([three!.id, 9999, none!.id]);
    const later = items(mounted.root.snapshot().view);
    assert.deepEqual(answered, [
        { id: three!.id, slots: { actions: later[2]!.props.actions, detail: later[2]!.props.detail } },
        { id: 9999, slots: {} },
        { id: none!.id, slots: {} },
    ]);
    const panel = answered[0]!.slots.actions as unknown as UINode;
    assert.deepEqual(panel.children[0]!.props, { title: "Open 3", onAction: { $fn: ["onAction"] } });
    assert.equal((later[0]!.props.actions as unknown as UINode).type, "ActionPanel");
    assert.deepEqual(later[1]!.props.actions, { $deferred: true });
});

test("the item selectedItemId names carries its actions and detail in the first snapshot, and only it", async () => {
    const item = (n: number) =>
        h(List.Item, {
            key: n,
            id: `item-${n}`,
            title: `item ${n}`,
            actions: h(ActionPanel, null, h(Action, { title: `Open ${n}`, onAction: () => {} })),
            detail: h(List.Item.Detail, { markdown: `# ${n}` }),
        });
    const numbers = Array.from({ length: 1000 }, (_, index) => index + 1);
    let select: (selected: unknown) => void = () => {};
    const Selecting = () => {
        const [selected, setSelected] = useState<unknown>("item-500");
        select = setSelected;
        return h(List, { selectedItemId: selected }, numbers.map(item));
    };
    const mounted = await mount(h(Selecting));
    const carried = (view: UINode | null) =>
        view!.children.filter((child) => (child.props.actions as unknown as UINode).type === "ActionPanel");
    const titles = (view: UINode | null) => carried(view).map((child) => child.props.title);

    // The first item and item 500, never its neighbours.
    assert.deepEqual(titles(mounted.first.view), ["item 1", "item 500"]);
    const five = mounted.first.view!.children[499]!;
    assert.equal((five.props.detail as unknown as UINode).type, "List.Item.Detail");
    assert.deepEqual(mounted.first.view!.children[498]!.props.actions, { $deferred: true });
    assert.deepEqual(mounted.first.view!.children[500]!.props.actions, { $deferred: true });

    // It's read in each snapshot: a controlled selection that moves takes its slots along.
    const after = async (selected: unknown) => {
        const next = mounted.next();
        select(selected);
        return titles((await next).view);
    };
    assert.deepEqual(await after("item-750"), ["item 1", "item 750"]);
    // An id that names no item, or isn't a string, adds nothing.
    assert.deepEqual(await after("item-5000"), ["item 1"]);
    assert.deepEqual(await after(500), ["item 1"]);

    // Only one item, even when two share the id: the first, as the app selects.
    const twice = await mount(
        h(List, { selectedItemId: "same" }, item(1), h(List.Item, { key: "a", id: "same", title: "a", actions: h(ActionPanel, null, h(Action, { title: "A", onAction: () => {} })) }), h(List.Item, { key: "b", id: "same", title: "b", actions: h(ActionPanel, null, h(Action, { title: "B", onAction: () => {} })) })),
    );
    assert.deepEqual(titles(twice.first.view), ["item 1", "a"]);

    // A Grid too.
    const cell = (n: number) =>
        h(Grid.Item, { key: n, id: `cell-${n}`, title: `cell ${n}`, content: "x.png", actions: h(ActionPanel, null, h(Action, { title: `Open ${n}`, onAction: () => {} })) });
    const grid = await mount(h(Grid, { selectedItemId: "cell-40" }, numbers.slice(0, 100).map(cell)));
    assert.deepEqual(titles(grid.first.view), ["cell 1", "cell 40"]);
});

test("the items a render carries in full match what a full render sends", async () => {
    const item = (n: number) =>
        h(List.Item, {
            key: n,
            title: `item ${n}`,
            actions: h(
                ActionPanel,
                null,
                h(ActionPanel.Section, null, h(Action, { title: `Open ${n}`, shortcut: { modifiers: ["cmd"], key: "o" }, onAction: () => {} })),
                h(ActionPanel.Submenu, { title: "More" }, h(Action, { title: `Copy ${n}`, onAction: () => {} })),
            ),
            detail: h(List.Item.Detail, { markdown: `# ${n}`, metadata: h(List.Item.Detail.Metadata, null, h(List.Item.Detail.Metadata.Label, { title: "n", text: String(n) })) }),
        });
    const mounted = await mount(h(List, { isShowingDetail: true }, item(1), item(2), item(3), item(4)));
    const ids = mounted.first.view!.children.map((child) => child.id);

    // Asking for every item makes a render carry them all, as a render did before items were deferred.
    mounted.root.slots(ids);
    const full = mounted.root.snapshot().view!.children;
    assert.ok(full.every((child) => (child.props.actions as unknown as UINode).type === "ActionPanel"));

    // The first item, in a render that defers, and the selected one (asked for) match the full render exactly.
    mounted.root.slots([ids[2]!]);
    const deferred = mounted.root.snapshot().view!.children;
    assert.deepEqual(deferred[0], full[0]);
    assert.deepEqual(deferred[2], full[2]);
    assert.deepEqual(deferred[1]!.props.actions, { $deferred: true, shortcuts: 0 });
    assert.deepEqual({ ...deferred[1]!.props, actions: full[1]!.props.actions, detail: full[1]!.props.detail }, full[1]!.props);
    assert.deepEqual(mounted.root.slots([ids[1]!]), [{ id: ids[1], slots: { actions: full[1]!.props.actions, detail: full[1]!.props.detail } }]);
});

test("a deferred panel names the shortcuts it uses, each set once per render", async () => {
    const cmd = (key: string) => ({ modifiers: ["cmd"], key });
    const common = { macOS: { modifiers: ["cmd"], key: "backspace" }, Windows: { modifiers: ["ctrl"], key: "backspace" } };
    const Target = () => h(List, { actions: h(ActionPanel, null, h(Action, { title: "Elsewhere", shortcut: cmd("x"), onAction: () => {} })) });
    const usual = (n: number) =>
        h(
            ActionPanel,
            null,
            h(Action, { title: `Open ${n}`, onAction: () => {} }),
            h(ActionPanel.Section, null, h(Action, { title: "Delete", shortcut: common, onAction: () => {} })),
            h(ActionPanel.Submenu, { title: "More" }, h(Action, { title: "Copy", shortcut: cmd("c"), onAction: () => {} })),
            // A pushed view's own actions aren't this panel's.
            h(Action.Push, { title: "Push", target: h(Target) }),
        );
    const mounted = await mount(
        h(
            List,
            null,
            h(List.Item, { key: 1, title: "first", actions: usual(1) }),
            h(List.Item, { key: 2, title: "two", actions: usual(2) }),
            h(List.Item, { key: 3, title: "three", actions: usual(3) }),
            h(List.Item, {
                key: 4,
                title: "four",
                actions: h(ActionPanel, null, h(Action, { title: "Pin", shortcut: cmd("p"), onAction: () => {} })),
            }),
            h(List.Item, { key: 5, title: "five", actions: h(ActionPanel, null, h(Action, { title: "Plain", onAction: () => {} })) }),
        ),
    );
    const view = mounted.first.view!;
    const [, two, three, four, five] = view.children;
    assert.deepEqual(view.props.$shortcutSets, [[common, cmd("c")], [cmd("p")]]);
    assert.deepEqual(two!.props.actions, { $deferred: true, shortcuts: 0 }, "rows with the same shortcuts share a set");
    assert.deepEqual(three!.props.actions, { $deferred: true, shortcuts: 0 });
    assert.deepEqual(four!.props.actions, { $deferred: true, shortcuts: 1 });
    assert.deepEqual(five!.props.actions, { $deferred: true }, "a panel with no shortcuts names no set");

    // With every item carried in full, there's nothing to name.
    mounted.root.slots(view.children.map((child) => child.id));
    assert.equal("$shortcutSets" in mounted.root.snapshot().view!.props, false);
});

test("a deferred panel names a submenu's own shortcut too, so the key waits for it", async () => {
    const cmd = (key: string) => ({ modifiers: ["cmd"], key });
    const panel = () =>
        h(
            ActionPanel,
            null,
            h(Action, { title: "Open", onAction: () => {} }),
            h(ActionPanel.Submenu, { title: "Open With…", shortcut: cmd("o") }, h(Action, { title: "TextEdit", shortcut: cmd("t"), onAction: () => {} })),
        );
    const mounted = await mount(
        h(List, null, h(List.Item, { key: 1, title: "first", actions: panel() }), h(List.Item, { key: 2, title: "two", actions: panel() })),
    );
    const view = mounted.first.view!;
    assert.deepEqual(view.props.$shortcutSets, [[cmd("o"), cmd("t")]]);
    assert.deepEqual(view.children[1]!.props.actions, { $deferred: true, shortcuts: 0 });
});

test("a Grid's items defer their actions too", async () => {
    const cell = (n: number) =>
        h(Grid.Item, {
            key: n,
            content: "x.png",
            actions: h(ActionPanel, null, h(Action, { title: `Open ${n}`, onAction: () => {} })),
        });
    const { first } = await mount(h(Grid, null, cell(1), cell(2)));
    const [one, two] = first.view!.children;
    assert.equal((one!.props.actions as unknown as UINode).type, "ActionPanel");
    assert.deepEqual(two!.props.actions, { $deferred: true });
});

test("a callback makes the round trip and the new state comes back", async () => {
    function Counter() {
        const [count, setCount] = useState(0);
        return h(
            List,
            null,
            h(List.Item, {
                title: `count ${count}`,
                actions: h(ActionPanel, null, h(Action, { title: "Add", onAction: () => setCount((c) => c + 1) })),
            }),
        );
    }
    const mounted = await mount(h(Counter));
    const action = find(mounted.first.view, "Action")!;

    const next = mounted.next();
    mounted.root.dispatch(action.id, ["onAction"], []);
    assert.equal(find((await next).view, "List.Item")!.props.title, "count 1");
});

test("several state changes in one event are sent once", async () => {
    let bump: () => void = () => {};
    function Burst() {
        const [count, setCount] = useState(0);
        const [label, setLabel] = useState("start");
        bump = () => {
            for (let i = 0; i < 10; i++) setCount((c) => c + 1);
            setLabel("done");
        };
        return h(Detail, { markdown: `${label} ${count}`, actions: h(ActionPanel, null, h(Action, { title: "Go", onAction: () => bump() })) });
    }
    const mounted = await mount(h(Burst));
    const action = find(mounted.first.view, "Action")!;
    mounted.root.dispatch(action.id, ["onAction"], []);
    await mounted.settle();
    assert.equal(mounted.snapshots.length, 2, "the first render plus exactly one update");
    assert.equal(mounted.snapshots[1]!.view!.props.markdown, "done 10");
});

test("functions nested in props are addressed by their path", async () => {
    let loaded = 0;
    const mounted = await mount(h(List, { pagination: { hasMore: true, pageSize: 20, onLoadMore: () => loaded++ } }));
    const list = mounted.first.view!;
    assert.deepEqual(list.props.pagination, { hasMore: true, pageSize: 20, onLoadMore: { $fn: ["pagination", "onLoadMore"] } });
    mounted.root.dispatch(list.id, ["pagination", "onLoadMore"], []);
    assert.equal(loaded, 1);
});

test("Detail carries markdown and its metadata as a prop", async () => {
    const { first } = await mount(
        h(Detail, {
            markdown: "# Hello",
            navigationTitle: "Task",
            metadata: h(
                Detail.Metadata,
                null,
                h(Detail.Metadata.Label, { title: "Due", text: "today" }),
                h(Detail.Metadata.Separator),
                h(Detail.Metadata.TagList, { title: "Tags" }, h(Detail.Metadata.TagList.Item, { text: "work", color: "raycast-blue" })),
            ),
        }),
    );
    const detail = first.view!;
    assert.equal(detail.type, "Detail");
    assert.equal(detail.props.markdown, "# Hello");
    const metadata = detail.props.metadata as unknown as { type: string; children: { type: string }[] };
    assert.equal(metadata.type, "Metadata");
    assert.deepEqual(
        metadata.children.map((child) => child.type),
        ["Metadata.Label", "Metadata.Separator", "Metadata.TagList"],
    );
});

test("Form fields render in order, with the action panel as a prop", async () => {
    const { first } = await mount(
        h(
            Form,
            { actions: h(ActionPanel, null, h(Action, { title: "Save", onAction: () => {} })) },
            h(Form.Description, { text: "Write a note" }),
            h(Form.TextArea, { id: "note", title: "Note", defaultValue: "hi" }),
        ),
    );
    const form = first.view!;
    assert.equal(form.type, "Form");
    assert.deepEqual(
        form.children.map((child) => [child.type, child.props]),
        [
            ["Form.Description", { text: "Write a note" }],
            ["Form.TextArea", { id: "note", title: "Note", defaultValue: "hi", onChange: { $fn: ["onChange"] } }],
        ],
    );
    assert.equal((form.props.actions as unknown as { type: string }).type, "ActionPanel");
});

test("dates and repeated objects serialize; cycles don't hang", async () => {
    const shared = { source: "star.png" };
    const cyclic: Record<string, unknown> = { name: "loop" };
    cyclic.self = cyclic;
    const { first } = await mount(
        h(List.Item, { title: "x", date: new Date("2026-01-02T03:04:05Z"), icon: shared, other: shared, cyclic }),
    );
    const props = first.view!.props;
    assert.deepEqual(props.date, { $date: "2026-01-02T03:04:05.000Z" });
    assert.deepEqual(props.icon, shared);
    assert.deepEqual(props.other, shared, "an object used twice is not mistaken for a cycle");
    assert.deepEqual(props.cyclic, { name: "loop", self: null });
});

test("an element prop that goes away disappears from the props", async () => {
    let hide: () => void = () => {};
    function Toggle() {
        const [shown, setShown] = useState(true);
        hide = () => setShown(false);
        return h(Detail, { markdown: "x", actions: shown ? h(ActionPanel, null, h(Action, { title: "A", onAction: () => hide() })) : undefined });
    }
    const mounted = await mount(h(Toggle));
    assert.ok(mounted.first.view!.props.actions);
    const next = mounted.next();
    mounted.root.dispatch(find(mounted.first.view, "Action")!.id, ["onAction"], []);
    assert.equal((await next).view!.props.actions, undefined);
});

test("calling a callback that no longer exists throws StaleCallbackError", async () => {
    const mounted = await mount(h(Detail, { markdown: "x" }));
    assert.throws(() => mounted.root.dispatch(9999, ["onAction"], []), StaleCallbackError);
    assert.throws(() => mounted.root.dispatch(mounted.first.view!.id, ["onAction"], []), StaleCallbackError);
});

test("an error thrown while rendering is reported", async () => {
    function Broken(): never {
        throw new Error("boom");
    }
    const snapshots: unknown[] = [];
    const errors: unknown[] = [];
    const { createRoot } = await import("../src/renderer/root.ts");
    const root = createRoot({ onRender: (s) => snapshots.push(s), onError: (e) => errors.push(e) });
    root.render(h(Broken));
    for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
    assert.equal(errors.length, 1);
    assert.equal((errors[0] as Error).message, "boom");
});
