// The values of the Form being shown, for Action.SubmitForm.
//
// Form provides a registry. Each mounted field registers its value under its
// `id`: `value` when the extension controls it, else `defaultValue` (read once,
// on mount), else the field's empty value. The app reports typing through the
// field's onChange, which updates the registry. Entries belong to field
// instances rather than ids, so a field remounted under a new `key` replaces
// the old one's value instead of losing it when the old one unmounts.
// Fields with `storeValue` (never a PasswordField) are marked, and their
// values go to the app on submit, to start the form with next time.

import { createContext, useContext, useEffect, useState } from "react";

export type FormRegistry = Map<object, { id: string; value: unknown; store: boolean }>;

export const FormValuesContext = createContext<FormRegistry | null>(null);

/** Returns a function that reads the enclosing Form's current values ({} outside a Form). */
export function useFormValues(): () => Record<string, unknown> {
    const registry = useContext(FormValuesContext);
    return () => {
        const values: Record<string, unknown> = {};
        for (const { id, value } of registry?.values() ?? []) {
            if (value !== undefined) values[id] = value;
        }
        return values;
    };
}

/** Returns a function that reads the current values of the enclosing Form's fields with `storeValue`. */
export function useStoredFormValues(): () => Record<string, unknown> {
    const registry = useContext(FormValuesContext);
    return () => {
        const values: Record<string, unknown> = {};
        for (const { id, value, store } of registry?.values() ?? []) {
            if (store && value !== undefined) values[id] = value;
        }
        return values;
    };
}

/** Registers a field with the enclosing Form; returns the function that records a new value. */
export function useFormField(
    id: unknown,
    value: unknown,
    defaultValue: unknown,
    empty: unknown,
    store = false,
): (next: unknown) => void {
    const registry = useContext(FormValuesContext);
    const [token] = useState(() => ({}));
    const [initial] = useState(() => (value !== undefined ? value : defaultValue !== undefined ? defaultValue : empty));
    if (registry && typeof id === "string") {
        const entry = registry.get(token);
        if (!entry || entry.id !== id) registry.set(token, { id, value: entry ? entry.value : initial, store });
        registry.get(token)!.store = store;
        if (value !== undefined) registry.get(token)!.value = value;
    }
    useEffect(() => () => void registry?.delete(token), [registry, token]);
    return (next) => {
        const entry = registry?.get(token);
        if (entry) entry.value = next;
    };
}
