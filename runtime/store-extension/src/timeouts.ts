// How long each program the store runs may take, in milliseconds. Every timeout the store passes is one of these.

/** A git command that works on the local copy only: `rev-parse`, `ls-tree`, `symbolic-ref`, `for-each-ref`, `update-ref`,
 * `reflog`, `sparse-checkout set`, and `xcode-select -p` and `git --version`. */
export const shortTimeout = 30_000;

/** A git command that downloads, or rewrites the whole copy: `clone`, `fetch`, a checkout that fetches files (the
 * list's manifests after a clone or refresh, a README, an extension's source through `sparse-checkout add`), and
 * `gc`. A slow connection can take a while. */
export const longTimeout = 120_000;

/** `fudge scan`, which reads an extension's source without building it. */
export const scanTimeout = 120_000;

/** `fudge build`, the longest step: npm may install the extension's packages first. */
export const buildTimeout = 600_000;
