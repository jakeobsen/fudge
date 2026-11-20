// How extensions talk back to the user: toasts, the HUD, alerts, and the
// window calls (closeMainWindow, popToRoot, clearSearchBar). The app shows
// them; a toast's actions come back as `toastAction` messages (see worker.ts).

import { callApp } from "../bridge.ts";
import { RAYCAST_ENUMS } from "./raycast-enums.generated.ts";

const ToastStyle = Object.freeze({ ...RAYCAST_ENUMS.ToastStyle_2 });
const AlertActionStyle = Object.freeze({ ...RAYCAST_ENUMS.AlertActionStyle_2 });

type ToastStyleValue = (typeof ToastStyle)[keyof typeof ToastStyle];
type Shortcut = { modifiers: string[]; key: string };
type ToastAction = { title: string; shortcut?: Shortcut; onAction: (toast: Toast) => void };
type ToastOptions = {
    title: string;
    message?: string;
    style?: ToastStyleValue;
    primaryAction?: ToastAction;
    secondaryAction?: ToastAction;
};

let nextToastId = 1;
const toasts = new Map<number, Toast>();

/** A toast in the launcher's bottom bar. Changing a shown toast updates it in place. */
export class Toast {
    static readonly Style = ToastStyle;

    readonly #id = nextToastId++;
    #options: ToastOptions;
    #shown = false;

    constructor(options: ToastOptions) {
        this.#options = { style: ToastStyle.Success, ...options };
    }

    get style(): ToastStyleValue {
        return this.#options.style ?? ToastStyle.Success;
    }
    set style(style: ToastStyleValue) {
        this.#change({ style });
    }
    get title(): string {
        return this.#options.title;
    }
    set title(title: string) {
        this.#change({ title });
    }
    get message(): string | undefined {
        return this.#options.message;
    }
    set message(message: string | undefined) {
        this.#change({ message });
    }
    get primaryAction(): ToastAction | undefined {
        return this.#options.primaryAction;
    }
    set primaryAction(primaryAction: ToastAction | undefined) {
        this.#change({ primaryAction });
    }
    get secondaryAction(): ToastAction | undefined {
        return this.#options.secondaryAction;
    }
    set secondaryAction(secondaryAction: ToastAction | undefined) {
        this.#change({ secondaryAction });
    }

    async show(): Promise<void> {
        this.#shown = true;
        toasts.set(this.#id, this);
        await callApp("toast.show", this.#payload());
    }

    async hide(): Promise<void> {
        this.#shown = false;
        toasts.delete(this.#id);
        await callApp("toast.hide", { id: this.#id });
    }

    /** Runs one of the toast's actions; called when the user picks it in the app. */
    static runAction(id: number, which: "primary" | "secondary"): void {
        const toast = toasts.get(id);
        const action = which === "primary" ? toast?.primaryAction : toast?.secondaryAction;
        if (toast && action) action.onAction(toast);
    }

    #change(changes: Partial<ToastOptions>): void {
        this.#options = { ...this.#options, ...changes };
        if (this.#shown) void callApp("toast.show", this.#payload()).catch(() => {});
    }

    #payload() {
        const action = (option?: ToastAction) => (option ? { title: option.title, shortcut: option.shortcut ?? null } : null);
        return {
            id: this.#id,
            title: this.#options.title,
            message: this.#options.message ?? null,
            style: this.style,
            primaryAction: action(this.#options.primaryAction),
            secondaryAction: action(this.#options.secondaryAction),
        };
    }
}

/** Shows a toast. Also accepts Raycast's old form, `showToast(style, title, message)`. */
export async function showToast(options: ToastOptions | ToastStyleValue, title?: string, message?: string): Promise<Toast> {
    const toast = new Toast(typeof options === "string" ? { style: options, title: title ?? "", message } : options);
    await toast.show();
    return toast;
}

type WindowOptions = { clearRootSearch?: boolean; popToRootType?: string };

/** Closes the window and shows `title` briefly near the bottom of the screen. */
export async function showHUD(title: string, options: WindowOptions = {}): Promise<void> {
    await callApp("hud.show", { title, clearRootSearch: options.clearRootSearch ?? false, popToRootType: options.popToRootType ?? "default" });
}

export async function closeMainWindow(options: WindowOptions = {}): Promise<void> {
    await callApp("window.close", { clearRootSearch: options.clearRootSearch ?? false, popToRootType: options.popToRootType ?? "default" });
}

export async function popToRoot(options: { clearSearchBar?: boolean } = {}): Promise<void> {
    await callApp("window.popToRoot", { clearSearchBar: options.clearSearchBar ?? false });
}

export async function clearSearchBar(options: { forceScrollToTop?: boolean } = {}): Promise<void> {
    await callApp("searchBar.clear", { forceScrollToTop: options.forceScrollToTop ?? false });
}

type AlertAction = { title: string; style?: string; onAction?: () => void };
type AlertOptions = {
    title: string;
    message?: string;
    icon?: unknown;
    primaryAction?: AlertAction;
    dismissAction?: AlertAction;
    rememberUserChoice?: boolean;
};

export const Alert = Object.freeze({ ActionStyle: AlertActionStyle });

/** @deprecated Raycast's old names for Toast.Style and Alert.ActionStyle. */
export { AlertActionStyle, ToastStyle };

/** Asks the user to confirm. Resolves true when they pick the primary action. */
export async function confirmAlert(options: AlertOptions): Promise<boolean> {
    const action = (option: AlertAction | undefined) => (option ? { title: option.title, style: option.style ?? null } : null);
    const confirmed = await callApp<boolean>("alert.confirm", {
        title: options.title,
        message: options.message ?? null,
        icon: options.icon ?? null,
        primaryAction: action(options.primaryAction),
        dismissAction: action(options.dismissAction),
    });
    (confirmed ? options.primaryAction : options.dismissAction)?.onAction?.();
    return confirmed === true;
}
