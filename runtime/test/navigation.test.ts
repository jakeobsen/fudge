import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement as h, useState } from "react";
import { Action, ActionPanel, Detail, List, useNavigation } from "../src/api/index.ts";
import { find, mount } from "./support/mount.ts";

function Root({ onPop }: { onPop?: () => void }) {
    const [visits, setVisits] = useState(0);
    return h(
        List,
        null,
        h(List.Item, {
            title: `visits ${visits}`,
            actions: h(
                ActionPanel,
                null,
                h(Action, { title: "Visit", onAction: () => setVisits((v) => v + 1) }),
                h(Action.Push, { title: "Show", target: h(Detail, { markdown: "pushed" }), onPop }),
            ),
        }),
    );
}

function actionTitled(node: Parameters<typeof find>[0], title: string) {
    const panel = find(node, "ActionPanel")!;
    return panel.children.find((child) => child.props.title === title)!;
}

test("Action.Push shows its target on top; popping keeps the earlier view's state", async () => {
    const mounted = await mount(h(Root));

    let next = mounted.next();
    mounted.root.dispatch(actionTitled(mounted.first.view, "Visit").id, ["onAction"], []);
    const visited = await next;
    assert.equal(find(visited.view, "List.Item")!.props.title, "visits 1");

    next = mounted.next();
    mounted.root.dispatch(actionTitled(visited.view, "Show").id, ["onAction"], []);
    const pushed = await next;
    assert.equal(pushed.depth, 2);
    assert.equal(pushed.view!.type, "Detail");
    assert.equal(pushed.view!.props.markdown, "pushed");

    next = mounted.next();
    mounted.navigation.current!.pop();
    const popped = await next;
    assert.equal(popped.depth, 1);
    assert.equal(find(popped.view, "List.Item")!.props.title, "visits 1", "state survived the push");
});

test("onPop runs once, after the pop", async () => {
    let pops = 0;
    const mounted = await mount(h(Root, { onPop: () => pops++ }));
    let next = mounted.next();
    mounted.root.dispatch(actionTitled(mounted.first.view, "Show").id, ["onAction"], []);
    await next;

    next = mounted.next();
    mounted.navigation.current!.pop();
    mounted.navigation.current!.pop(); // already at the root: ignored
    await next;
    await mounted.settle();
    assert.equal(pops, 1);
});

test("useNavigation pushes and pops from inside a view", async () => {
    function Pushed() {
        const { pop } = useNavigation();
        return h(Detail, { markdown: "inner", actions: h(ActionPanel, null, h(Action, { title: "Back", onAction: pop })) });
    }
    function Outer() {
        const { push } = useNavigation();
        return h(Detail, { markdown: "outer", actions: h(ActionPanel, null, h(Action, { title: "In", onAction: () => push(h(Pushed)) })) });
    }
    const mounted = await mount(h(Outer));

    let next = mounted.next();
    mounted.root.dispatch(find(mounted.first.view, "Action")!.id, ["onAction"], []);
    const inner = await next;
    assert.equal(inner.view!.props.markdown, "inner");

    next = mounted.next();
    mounted.root.dispatch(find(inner.view, "Action")!.id, ["onAction"], []);
    const outer = await next;
    assert.equal(outer.view!.props.markdown, "outer");
    assert.equal(outer.depth, 1);
});

test("useNavigation outside a command's view throws", async () => {
    function Lost() {
        useNavigation();
        return null;
    }
    const { createRoot } = await import("../src/renderer/root.ts");
    const errors: unknown[] = [];
    const root = createRoot({ onRender: () => {}, onError: (e) => errors.push(e) });
    root.render(h(Lost));
    for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
    assert.match(String(errors[0]), /only be used inside a command's view/);
});
