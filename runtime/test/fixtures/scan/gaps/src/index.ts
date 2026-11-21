import { AI, WindowManagement, showHUD } from "@raycast/api";

export default async function Command() {
    const window = await WindowManagement.getActiveWindow();
    await showHUD(await AI.ask(`Describe ${window.id}`));
}
