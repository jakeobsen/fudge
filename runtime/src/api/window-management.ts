// WindowManagement: the app reads the window list and moves windows through the Accessibility API, asked for over
// rpc (see bridge.ts). macOS has no public way to list Spaces, so each screen is one desktop: the Space on it now.

import { callApp } from "../bridge.ts";
import { RAYCAST_ENUMS } from "./raycast-enums.generated.ts";

type Application = { name: string; path: string; bundleId?: string };
type Bounds = { position: { x: number; y: number }; size: { width: number; height: number } };
type Window = {
    id: string;
    application?: Application;
    bounds: Bounds | "fullscreen";
    desktopId: string;
    fullScreenSettable: boolean;
    resizable: boolean;
    positionable: boolean;
    active: boolean;
};
type Desktop = {
    size: { width: number; height: number };
    id: string;
    screenId: string;
    active: boolean;
    type: (typeof DesktopType)[keyof typeof DesktopType];
};
type BoundsOptions =
    | {
          id: string;
          bounds: { position?: { x?: number; y?: number }; size?: { width?: number; height?: number } };
          desktopId?: string;
      }
    | { id: string; bounds: "fullscreen" };

const DesktopType = Object.freeze({ ...RAYCAST_ENUMS.WindowManagementDesktopType });

export const WindowManagement = {
    DesktopType,
    /** One desktop per screen: the Space showing on it now. */
    async getDesktops(): Promise<Desktop[]> {
        return callApp<Desktop[]>("windows.desktops");
    },
    /** The frontmost app's focused window. Rejects when there's none. */
    async getActiveWindow(): Promise<Window> {
        return callApp<Window>("windows.active");
    },
    /** The windows on the active desktop (the active window's screen), front to back. */
    async getWindowsOnActiveDesktop(): Promise<Window[]> {
        return callApp<Window[]>("windows.onActiveDesktop");
    },
    /** Moves or resizes a window, or makes it full screen. Parts of the bounds left out keep their current value. */
    async setWindowBounds(options: BoundsOptions): Promise<void> {
        const { id, bounds } = options;
        const desktopId = "desktopId" in options ? options.desktopId : undefined;
        await callApp("windows.setBounds", desktopId === undefined ? { id, bounds } : { id, bounds, desktopId });
    },
};
