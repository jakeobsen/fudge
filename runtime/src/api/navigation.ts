// Navigation: `useNavigation()` and the stack of views behind it.
//
// Every pushed view stays mounted, so its state survives a pop; each sits in
// its own `$view` host instance and the root sends only the top one.

import { createContext, createElement, useContext, useMemo, useRef, useState, type ReactNode } from "react";
import { VIEW } from "../renderer/root.ts";

export type Navigation = {
    push(view: ReactNode, onPop?: () => void): void;
    pop(): void;
};

type Entry = { key: number; view: ReactNode; onPop?: () => void };

const NavigationContext = createContext<Navigation | null>(null);

export function useNavigation(): Navigation {
    const navigation = useContext(NavigationContext);
    if (!navigation) throw new Error("useNavigation can only be used inside a command's view");
    return navigation;
}

/** Exposes `pop` to the host, which calls it when the user presses Esc on a pushed view. */
export type NavigationHandle = { current: Navigation | null };

export function NavigationRoot({ root, handle }: { root: ReactNode; handle?: NavigationHandle }) {
    // The stack lives in a ref so push and pop can act on it immediately (and
    // run onPop exactly once); the counter only asks React to render again.
    const stack = useRef<Entry[]>([{ key: 0, view: root }]);
    const [, setVersion] = useState(0);

    const navigation = useMemo<Navigation>(() => {
        let nextKey = 1;
        return {
            push(view, onPop) {
                stack.current = [...stack.current, { key: nextKey++, view, onPop }];
                setVersion((version) => version + 1);
            },
            pop() {
                if (stack.current.length <= 1) return;
                const popped = stack.current[stack.current.length - 1]!;
                stack.current = stack.current.slice(0, -1);
                setVersion((version) => version + 1);
                if (popped.onPop) queueMicrotask(popped.onPop);
            },
        };
    }, []);
    if (handle) handle.current = navigation;

    return createElement(
        NavigationContext.Provider,
        { value: navigation },
        stack.current.map((entry) => createElement(VIEW, { key: entry.key }, entry.view)),
    );
}
