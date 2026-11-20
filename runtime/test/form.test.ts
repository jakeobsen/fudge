import assert from "node:assert/strict";
import { test } from "node:test";
import { createElement as h, useState } from "react";
import { Action, ActionPanel, Form } from "../src/api/index.ts";
import type { UINode } from "../src/renderer/serialize.ts";
import { connect, type RpcRequest } from "../src/bridge.ts";
import { find, mount, type Mounted } from "./support/mount.ts";

function submitAction(onSubmit: (values: Record<string, unknown>) => void) {
    return h(ActionPanel, null, h(Action.SubmitForm, { onSubmit }));
}

async function submit(mounted: Mounted): Promise<void> {
    const view = mounted.snapshots.at(-1)!.view!;
    mounted.root.dispatch(find(view, "Action")!.id, ["onAction"], []);
    await mounted.settle();
}

async function type(mounted: Mounted, fieldType: string, value: unknown): Promise<void> {
    const view = mounted.snapshots.at(-1)!.view!;
    mounted.root.dispatch(find(view, fieldType)!.id, ["onChange"], [value]);
    await mounted.settle();
}

test("Submit Form collects every field's value by id", async () => {
    const submitted: unknown[] = [];
    const mounted = await mount(
        h(
            Form,
            { actions: submitAction((values) => submitted.push(values)) },
            h(Form.Description, { text: "Fill this in" }),
            h(Form.TextField, { id: "name", defaultValue: "otter" }),
            h(Form.TextArea, { id: "notes" }),
            h(Form.Checkbox, { id: "done", label: "Done", value: true }),
            h(Form.PasswordField, { id: "secret" }),
        ),
    );
    await type(mounted, "Form.TextArea", "typed here");
    await submit(mounted);
    assert.deepEqual(submitted, [{ name: "otter", notes: "typed here", done: true, secret: "" }]);
});

test("fields always give the app an onChange, and the extension's own still hears it", async () => {
    const heard: unknown[] = [];
    const mounted = await mount(
        h(Form, null, h(Form.TextField, { id: "plain" }), h(Form.TextArea, { id: "watched", onChange: (v: unknown) => heard.push(v) })),
    );
    const view = mounted.first.view!;
    assert.equal(view.type, "Form");
    const plain = find(view, "Form.TextField")!;
    assert.deepEqual(plain.props.onChange, { $fn: ["onChange"] });
    await type(mounted, "Form.TextArea", "hello");
    assert.deepEqual(heard, ["hello"]);
});

test("a field remounted under a new key starts from its new defaultValue", async () => {
    // next-task's Edit Workflow bumps the key to load new text into an uncontrolled text area.
    const submitted: unknown[] = [];
    let replace: () => void = () => {};
    function Editor() {
        const [generation, setGeneration] = useState(0);
        replace = () => setGeneration((n) => n + 1);
        return h(
            Form,
            { actions: submitAction((values) => submitted.push(values)) },
            h(Form.TextArea, { key: generation, id: "workflow", defaultValue: generation === 0 ? "saved" : "example" }),
        );
    }
    const mounted = await mount(h(Editor));
    await type(mounted, "Form.TextArea", "edited");
    replace();
    await mounted.settle();
    await submit(mounted);
    assert.deepEqual(submitted, [{ workflow: "example" }]);
});

test("a controlled field submits the extension's value, and an unmounted field drops out", async () => {
    const submitted: unknown[] = [];
    let hide: () => void = () => {};
    function Controlled() {
        const [title, setTitle] = useState("first");
        const [shown, setShown] = useState(true);
        hide = () => setShown(false);
        return h(
            Form,
            { actions: submitAction((values) => submitted.push(values)) },
            h(Form.TextField, { id: "title", value: title.toUpperCase(), onChange: setTitle }),
            shown ? h(Form.TextField, { id: "extra", defaultValue: "x" }) : null,
        );
    }
    const mounted = await mount(h(Controlled));
    await type(mounted, "Form.TextField", "second");
    await submit(mounted);
    hide();
    await mounted.settle();
    await submit(mounted);
    assert.deepEqual(submitted, [{ title: "SECOND", extra: "x" }, { title: "SECOND" }]);
    const field = find(mounted.snapshots.at(-1)!.view, "Form.TextField") as UINode;
    assert.equal(field.props.value, "SECOND", "the app sees the controlled value");
});

test("a Dropdown submits its string and a TagPicker its array, as the app reports them", async () => {
    const submitted: unknown[] = [];
    const mounted = await mount(
        h(
            Form,
            { actions: submitAction((values) => submitted.push(values)) },
            h(
                Form.Dropdown,
                { id: "lang" },
                h(Form.Dropdown.Item, { value: "swift", title: "Swift" }),
                h(Form.Dropdown.Section, { title: "Web" }, h(Form.Dropdown.Item, { value: "ts", title: "TypeScript" })),
            ),
            h(Form.TagPicker, { id: "tags" }, h(Form.TagPicker.Item, { value: "red", title: "Red" })),
        ),
    );
    await submit(mounted);
    // Until the app reports a choice, a Dropdown has none and a TagPicker is empty.
    assert.deepEqual(submitted.at(-1), { tags: [] });
    await type(mounted, "Form.Dropdown", "ts");
    await type(mounted, "Form.TagPicker", ["red"]);
    await submit(mounted);
    assert.deepEqual(submitted.at(-1), { lang: "ts", tags: ["red"] });
});

test("onFocus and onBlur pass through to the extension with the app's FormEvent", async () => {
    const heard: unknown[] = [];
    const mounted = await mount(
        h(
            Form,
            null,
            h(Form.TextField, {
                id: "name",
                onFocus: (event: unknown) => heard.push(event),
                onBlur: (event: unknown) => heard.push(event),
            }),
        ),
    );
    const field = find(mounted.first.view!, "Form.TextField")!;
    assert.deepEqual(field.props.onFocus, { $fn: ["onFocus"] });
    const focus = { target: { id: "name", value: "" }, type: "focus" };
    const blur = { target: { id: "name", value: "typed" }, type: "blur" };
    mounted.root.dispatch(field.id, ["onFocus"], [focus]);
    mounted.root.dispatch(field.id, ["onBlur"], [blur]);
    await mounted.settle();
    assert.deepEqual(heard, [focus, blur]);
});

test("submitting sends the values of fields with storeValue to the app, never a password", async () => {
    const sent: RpcRequest[] = [];
    connect((request) => sent.push(request));
    try {
        const submitted: unknown[] = [];
        const mounted = await mount(
            h(
                Form,
                { actions: submitAction((values) => submitted.push(values)) },
                h(Form.TextField, { id: "name", storeValue: true, defaultValue: "otter" }),
                h(Form.TextField, { id: "plain", defaultValue: "x" }),
                h(Form.PasswordField, { id: "secret", storeValue: true, defaultValue: "hunter2" }),
                h(Form.TagPicker, { id: "tags", storeValue: true }, h(Form.TagPicker.Item, { value: "red", title: "Red" })),
            ),
        );
        await type(mounted, "Form.TagPicker", ["red"]);
        await submit(mounted);
        assert.equal(submitted.length, 1, "the extension's onSubmit still runs");
        assert.deepEqual(
            sent.map((request) => [request.method, request.params]),
            [["form.storeValues", { values: { name: "otter", tags: ["red"] } }]],
        );
    } finally {
        connect(null);
    }
});
