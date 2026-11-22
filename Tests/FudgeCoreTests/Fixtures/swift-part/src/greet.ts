import { greet } from "swift:../swift";

// Calls its Swift part.
export default async function Command() {
  console.log(await greet("Mac"));
}
