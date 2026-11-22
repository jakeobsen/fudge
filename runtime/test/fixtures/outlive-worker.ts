// A worker that starts a program with its output in files, as the store starts `fudge build`, and tells the test its
// pid; the test then terminates this worker (SPEC-156 A.1). `workerData`: the program, its arguments and the two files.
import { parentPort, workerData } from "node:worker_threads";
import { spawnProgram } from "../../store-extension/src/git.ts";

const { program, args, output } = workerData as { program: string; args: string[]; output: { stdout: string; stderr: string } };
void spawnProgram(program, args, { timeout: 60_000, output, started: (pid) => parentPort!.postMessage(pid) });
