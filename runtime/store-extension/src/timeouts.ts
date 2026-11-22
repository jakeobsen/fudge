// How long each program the store runs may take, in milliseconds. Every timeout the store passes is one of these.

/** A git command that works on the local copy only: `rev-parse`, `ls-tree`, `symbolic-ref`, `for-each-ref`, `update-ref`,
 * `reflog`, `sparse-checkout set`, and `xcode-select -p` and `git --version`. */
export const shortTimeout = 30_000;

/** A git command that downloads, or rewrites the whole copy: `clone`, `fetch`, a checkout that fetches files (the
 * list's manifests after a clone or refresh, a README, an extension's source through `sparse-checkout add`), and the
 * refresh's `rev-list`, `pack-objects` and `prune`. A slow connection can take a while. */
export const longTimeout = 120_000;

/** `fudge scan`, which reads an extension's source without building it. */
export const scanTimeout = 120_000;

/** `fudge build`, the longest step: npm may install the extension's packages first. */
export const buildTimeout = 600_000;

/**
 * `fudge build` of an extension with a part written in Swift, built with the Command Line Tools (SPEC-145 §3): the first
 * one also fetches and builds SwiftPM's packages. A store extension's first build, with an empty cache, took 324 s
 * (318 s of it SwiftPM's, most of that compiling swift-syntax) on a recent Apple silicon Mac with other builds running,
 * against `buildTimeout`'s 600 s; a Mac half as fast would pass it, so this allows about 3.7 times that build. Later
 * builds reuse the shared cache.
 */
export const swiftBuildTimeout = 1_200_000;
