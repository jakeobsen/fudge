import { greet } from "rust:../rust";

// Calls its Rust part wherever it runs.
export default async function Command() {
  console.log(await greet("Mac"));
}
