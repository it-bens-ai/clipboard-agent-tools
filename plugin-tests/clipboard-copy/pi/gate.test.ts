import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { describeFailure, runGate, runScript } from "../../../plugins/clipboard-copy/pi/gate.ts";
import { makeTemporaryDirectory } from "./temporary-directory.ts";

function writeScript(dir: string, body: string): string {
  const script = join(dir, "script.sh");
  writeFileSync(script, body);
  return script;
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") {
      return false;
    }
    throw error;
  }
}

/**
A kill function that throws an error with `code` instead of signalling, and kills the real process
group after the test so the script it failed to stop does not outlive it.
*/
function failingKill(t: TestContext, code: string): (pid: number) => void {
  const groups: number[] = [];
  t.after(() => {
    for (const group of groups) {
      try {
        process.kill(group, "SIGKILL");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ESRCH") {
          throw error;
        }
      }
    }
  });
  return (pid) => {
    groups.push(pid);
    throw Object.assign(new Error(`kill ${code}`), { code });
  };
}

test("runScript returns the script's stdout and exit code 0 unchanged", async (t) => {
  const script = writeScript(makeTemporaryDirectory(t), "printf '  {\"ok\": true}\\n'\nexit 0\n");

  const result = await runScript(script, {}, 5000);

  assert.deepEqual(result, { code: 0, stderr: "", stdout: '  {"ok": true}\n' });
});

test("the script reads its input as JSON on stdin", async (t) => {
  const script = writeScript(makeTemporaryDirectory(t), "cat\n");

  const { stdout } = await runScript(script, { tool_input: { command: "echo x | pbcopy" } }, 5000);

  assert.equal(stdout, '{"tool_input":{"command":"echo x | pbcopy"}}');
});

test("the script runs with CLIPBOARD_COPY_HOST=pi", async (t) => {
  const script = writeScript(makeTemporaryDirectory(t), 'printf "host=%s" "${CLIPBOARD_COPY_HOST-unset}"\n');

  const { stdout } = await runScript(script, {}, 5000);

  assert.equal(stdout, "host=pi");
});

test("a gate that exits 0 allows without a failure", async (t) => {
  const script = writeScript(makeTemporaryDirectory(t), "exit 0\n");

  const result = await runGate(script, { tool_input: { command: "ls" } }, 5000);

  assert.deepEqual(result, { block: false });
});

test("a gate that exits 2 blocks with its trimmed stderr as the reason", async (t) => {
  const script = writeScript(
    makeTemporaryDirectory(t),
    "printf '\\n  Use the mcp__clipboard_copy__clipboard_copy MCP tool instead.  \\n' >&2\nexit 2\n",
  );

  const result = await runGate(script, { tool_input: { command: "echo x | pbcopy" } }, 5000);

  assert.deepEqual(result, { block: true, reason: "Use the mcp__clipboard_copy__clipboard_copy MCP tool instead." });
});

test("a gate that exits 2 with only whitespace on stderr blocks with a reason saying the check gave none", async (t) => {
  // Fail vector: an empty reason reaches pi as a block with nothing to tell the model.
  const script = writeScript(makeTemporaryDirectory(t), "printf '  \\n' >&2\nexit 2\n");

  const result = await runGate(script, { tool_input: { command: "echo x | pbcopy" } }, 5000);

  assert.deepEqual(result, { block: true, reason: "clipboard-copy: the clipboard check blocked the command without a reason." });
});

test("a gate that exits with another status blocks with a failure naming the status and its stderr", async (t) => {
  const script = writeScript(makeTemporaryDirectory(t), "printf '  jq: not found  \\n' >&2\nexit 1\n");

  const result = await runGate(script, {}, 5000);

  assert.deepEqual(result, { block: true, failure: "exited with status 1: jq: not found" });
});

test("a gate that exits with another status and no stderr blocks with a failure naming the status alone", async (t) => {
  const script = writeScript(makeTemporaryDirectory(t), "exit 3\n");

  const result = await runGate(script, {}, 5000);

  assert.deepEqual(result, { block: true, failure: "exited with status 3" });
});

test("a nonexistent gate script blocks with a failure naming bash's error", async (t) => {
  const script = join(makeTemporaryDirectory(t), "missing.sh");

  const result = await runGate(script, {}, 5000);

  assert.deepEqual(result, { block: true, failure: `exited with status 127: bash: ${script}: No such file or directory` });
});

test("a gate that exits 2 without reading its 1 MB input still blocks and raises no unhandled error", async (t) => {
  const unhandled: unknown[] = [];
  const record = (error: unknown): void => {
    unhandled.push(error);
  };
  process.on("uncaughtException", record);
  process.on("unhandledRejection", record);
  t.after(() => {
    process.off("uncaughtException", record);
    process.off("unhandledRejection", record);
  });
  const script = writeScript(makeTemporaryDirectory(t), "exec 0<&-\nprintf 'Use clipboard_copy.' >&2\nexit 2\n");

  const result = await runGate(script, { payload: "x".repeat(1024 * 1024) }, 5000);
  // A late EPIPE would surface after settling; give it a few event-loop turns to arrive.
  await delay(100);

  assert.deepEqual(result, { block: true, reason: "Use clipboard_copy." });
  assert.deepEqual(unhandled, []);
});

test("a gate that outlives its timeout blocks with a failure, and its background children are killed", { timeout: 10_000 }, async (t) => {
  const dir = makeTemporaryDirectory(t);
  const pidFile = join(dir, "sleep.pid");
  const script = writeScript(dir, `sleep 37 &\nprintf '%s' "$!" > '${pidFile}'\nwait\n`);

  const result = await runGate(script, {}, 500);

  assert.deepEqual(result, {
    block: true,
    failure: "did not finish: it timed out, could not start, or was killed by a signal",
  });
  const sleepPid = Number(readFileSync(pidFile, "utf8"));
  // SIGKILL delivery and reaping of the orphaned sleep are asynchronous; poll briefly.
  for (let attempt = 0; attempt < 40 && isProcessAlive(sleepPid); attempt++) {
    await delay(50);
  }
  assert.equal(isProcessAlive(sleepPid), false);
});

test("a timed-out script whose process group is already gone reports no kill failure", { timeout: 10_000 }, async (t) => {
  // Fail vector: a kill that reports every error turns a group that exited on its own into a failure.
  const script = writeScript(makeTemporaryDirectory(t), "exec sleep 37\n");

  const result = await runScript(script, {}, 200, failingKill(t, "ESRCH"));

  assert.deepEqual(result, { code: null, stderr: "", stdout: "" });
});

test("a timed-out script whose process group cannot be killed reports why the kill failed", { timeout: 10_000 }, async (t) => {
  // Fail vector: a catch that ignores every kill error leaves a still-running script unreported.
  const script = writeScript(makeTemporaryDirectory(t), "exec sleep 37\n");

  const result = await runScript(script, {}, 200, failingKill(t, "EPERM"));

  assert.deepEqual(result, { code: null, killFailure: "kill EPERM", stderr: "", stdout: "" });
});

test("a failure description names a failed kill after the timeout", () => {
  const description = describeFailure({ code: null, killFailure: "kill EPERM", stderr: "", stdout: "" });

  assert.equal(
    description,
    "did not finish: it timed out, could not start, or was killed by a signal; killing its process group failed: kill EPERM",
  );
});
