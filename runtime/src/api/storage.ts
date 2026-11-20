// LocalStorage (async, per extension) and Cache (sync, per extension).
//
// Both live in files the app names in the launch context. They're read and
// written here, in the worker, with whole-file atomic writes; two commands of
// the same extension running at once can race, and the last write wins.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { launchContext } from "./launch.ts";

type Value = string | number | boolean;

function readJSON(file: string): Record<string, unknown> {
    try {
        const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
        return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {};
    } catch {
        return {};
    }
}

function writeJSON(file: string, value: unknown): void {
    mkdirSync(dirname(file), { recursive: true });
    const temporary = `${file}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
    writeFileSync(temporary, JSON.stringify(value));
    renameSync(temporary, file);
}

const storageFile = () => {
    const file = launchContext().environment.localStoragePath;
    if (!file) throw new Error("LocalStorage isn't available: the app didn't say where to keep it");
    return file;
};

export const LocalStorage = {
    async allItems<T = Record<string, Value>>(): Promise<T> {
        return readJSON(storageFile()) as T;
    },
    async getItem<T extends Value = Value>(key: string): Promise<T | undefined> {
        return readJSON(storageFile())[key] as T | undefined;
    },
    async setItem(key: string, value: Value): Promise<void> {
        const items = readJSON(storageFile());
        items[key] = value;
        writeJSON(storageFile(), items);
    },
    async removeItem(key: string): Promise<void> {
        const items = readJSON(storageFile());
        delete items[key];
        writeJSON(storageFile(), items);
    },
    async clear(): Promise<void> {
        writeJSON(storageFile(), {});
    },
};

/** @deprecated Use LocalStorage.allItems. */
export const allLocalStorageItems = LocalStorage.allItems;
/** @deprecated Use LocalStorage.getItem. */
export const getLocalStorageItem = LocalStorage.getItem;
/** @deprecated Use LocalStorage.setItem. */
export const setLocalStorageItem = LocalStorage.setItem;
/** @deprecated Use LocalStorage.removeItem. */
export const removeLocalStorageItem = LocalStorage.removeItem;
/** @deprecated Use LocalStorage.clear. */
export const clearLocalStorage = LocalStorage.clear;

type Subscriber = (key: string | undefined, data: string | undefined) => void;

/** One cache folder, shared by every Cache instance that uses it in this worker. */
type Store = { file: string; entries: Map<string, string>; subscribers: Set<Subscriber>; capacity: number };
const stores = new Map<string, Store>();

function storeFor(directory: string, capacity: number): Store {
    let store = stores.get(directory);
    if (!store) {
        const file = join(directory, "cache.json");
        const entries = new Map<string, string>();
        for (const [key, value] of Object.entries(readJSON(file))) if (typeof value === "string") entries.set(key, value);
        store = { file, entries, subscribers: new Set(), capacity };
        stores.set(directory, store);
    }
    return store;
}

/**
 * A synchronous key-value cache that keeps the most recently used entries
 * within `capacity` bytes (10 MB by default).
 */
export class Cache {
    static get STORAGE_DIRECTORY_NAME(): string {
        return "cache";
    }

    static get DEFAULT_CAPACITY(): number {
        return 10 * 1024 * 1024;
    }

    readonly #directory: string;
    readonly #store: Store;

    constructor(options: { namespace?: string; capacity?: number } = {}) {
        const root = launchContext().environment.cachePath;
        if (!root) throw new Error("Cache isn't available: the app didn't say where to keep it");
        this.#directory = options.namespace ? join(root, options.namespace) : root;
        this.#store = storeFor(this.#directory, options.capacity ?? Cache.DEFAULT_CAPACITY);
    }

    get storageDirectory(): string {
        return this.#directory;
    }

    get isEmpty(): boolean {
        return this.#store.entries.size === 0;
    }

    // The methods are bound to the instance: @raycast/utils hands `cache.subscribe` to
    // useSyncExternalStore on its own, and Raycast's Cache works when called that way.

    get = (key: string): string | undefined => {
        const value = this.#store.entries.get(key);
        if (value !== undefined) {
            // Most recently used last.
            this.#store.entries.delete(key);
            this.#store.entries.set(key, value);
        }
        return value;
    };

    has = (key: string): boolean => {
        return this.#store.entries.has(key);
    };

    set = (key: string, data: string): void => {
        const { entries } = this.#store;
        entries.delete(key);
        entries.set(key, data);
        let size = 0;
        for (const [k, v] of entries) size += k.length + v.length;
        for (const [oldest, value] of entries) {
            if (size <= this.#store.capacity || oldest === key) break;
            entries.delete(oldest);
            size -= oldest.length + value.length;
        }
        this.#save();
        this.#notify(key, data);
    };

    remove = (key: string): boolean => {
        const removed = this.#store.entries.delete(key);
        if (removed) {
            this.#save();
            this.#notify(key, undefined);
        }
        return removed;
    };

    clear = (options: { notifySubscribers: boolean } = { notifySubscribers: true }): void => {
        this.#store.entries.clear();
        this.#save();
        if (options.notifySubscribers) this.#notify(undefined, undefined);
    };

    subscribe = (subscriber: Subscriber): (() => void) => {
        this.#store.subscribers.add(subscriber);
        return () => this.#store.subscribers.delete(subscriber);
    };

    #save(): void {
        writeJSON(this.#store.file, Object.fromEntries(this.#store.entries));
    }

    #notify(key: string | undefined, data: string | undefined): void {
        for (const subscriber of this.#store.subscribers) subscriber(key, data);
    }
}
