import { spawn } from "node:child_process";

export interface ScriptResult {
  code: number | null;
  /**
   * Why the script's process group could not be killed after the timeout, when that failed.
   */
  killFailure?: string;
  stderr: string;
  stdout: string;
}

/**
 * Sends `signal` to `pid`, as `process.kill` does: a negative `pid` names a process group.
 */
type Kill = (pid: number, signal: NodeJS.Signals) => void;

const EMPTY_BLOCK_REASON = "clipboard-copy: the clipboard check blocked the command without a reason.";

/**
 * A gate script that neither allowed (exit 0) nor blocked (exit 2) the call still blocks it, with a
 * `failure` that says what went wrong in place of the script's `reason`.
 */
export type GateResult = { block: false } | { block: true; failure: string } | { block: true; reason: string };

/**
 * Runs `bash <script>` with `input` as JSON on stdin and `CLIPBOARD_COPY_HOST=pi` in its environment.
 * Never rejects: a failed spawn or the timeout resolves `{ code: null, stdout: "", stderr: "" }`. A
 * script that exits without reading all of its input still reports its own exit code. On timeout the
 * script's whole process group is killed with `kill`; a kill that fails for any reason other than
 * the group being gone already adds `killFailure`.
 */
export function runScript(
  script: string,
  input: unknown,
  timeoutMs: number,
  kill: Kill = (pid, signal) => {
    process.kill(pid, signal);
  },
): Promise<ScriptResult> {
  return new Promise((resolve) => {
    const env: NodeJS.ProcessEnv = { ...process.env, CLIPBOARD_COPY_HOST: "pi" };
    // Own process group, so the timeout can kill grandchildren that hold the stdio pipes open
    // and would otherwise keep `close` from firing. `bash` comes from PATH, as it does for the hooks
    // on Claude Code and Codex.
    // eslint-disable-next-line sonarjs/no-os-command-from-path
    const child = spawn("bash", [script], { detached: true, env });
    let stdout = "";
    let stderr = "";
    let isSettled = false;

    const settle = (result: ScriptResult): void => {
      if (isSettled) {
        return;
      }
      isSettled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const fail = (): void => {
      settle({ code: null, stderr: "", stdout: "" });
    };

    const timer = setTimeout(() => {
      try {
        // A failed spawn leaves `pid` undefined, but its `error` settles and clears this timer first.
        if (child.pid !== undefined) {
          kill(-child.pid, "SIGKILL");
        }
      } catch (error) {
        if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) {
          settle({ code: null, killFailure: error instanceof Error ? error.message : String(error), stderr: "", stdout: "" });
          return;
        }
      }
      fail();
    }, timeoutMs);

    child.on("error", fail);
    child.stdin.on("error", () => {
      // EPIPE: the script exited without reading all of its input. Its exit code, which `close`
      // reports, still decides the outcome.
    });
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("close", (code) => {
      settle({ code, stderr, stdout });
    });
    child.stdin.end(JSON.stringify(input));
  });
}

/**
 * Describes how a script run that did not succeed ended, with its trimmed stderr when it has any.
 */
export function describeFailure({ code, killFailure, stderr }: ScriptResult): string {
  if (code === null) {
    const unfinished = "did not finish: it timed out, could not start, or was killed by a signal";
    return killFailure === undefined ? unfinished : `${unfinished}; killing its process group failed: ${killFailure}`;
  }
  const detail = stderr.trim();
  return detail === "" ? `exited with status ${String(code)}` : `exited with status ${String(code)}: ${detail}`;
}

/**
 * Runs a hook gate script. Exit code 0 allows, and exit code 2 blocks with the trimmed stderr as the
 * reason, or with a reason saying the check gave none when that is empty. Any other outcome,
 * including a timeout or a failed spawn, blocks with a `failure`. Never rejects.
 */
export async function runGate(script: string, input: unknown, timeoutMs: number): Promise<GateResult> {
  const result = await runScript(script, input, timeoutMs);
  if (result.code === 2) {
    const reason = result.stderr.trim();
    return { block: true, reason: reason === "" ? EMPTY_BLOCK_REASON : reason };
  }
  return result.code === 0 ? { block: false } : { block: true, failure: describeFailure(result) };
}
