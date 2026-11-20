import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement as h, useState } from "react";
import { Action, ActionPanel, Detail, Form, List } from "../src/api/index.ts";
import { StaleCallbackError } from "../src/renderer/root.ts";
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
