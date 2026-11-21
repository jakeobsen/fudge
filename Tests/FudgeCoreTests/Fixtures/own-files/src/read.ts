import { readFile } from "node:fs/promises";
import { relative } from "node:path";

// As the store's amazon-aws Console command does: Raycast installs a command beside `assets/` and `package.json`.
export default async function Command() {
    const services = JSON.parse(await readFile(`${__dirname}/assets/services.json`, "utf8"));
    const manifest = JSON.parse(await readFile(`${__dirname}/package.json`, "utf8"));
    console.log(`${manifest.name}: ${services.services.join(", ")}; ${relative(__dirname, __filename)}`);
}
