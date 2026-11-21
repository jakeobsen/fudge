// Reading files from the store's copy: regular files only, never through a link, and never too big. The copy comes
// from a repository anyone can send changes to, and git checks out a committed link as a link.

import { constants } from "node:fs";
import { open } from "node:fs/promises";

/** The most an extension's `package.json` may hold for the list. */
export const maxManifestBytes = 1024 * 1024;
/** The most a README may hold for the detail pane. */
export const maxReadmeBytes = 1024 * 1024;
/** The most a lockfile may hold for the package-source check. */
export const maxLockfileBytes = 50 * 1024 * 1024;

/**
 * `file` as UTF-8, if it's a regular file of at most `maxBytes`. A link isn't followed (`O_NOFOLLOW`), and a FIFO or
 * device is never waited on (`O_NONBLOCK`), so `README.md -> /dev/zero` can't make the store read forever. Rejects
 * anything else: a link, a device, a FIFO, a folder, or a file that's too big.
 */
export async function readRegularFile(file: string, maxBytes: number): Promise<string> {
    const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const info = await handle.stat();
        if (!info.isFile()) throw new Error(`${file} isn't a regular file`);
        if (info.size > maxBytes) throw new Error(`${file} is bigger than ${maxBytes} bytes`);
        const buffer = Buffer.alloc(info.size);
        let read = 0;
        while (read < info.size) {
            const { bytesRead } = await handle.read(buffer, read, info.size - read, read);
            if (bytesRead === 0) break;
            read += bytesRead;
        }
        return buffer.subarray(0, read).toString("utf8");
    } finally {
        await handle.close();
    }
}
