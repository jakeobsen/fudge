import { AI, captureMemorySnapshot, showHUD } from "@raycast/api";

export default async function Command() {
    captureMemorySnapshot("start");
    await showHUD(await AI.ask("Describe the weather"));
}
