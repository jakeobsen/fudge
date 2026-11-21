import { preferences } from "@raycast/api";

// Reads none of its own files, so it runs from either layout; Raycast's deprecated `preferences` comes from the
// extension's manifest, wherever the command is.
export default async function Command() {
    console.log(`plain ran: ${preferences.greeting?.value}`);
}
