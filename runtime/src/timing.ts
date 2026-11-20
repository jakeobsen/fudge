// Temporary timing logs for FUD-81, on stderr while FUDGE_TIMING is set.
import { writeSync } from "node:fs";

const on = !!process.env.FUDGE_TIMING;
export const now = (): number => performance.timeOrigin + performance.now();
export function timing(stage: string, fields = ""): void {
    if (on) writeSync(2, `fudge-timing ${now().toFixed(1)} ${stage} ${fields}\n`);
}
