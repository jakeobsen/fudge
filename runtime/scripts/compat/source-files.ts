// Which files under an extension's `src/` the compatibility scan reads. The Extension Store's check fetches, counts
// and checks out the files with these extensions (SPEC-119), so it takes them from here; this module imports nothing,
// so the store's bundle gets only these lines.

/** The extensions of the scripts the scan reads, in the order `fudge build` looks for a command's entry. */
export const sourceExtensions = ["tsx", "ts", "jsx", "js"] as const;

const script = new RegExp(`\\.(?:${sourceExtensions.join("|")})$`);

/** Whether a name ends with one of `sourceExtensions`, declaration files, tests and mocks included. */
export function hasSourceExtension(name: string): boolean {
    return script.test(name);
}

/**
 * Whether a file under an extension's `src/` is extension code: a script, not a declaration file, and not a test
 * or mock (`*.test.*`, `*.spec.*`, or inside `__mocks__/`, `__tests__/`, `test/` or `tests/`).
 */
export function isExtensionSource(relativePath: string): boolean {
    if (!hasSourceExtension(relativePath) || relativePath.endsWith(".d.ts")) return false;
    const segments = relativePath.split(/[\\/]/);
    if (segments.includes("node_modules")) return false;
    if (segments.slice(0, -1).some((folder) => ["__mocks__", "__tests__", "test", "tests"].includes(folder))) return false;
    return !/\.(test|spec)\.[^.]+$/.test(segments.at(-1)!);
}
