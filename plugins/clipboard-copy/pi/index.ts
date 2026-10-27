import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  rmdirSync,
  rmSync,
  unlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describeFailure, runGate, runScript } from "./gate.ts";
import type { ExtensionAPI, ExtensionContext, ToolResultEventResult } from "@earendil-works/pi-coding-agent";

const PLUGIN_ROOT = fileURLToPath(new URL("..", import.meta.url));
const SCRIPTS_DIR = path.join(PLUGIN_ROOT, "hooks", "scripts");
const SCRIPT_TIMEOUT_MS = 5000;
const SERVER_NAME = "clipboard-copy";

/**
pi's name for an MCP tool: `mcp__<server>__<tool>`, with every character outside `[A-Za-z0-9_]` as
`_`. pi shortens names over 64 characters with a hash; these stay under that.
*/
function mcpToolName(server: string, tool: string): string {
  return `mcp__${server}__${tool}`.replaceAll(/\W/g, "_");
}

const HANDOFF_TOOL_NAMES = new Set(["clipboard_copy", "clipboard_copy_file"].map((tool) => mcpToolName(SERVER_NAME, tool)));
// The server's last result line after it writes an OSC 52 sequence to a handoff file, which mktemp
// names osc52.XXXXXXXX.
const HANDOFF_MARKER_PREFIX = "OSC 52 handoff: ";
const HANDOFF_FILE_NAME = /^osc52\.[\dA-Za-z]{8}$/;
// The sequence as the server builds it, plain or wrapped in a tmux pass-through.
const OSC52_PREFIXES = ["\u{1B}]52;c;", "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;"];

type DirectiveRead = { context: string } | { problem: string };

function readAdditionalContext(stdout: string): DirectiveRead {
  if (stdout.trim() === "") {
    return { problem: "printed nothing" };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return { problem: "printed output that is not JSON" };
  }
  if (typeof parsed !== "object" || parsed === null || !("hookSpecificOutput" in parsed)) {
    return { problem: "printed JSON without hookSpecificOutput" };
  }
  const output = parsed.hookSpecificOutput;
  if (typeof output !== "object" || output === null || !("additionalContext" in output)) {
    return { problem: "printed hookSpecificOutput without additionalContext" };
  }
  const context = output.additionalContext;
  return typeof context === "string" && context !== ""
    ? { context }
    : { problem: "printed an additionalContext that is not a non-empty string" };
}

/**
pi expands `$NAME` and `${NAME}` in MCP server env values, and reads `$$` as a literal `$`.
*/
function escapeEnvironmentValue(value: string): string {
  return value.replaceAll("$", () => "$$");
}

/**
Shows a warning in pi's UI, or writes it to stderr when pi runs without one (print and JSON modes).
*/
function warn(ctx: ExtensionContext, message: string): void {
  if (ctx.hasUI) {
    ctx.ui.notify(message, "warning");
    return;
  }
  process.stderr.write(`${message}\n`);
}

/**
A tool result holding one text block, with the matching MCP `CallToolResult` as structured content.
*/
function textResult(text: string, isError: boolean): ToolResultEventResult {
  const content = [{ text, type: "text" as const }];
  return { content, isError, structuredContent: { content, isError } };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
Returns the OSC 52 sequence in `file`. Throws when the file cannot be opened without following a
link, is not a regular file owned by this user, or cannot be read.
*/
function readHandoffFile(file: string): string {
  // The name holds no path separator, so the joined path is a direct child of the handoff
  // directory. O_NOFOLLOW makes a link at that name fail instead of following it to a file
  // elsewhere, and O_NONBLOCK keeps a FIFO at that name from blocking the open until a writer
  // appears; the fstat check below then refuses it.
  const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stats = fstatSync(fd);
    const uid = typeof process.getuid === "function" ? process.getuid() : undefined;
    if (uid === undefined || !stats.isFile() || stats.uid !== uid) {
      throw new Error("it is not a regular file owned by the current user");
    }
    return readFileSync(fd, "utf8");
  } finally {
    closeSync(fd);
  }
}

/**
Removes whatever is at `file` without following a link: unlinks a non-directory and removes an
empty directory. Nothing at `file` leaves nothing to remove.
*/
function removeEntry(file: string): void {
  const stats = lstatSync(file, { throwIfNoEntry: false });
  if (stats === undefined) {
    return;
  }
  if (stats.isDirectory()) {
    rmdirSync(file);
  } else {
    unlinkSync(file);
  }
}

/**
Reads and removes the handoff file `name` in `dir`, and writes its OSC 52 sequence to pi's
terminal. Returns the result that replaces the tool's: `summary` once the sequence is written, an
error when the file is not a handoff file or pi has no interactive terminal. Throws when the file
cannot be read or removed; an entry that cannot be read is removed first, and the error also says
when that removal failed.
*/
function handBack(dir: string, name: string, summary: string, ctx: ExtensionContext): ToolResultEventResult {
  const file = path.join(dir, name);
  let sequence: string;
  try {
    sequence = readHandoffFile(file);
  } catch (error) {
    try {
      removeEntry(file);
    } catch (removalError) {
      throw new Error(`${errorMessage(error)}; removing it failed too: ${errorMessage(removalError)}`, { cause: removalError });
    }
    throw error;
  }
  unlinkSync(file);
  if (OSC52_PREFIXES.every((prefix) => !sequence.startsWith(prefix))) {
    return textResult(`clipboard-copy: nothing was copied. The OSC 52 handoff file ${name} holds no OSC 52 sequence.`, true);
  }
  if (ctx.mode !== "tui") {
    return textResult(
      `clipboard-copy: nothing was copied. The server fell back to OSC 52, which needs pi's interactive terminal, and pi runs in ${ctx.mode} mode.`,
      true,
    );
  }
  if (!process.stdout.isTTY) {
    return textResult(
      "clipboard-copy: nothing was copied. The server fell back to OSC 52, which needs pi's interactive terminal, and pi's stdout is not a terminal.",
      true,
    );
  }
  process.stdout.write(sequence);
  return textResult(summary, false);
}

/**
Creates the directory where the MCP server, which runs without a terminal, leaves OSC 52 sequences
for the tool_result handler to write to pi's. Owner-only, as the server requires.
*/
function createHandoffDirectory(): string {
  const created = mkdtempSync(path.join(tmpdir(), "clipboard-copy-pi-"));
  const handoffDirectory = realpathSync(created);
  chmodSync(handoffDirectory, 0o700);
  return handoffDirectory;
}

export default function clipboardCopy(pi: ExtensionAPI): void {
  // Created on session_start, not here: pi also loads extensions for runs that start no session and
  // never fire session_shutdown, such as `pi --help`, and the directory would outlive those.
  let handoffDirectory: string | undefined;
  let directive = "";

  pi.on("session_shutdown", () => {
    if (handoffDirectory !== undefined) {
      rmSync(handoffDirectory, { force: true, recursive: true });
    }
  });

  pi.on("session_start", async (_event, ctx) => {
    handoffDirectory = createHandoffDirectory();
    pi.registerMcpServer(SERVER_NAME, {
      command: path.join(PLUGIN_ROOT, "mcp-server-clipboard", "server.sh"),
      description: "Writes to the user's system pasteboard, locally or through the terminal over SSH.",
      env: { CLIPBOARD_COPY_HOST: "pi", CLIPBOARD_COPY_OSC52_DIR: escapeEnvironmentValue(handoffDirectory) },
      // Keeps pi's declared tool set lean; the model loads the tools through tool_search.
      exposure: "deferred",
    });

    const result = await runScript(path.join(SCRIPTS_DIR, "session-start.sh"), { cwd: ctx.cwd }, SCRIPT_TIMEOUT_MS);
    const read: DirectiveRead = result.code === 0 ? readAdditionalContext(result.stdout) : { problem: describeFailure(result) };
    if ("problem" in read) {
      directive = "";
      warn(ctx, `clipboard-copy: session-start.sh ${read.problem}; the system prompt gets no clipboard-copy directive.`);
      return;
    }
    directive = read.context;
  });

  pi.on("before_agent_start", (event) => {
    if (directive !== "") {
      event.systemPromptOptions.sections.clipboard_copy = directive;
    }
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") {
      return;
    }
    const result = await runGate(
      path.join(SCRIPTS_DIR, "check-clipboard.sh"),
      { cwd: ctx.cwd, tool_input: event.input },
      SCRIPT_TIMEOUT_MS,
    );
    if ("failure" in result) {
      warn(ctx, `clipboard-copy: check-clipboard.sh ${result.failure}; the bash command was blocked.`);
      return { block: true, reason: `clipboard-copy: the clipboard check failed (${result.failure}), so the command was blocked.` };
    }
    if (result.block) {
      return result;
    }
  });

  pi.on("tool_result", (event, ctx) => {
    if (!HANDOFF_TOOL_NAMES.has(event.toolName) || event.isError) {
      return;
    }
    const text = event.content.flatMap((block) => (block.type === "text" ? block.text : [])).join("\n");
    const cut = text.lastIndexOf("\n");
    const lastLine = text.slice(cut + 1);
    const name = lastLine.slice(HANDOFF_MARKER_PREFIX.length);
    if (!lastLine.startsWith(HANDOFF_MARKER_PREFIX) || !HANDOFF_FILE_NAME.test(name)) {
      return;
    }
    const summary = cut === -1 ? "" : text.slice(0, cut);
    // pi logs and drops a handler's exception and keeps the original result, so every failure
    // becomes an error result here instead.
    try {
      if (handoffDirectory === undefined) {
        throw new Error("the session has not started, so there is no handoff directory");
      }
      return handBack(handoffDirectory, name, summary, ctx);
    } catch (error) {
      return textResult(
        `clipboard-copy: nothing was copied. The OSC 52 handoff file ${name} could not be delivered: ${errorMessage(error)}`,
        true,
      );
    }
  });
}
