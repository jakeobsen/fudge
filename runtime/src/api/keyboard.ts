// Keyboard: the common shortcuts. Their key combinations are the ones
// Raycast documents for Keyboard.Shortcut.Common, as { macOS, Windows } pairs.

type Shortcut = { modifiers: string[]; key: string };
const pair = (macOS: Shortcut, Windows: Shortcut) => Object.freeze({ macOS, Windows });
const key = (modifiers: string[], key: string): Shortcut => ({ modifiers, key });

const Common = Object.freeze({
    Copy: pair(key(["cmd", "shift"], "c"), key(["ctrl", "shift"], "c")),
    CopyDeeplink: pair(key(["cmd", "shift"], "c"), key(["ctrl", "shift"], "c")),
    CopyName: pair(key(["cmd", "opt"], "c"), key(["ctrl", "alt"], "c")),
    CopyPath: pair(key(["cmd", "ctrl"], "c"), key(["alt", "shift"], "c")),
    Save: pair(key(["cmd"], "s"), key(["ctrl"], "s")),
    Duplicate: pair(key(["cmd"], "d"), key(["ctrl", "shift"], "s")),
    Edit: pair(key(["cmd"], "e"), key(["ctrl"], "e")),
    MoveDown: pair(key(["cmd", "opt"], "arrowDown"), key(["ctrl", "alt"], "arrowDown")),
    MoveUp: pair(key(["cmd", "opt"], "arrowUp"), key(["ctrl", "alt"], "arrowUp")),
    New: pair(key(["cmd"], "n"), key(["ctrl"], "n")),
    Open: pair(key(["cmd"], "o"), key(["ctrl"], "o")),
    OpenWith: pair(key(["cmd", "shift"], "o"), key(["ctrl", "shift"], "o")),
    Pin: pair(key(["cmd"], "."), key(["ctrl"], ".")),
    Refresh: pair(key(["cmd"], "r"), key(["ctrl"], "r")),
    Remove: pair(key(["ctrl"], "x"), key(["ctrl"], "d")),
    RemoveAll: pair(key(["ctrl", "shift"], "x"), key(["ctrl", "alt"], "d")),
    ToggleQuickLook: pair(key(["cmd"], "y"), key(["ctrl"], "y")),
});

export const Keyboard = Object.freeze({ Shortcut: Object.freeze({ Common }) });
