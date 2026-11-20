// Messages between the fudge app and the extension host.
//
// Both sides write one JSON object per line: the app on the host's stdin,
// the host on its stdout. Every message has a `type`; requests also carry
// an `id` that the response repeats.

export type Request = { type: "ping"; id: number };

export type Response = { type: "pong"; id: number } | { type: "error"; id?: number; message: string };

/** Parses one line from the app and returns the reply to write back. */
export function handleLine(line: string): Response {
    let message: unknown;
    try {
        message = JSON.parse(line);
    } catch {
        return { type: "error", message: "not valid JSON" };
    }
    if (!isObject(message) || typeof message.type !== "string") {
        return { type: "error", message: "a message must be an object with a string `type`" };
    }
    const id = typeof message.id === "number" ? message.id : undefined;
    switch (message.type) {
        case "ping":
            if (id === undefined) return { type: "error", message: "`ping` needs a numeric `id`" };
            return { type: "pong", id };
        default:
            return { type: "error", id, message: `unknown message type \`${message.type}\`` };
    }
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
