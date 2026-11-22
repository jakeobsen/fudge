import { greet } from "rust:../rust";

// Calls its Rust part only on Windows, as the store's extensions that also list macOS do.
export default async function Command() {
  if (process.platform === "win32") {
    console.log(await greet("Windows"));
  } else {
    console.log("works without its Rust part");
  }
}
