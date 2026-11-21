// The deprecated top-level `render()`. Before default exports, a command module called `render(<Command />)` from
// @raycast/api while it loaded, and exported nothing. The worker loads every command module through `recordRender`,
// and mounts the element recorded there when the module has no default export.

import type { ReactNode } from "react";

type Recording = { called: boolean; element?: ReactNode };

let recording: Recording | null = null;

/** Raycast's deprecated `render(element)`. Only a call while the command module loads counts; any other does nothing. */
export function render(element: ReactNode): void {
    if (!recording) return;
    if (recording.called) {
        console.error("render() was called again while the command loaded; Fudge shows the first element");
        return;
    }
    recording.called = true;
    recording.element = element;
}

/** Runs `load`, the command module's `require`, and returns what it gave, with the element `render` first got meanwhile. */
export function recordRender<T>(load: () => T): { result: T; rendered?: { element: ReactNode } } {
    const own: Recording = { called: false };
    recording = own;
    try {
        const result = load();
        return own.called ? { result, rendered: { element: own.element } } : { result };
    } finally {
        recording = null;
    }
}
