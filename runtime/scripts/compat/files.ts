// Reading an extension's files for the scan: regular files only, never through a link, and never too big.

import { closeSync, constants, fstatSync, openSync, readSync } from "node:fs";

/** The most a single source file may hold for the scan. A bigger one is reported as unreadable. */
export const maxSourceBytes = 5 * 1024 * 1024;

/** The most an extension's `package.json` may hold. */
export const maxManifestBytes = 1024 * 1024;

/**
 * `file` as UTF-8, if it's a regular file of at most `maxBytes`. A link isn't followed (`O_NOFOLLOW`), and a FIFO or
 * device is never waited on (`O_NONBLOCK`), so `src/x.ts -> /dev/zero` can't make the scan read forever. Throws for
 * anything else: a link, a device, a FIFO, a folder, or a file that's too big.
 */
export function readRegularFile(file: string, maxBytes: number): string {
    const descriptor = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const info = fstatSync(descriptor);
        if (!info.isFile()) throw new Error(`${file} isn't a regular file`);
        if (info.size > maxBytes) throw new Error(`${file} is bigger than ${maxBytes} bytes`);
        const buffer = Buffer.alloc(info.size);
        let read = 0;
        while (read < info.size) {
            const count = readSync(descriptor, buffer, read, info.size - read, read);
            if (count === 0) break;
            read += count;
        }
        return buffer.subarray(0, read).toString("utf8");
    } finally {
        closeSync(descriptor);
    }
}
