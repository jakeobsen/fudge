// The values of the Form being shown, for Action.SubmitForm. Form fields
// register here as their values change.

import { createContext, useContext, useRef } from "react";

export type FormValues = { current: Record<string, unknown> };

export const FormValuesContext = createContext<FormValues | null>(null);

/** Returns a function that reads the enclosing Form's current values ({} outside a Form). */
export function useFormValues(): () => Record<string, unknown> {
    const values = useContext(FormValuesContext);
    const fallback = useRef<Record<string, unknown>>({});
    return () => ({ ...(values ?? { current: fallback.current }).current });
}
