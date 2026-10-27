import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import {
  constants,
  cpSync,
  existsSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import clipboardCopy from "../../../plugins/clipboard-copy/pi/index.ts";
import { type FakeMcpServerConfig, type FakePi, type Handler, registerOnFakePi } from "./fake-pi.ts";
import { piMcpToolName, piResolveEnvironmentValue, piValidateMcpServerConfig } from "./pi-internals.ts";
import { makeTemporaryDirectory } from "./temporary-directory.ts";

const PLUGIN_DIR = fileURLToPath(new URL("../../../plugins/clipboard-copy", import.meta.url));
const SESSION_START_EVENT = { reason: "startup", type: "session_start" };
const SESSION_SHUTDOWN_EVENT = { reason: "quit", type: "session_shutdown" };
const SERVER_NAME = "clipboard-copy";
const DESCRIPTION = "Writes to the user's system pasteboard, locally or through the terminal over SSH.";
const OSC52_SEQUENCE = "\u{1B}]52;c;aGVsbG8=\u{07}";
const TMUX_OSC52_SEQUENCE = "\u{1B}Ptmux;\u{1B}\u{1B}]52;c;aGVsbG8=\u{07}\u{1B}\\";
const HANDOFF_NAME = "osc52.AbCd1234";
const SUMMARY = "Copied 5 bytes to clipboard via osc52";

/**
The tool names the MCP server declares in its tools.json.
*/
function serverToolNames(): string[] {
  const file = path.join(PLUGIN_DIR, "mcp-server-clipboard", "tools.json");
  const catalog = JSON.parse(readFileSync(file, "utf8")) as { tools?: unknown };
  if (!Array.isArray(catalog.tools) || catalog.tools.length === 0) {
    throw new Error(`${file} has no tools`);
  }
  return catalog.tools.map((tool: unknown, index) => {
    const name = (tool as { name?: unknown }).name;
    if (typeof name !== "string" || name === "") {
      throw new TypeError(`${file} tool at index ${String(index)} has no non-empty string "name"`);
    }
    return name;
  });
}

interface Notification {
  level: string;
  message: string;
}

interface FakeContext {
  ctx: { cwd: string; hasUI: boolean; mode: string; ui: { notify: (message: string, level: string) => void } };
  notifications: Notification[];
}

function makeContext(cwd: string, mode: string, hasUI: boolean): FakeContext {
  const notifications: Notification[] = [];
  return {
    ctx: {
      cwd,
      hasUI,
      mode,
      ui: {
        notify: (message, level) => {
          notifications.push({ level, message });
        },
      },
    },
    notifications,
  };
}

function handler(fake: FakePi, name: string): Handler {
  const found = fake.handlers.get(name);
  if (found === undefined) {
    throw new Error(`the extension registered no ${name} handler`);
  }
  return found;
}

function registeredServer(fake: FakePi): FakeMcpServerConfig {
  const server = fake.servers.get(SERVER_NAME);
  if (server === undefined) {
    throw new Error(`the extension registered no "${SERVER_NAME}" server`);
  }
  return server;
}

/**
Registers the extension on a fake pi and ends its session after the test, which removes the
handoff directory a session start created.
*/
function register(t: TestContext, extension: typeof clipboardCopy = clipboardCopy): FakePi {
  const fake = registerOnFakePi(extension);
  t.after(async () => {
    await handler(fake, "session_shutdown")(SESSION_SHUTDOWN_EVENT, {});
  });
  return fake;
}

/**
Registers the extension and starts its session, which creates the handoff directory and registers
the server.
*/
async function registerStarted(t: TestContext): Promise<FakePi> {
  const fake = register(t);
  const { ctx } = makeContext(makeTemporaryDirectory(t), "tui", true);
  await handler(fake, "session_start")(SESSION_START_EVENT, ctx);
  return fake;
}

/**
Runs `act` with TMPDIR, which os.tmpdir() reads on every call, set to `dir`, and restores it.
*/
async function withTmpdir<T>(dir: string, act: () => Promise<T>): Promise<T> {
  // eslint-disable-next-line sonarjs/publicly-writable-directories -- reads the variable to restore it
  const originalTmpdir = process.env.TMPDIR;
  // eslint-disable-next-line sonarjs/publicly-writable-directories -- points it at the test's own directory
  process.env.TMPDIR = dir;
  try {
    return await act();
  } finally {
    if (originalTmpdir === undefined) {
      // eslint-disable-next-line sonarjs/publicly-writable-directories -- restores the unset variable
      delete process.env.TMPDIR;
    } else {
      // eslint-disable-next-line sonarjs/publicly-writable-directories -- restores the original value
      process.env.TMPDIR = originalTmpdir;
    }
  }
}

/**
The handoff directory as the MCP server receives it: the registered env value resolved by pi.
*/
async function handoffDirectory(fake: FakePi): Promise<string> {
  const server = registeredServer(fake);
  if (!("env" in server) || server.env?.CLIPBOARD_COPY_OSC52_DIR === undefined) {
    throw new Error("the server was registered without CLIPBOARD_COPY_OSC52_DIR");
  }
  const resolved = await piResolveEnvironmentValue(server.env.CLIPBOARD_COPY_OSC52_DIR);
  if (resolved === undefined) {
    throw new Error(`pi resolves CLIPBOARD_COPY_OSC52_DIR "${server.env.CLIPBOARD_COPY_OSC52_DIR}" to nothing`);
  }
  return resolved;
}

/**
Loads a copy of the extension whose hook scripts named in `scripts` are replaced by the given
bodies, and registers it.
*/
async function registerCopy(t: TestContext, scripts: Record<string, string>): Promise<FakePi> {
  const dir = makeTemporaryDirectory(t);
  for (const part of ["pi", "hooks"]) {
    cpSync(path.join(PLUGIN_DIR, part), path.join(dir, "plugin", part), { recursive: true });
  }
  for (const [name, body] of Object.entries(scripts)) {
    writeFileSync(path.join(dir, "plugin", "hooks", "scripts", name), body);
  }
  const indexUrl = pathToFileURL(path.join(dir, "plugin", "pi", "index.ts")).href;
  const { default: extension } = (await import(indexUrl)) as { default: typeof clipboardCopy };
  return register(t, extension);
}

/**
Starts a session and returns the system prompt sections the next agent start receives.
*/
async function sectionsAfterSessionStart(fake: FakePi, ctx: FakeContext["ctx"]): Promise<Record<string, string>> {
  await handler(fake, "session_start")(SESSION_START_EVENT, ctx);
  const sections: Record<string, string> = {};
  await handler(fake, "before_agent_start")({ systemPromptOptions: { sections }, type: "before_agent_start" }, ctx);
  return sections;
}

function toolResultEvent(toolName: string, text: string, isError = false): Record<string, unknown> {
  return { content: [{ text, type: "text" }], input: {}, isError, toolCallId: "call-1", toolName, type: "tool_result" };
}

function errorResult(text: string): Record<string, unknown> {
  const content = [{ text, type: "text" }];
  return { content, isError: true, structuredContent: { content, isError: true } };
}

/**
Opens `file` the way the extension does, without following a link, expects it to fail with
`code`, and returns Node's message. Node names the failing system call differently per platform,
so a test expects Node's own message instead of a literal.
*/
function openFailureMessage(file: string, code: string): string {
  return failureMessage(() => openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK), code);
}

/**
Runs `act`, expects it to throw an error with `code`, and returns the error's message.
*/
function failureMessage(act: () => unknown, code: string): string {
  let message = "";
  assert.throws(act, (error: NodeJS.ErrnoException) => {
    message = error.message;
    return error.code === code;
  });
  return message;
}


/**
Runs the MCP server library's OSC 52 writer and handoff note on `text`, as server.sh does for a
call that falls back to OSC 52 with CLIPBOARD_COPY_OSC52_DIR set to `dir`, and returns the note
line it prints. `tmux` is the TMUX value the server sees, or undefined to leave TMUX unset.
*/
function serverHandoffLine(t: TestContext, dir: string, text: string, tmux: string | undefined): string {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    CLIPBOARD_COPY_HOST: "pi",
    CLIPBOARD_COPY_OSC52_DIR: dir,
    MCP_CALL_TMPDIR: makeTemporaryDirectory(t),
  };
  delete env.TMUX;
  if (tmux !== undefined) {
    env.TMUX = tmux;
  }
  const library = path.join(PLUGIN_DIR, "mcp-server-clipboard", "lib", "clipboard.sh");
  const bytes = String(Buffer.byteLength(text));
  // `bash` comes from PATH, as it does for the server on every host.
  // eslint-disable-next-line sonarjs/no-os-command-from-path
  const stdout = execFileSync("bash", ["-c", 'source "$1" && _clipboard_write_backend osc52 "$2" && _clipboard_handoff_note', "bash", library, bytes], {
    encoding: "utf8",
    env,
    input: text,
  });
  assert.match(stdout, /^OSC 52 handoff: osc52\.[\dA-Za-z]{8}\n$/);
  return stdout.slice(0, -1);
}

/**
Runs the tool_result handler with stdout's `isTTY` set to `isTty`, and returns its result with
everything it wrote to stdout. Both stdout changes are undone before this returns, so the test
runner's own output is not captured.
*/
function runToolResult(
  t: TestContext,
  fake: FakePi,
  event: Record<string, unknown>,
  ctx: FakeContext["ctx"],
  isTty: boolean,
): { result: unknown; written: string[] } {
  const written: string[] = [];
  const original = Object.getOwnPropertyDescriptor(process.stdout, "isTTY");
  Object.defineProperty(process.stdout, "isTTY", { configurable: true, value: isTty, writable: true });
  // eslint-disable-next-line unicorn/consistent-boolean-name -- a mock of stdout.write, not a boolean
  const stdoutWrite = t.mock.method(process.stdout, "write", (chunk: unknown) => {
    written.push(String(chunk));
    return true;
  });
  try {
    return { result: handler(fake, "tool_result")(event, ctx), written };
  } finally {
    stdoutWrite.mock.restore();
    if (original === undefined) {
      Reflect.deleteProperty(process.stdout, "isTTY");
    } else {
      Object.defineProperty(process.stdout, "isTTY", original);
    }
  }
}

// --- registration

test("loading the extension creates no handoff directory and registers no server", async (t) => {
  // Fail vector: pi loads extensions for runs that never start a session, such as `pi --help`, and a
  // directory created at load time is never removed.
  const parent = realpathSync(makeTemporaryDirectory(t));

  const fake = await withTmpdir(parent, () => Promise.resolve(register(t)));

  assert.deepEqual(readdirSync(parent), []);
  assert.equal(fake.servers.size, 0);
});

test("on session start the server is registered with the bundled server script, the pi host, deferred exposure, and its description", async (t) => {
  const fake = await registerStarted(t);

  const server = registeredServer(fake);

  assert.deepEqual(server, {
    command: path.join(PLUGIN_DIR, "mcp-server-clipboard", "server.sh"),
    description: DESCRIPTION,
    env: { CLIPBOARD_COPY_HOST: "pi", CLIPBOARD_COPY_OSC52_DIR: await handoffDirectory(fake) },
    exposure: "deferred",
  });
});

test("pi accepts the server registration", async (t) => {
  const server = registeredServer(await registerStarted(t));

  const validated = await piValidateMcpServerConfig(SERVER_NAME, server);

  assert.notEqual(typeof validated, "string", String(validated));
});

test("the handoff directory is a new owner-only directory under the system temp directory, even under a umask that clears owner bits", async (t) => {
  // Fail vector: mkdtemp creates 0700 minus the umask, so without the chmod umask 0200 leaves 0500.
  const fake = register(t);
  const { ctx } = makeContext(makeTemporaryDirectory(t), "tui", true);
  const originalUmask = process.umask(0o200);
  try {
    await handler(fake, "session_start")(SESSION_START_EVENT, ctx);
  } finally {
    process.umask(originalUmask);
  }

  const dir = await handoffDirectory(fake);

  assert.equal(path.dirname(dir), realpathSync(tmpdir()));
  assert.match(path.basename(dir), /^clipboard-copy-pi-[\dA-Za-z]{6}$/);
  assert.equal(statSync(dir).mode & 0o777, 0o700);
});

test("pi resolves the handoff directory unchanged when its path holds a dollar sign", async (t) => {
  // Fail vector: an unescaped "$HOME" in the env value is expanded by pi to the home directory.
  const parent = realpathSync(makeTemporaryDirectory(t));
  const dollarParent = path.join(parent, "tmp-$HOME");
  mkdirSync(dollarParent);

  const fake = await withTmpdir(dollarParent, () => registerStarted(t));

  const dir = await handoffDirectory(fake);
  assert.equal(path.dirname(dir), dollarParent);
  assert.equal(statSync(dir).isDirectory(), true);
});

test("ending the session removes the handoff directory and its files", async (t) => {
  const fake = registerOnFakePi(clipboardCopy);
  const { ctx } = makeContext(makeTemporaryDirectory(t), "tui", true);
  await handler(fake, "session_start")(SESSION_START_EVENT, ctx);
  const dir = await handoffDirectory(fake);
  writeFileSync(path.join(dir, HANDOFF_NAME), OSC52_SEQUENCE);
  t.after(() => {
    rmSync(dir, { force: true, recursive: true });
  });

  await handler(fake, "session_shutdown")(SESSION_SHUTDOWN_EVENT, {});

  assert.equal(existsSync(dir), false);
});

// --- session-start directive

test("the session-start directive with the pi addendum becomes the clipboard_copy system prompt section", async (t) => {
  const { ctx, notifications } = makeContext(makeTemporaryDirectory(t), "tui", true);
  const expected = `${readFileSync(path.join(PLUGIN_DIR, "hooks", "prompts", "mcp-tool-directives.md"), "utf8")}\n${readFileSync(
    path.join(PLUGIN_DIR, "hooks", "prompts", "host-pi.md"),
    "utf8",
  )}`;

  const sections = await sectionsAfterSessionStart(register(t), ctx);

  assert.deepEqual(sections, { clipboard_copy: expected });
  assert.deepEqual(notifications, []);
});

for (const { body, problem } of [
  { body: "exit 0\n", problem: "printed nothing" },
  { body: "printf '%s' 'Use the clipboard tools.'\n", problem: "printed output that is not JSON" },
  { body: `printf '%s' '{"additionalContext":"Use the clipboard tools."}'\n`, problem: "printed JSON without hookSpecificOutput" },
  {
    body: `printf '%s' '{"hookSpecificOutput":{"context":"Use the clipboard tools."}}'\n`,
    problem: "printed hookSpecificOutput without additionalContext",
  },
  {
    body: `printf '%s' '{"hookSpecificOutput":{"additionalContext":["Use the clipboard tools."]}}'\n`,
    problem: "printed an additionalContext that is not a non-empty string",
  },
  {
    body: `printf '%s' '{"hookSpecificOutput":{"additionalContext":"Use the clipboard tools."}}'\nprintf 'jq: not found\\n' >&2\nexit 1\n`,
    problem: "exited with status 1: jq: not found",
  },
]) {
  test(`no clipboard_copy section is added, and pi shows a warning, when session-start.sh ${problem}`, async (t) => {
    const fake = await registerCopy(t, { "session-start.sh": body });
    const { ctx, notifications } = makeContext(makeTemporaryDirectory(t), "tui", true);

    const sections = await sectionsAfterSessionStart(fake, ctx);

    assert.deepEqual(sections, {});
    assert.deepEqual(notifications, [
      {
        level: "warning",
        message: `clipboard-copy: session-start.sh ${problem}; the system prompt gets no clipboard-copy directive.`,
      },
    ]);
  });
}

test("a session-start failure goes to stderr when pi has no UI", async (t) => {
  const fake = await registerCopy(t, { "session-start.sh": "exit 1\n" });
  const { ctx, notifications } = makeContext(makeTemporaryDirectory(t), "print", false);
  const written: string[] = [];
  // eslint-disable-next-line unicorn/consistent-boolean-name -- a mock of stderr.write, not a boolean
  const stderrWrite = t.mock.method(process.stderr, "write", (chunk: unknown) => {
    written.push(String(chunk));
    return true;
  });

  let sections: Record<string, string>;
  try {
    sections = await sectionsAfterSessionStart(fake, ctx);
  } finally {
    stderrWrite.mock.restore();
  }

  assert.deepEqual(sections, {});
  assert.deepEqual(written, [
    "clipboard-copy: session-start.sh exited with status 1; the system prompt gets no clipboard-copy directive.\n",
  ]);
  assert.deepEqual(notifications, []);
});

// --- bash gate

test("a bash command piping into pbcopy is blocked with a reason naming pi's clipboard tools", async (t) => {
  const { ctx } = makeContext(makeTemporaryDirectory(t), "tui", true);
  const copyTool = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const copyFileTool = await piMcpToolName(SERVER_NAME, "clipboard_copy_file");

  const result = await handler(register(t), "tool_call")({ input: { command: "echo x | pbcopy" }, toolName: "bash" }, ctx);

  assert.deepEqual(result, {
    block: true,
    reason: [
      `Use the ${copyTool} MCP tool instead.`,
      "",
      "Bad command detected: echo x | pbcopy",
      "",
      `Use ${copyTool} with the text directly, or ${copyFileTool} with an absolute path when the content is already on disk.`,
      "",
      "The clipboard-copy MCP tool:",
      "  - Auto-detects the right backend per OS (pbcopy / wl-copy / xclip / xsel / clip.exe / clip)",
      "  - Falls back to OSC 52 over SSH and in headless environments",
    ].join("\n"),
  });
});

for (const { command, kind } of [
  { command: "ls -la", kind: "without a clipboard utility" },
  { command: "xclip -o -selection clipboard", kind: "reading the clipboard with xclip -o" },
]) {
  test(`a bash command ${kind} runs unblocked`, async (t) => {
    const { ctx, notifications } = makeContext(makeTemporaryDirectory(t), "tui", true);

    const result = await handler(register(t), "tool_call")({ input: { command }, toolName: "bash" }, ctx);

    assert.equal(result, undefined);
    assert.deepEqual(notifications, []);
  });
}

test("a powershell command is not checked", async (t) => {
  const { ctx } = makeContext(makeTemporaryDirectory(t), "tui", true);

  const result = await handler(register(t), "tool_call")({ input: { command: "echo x | pbcopy" }, toolName: "powershell" }, ctx);

  assert.equal(result, undefined);
});

test("a failing clipboard check blocks the bash command and shows a warning", async (t) => {
  const fake = await registerCopy(t, { "check-clipboard.sh": "printf 'jq: not found\\n' >&2\nexit 1\n" });
  const { ctx, notifications } = makeContext(makeTemporaryDirectory(t), "tui", true);

  const result = await handler(fake, "tool_call")({ input: { command: "ls -la" }, toolName: "bash" }, ctx);

  assert.deepEqual(result, {
    block: true,
    reason: "clipboard-copy: the clipboard check failed (exited with status 1: jq: not found), so the command was blocked.",
  });
  assert.deepEqual(notifications, [
    {
      level: "warning",
      message: "clipboard-copy: check-clipboard.sh exited with status 1: jq: not found; the bash command was blocked.",
    },
  ]);
});

// --- OSC 52 handback

for (const { label, sequence, tmux } of [
  { label: "a plain", sequence: OSC52_SEQUENCE, tmux: undefined },
  { label: "a tmux-wrapped", sequence: TMUX_OSC52_SEQUENCE, tmux: "tmux-socket,4242,0" },
]) {
  test(`${label} OSC 52 handoff from the server is written to pi's terminal and the result keeps only the summary`, async (t) => {
    // Fail vector: the server and the extension each spell the OSC 52 prefixes; a drift on either
    // side turns the handoff into a "holds no OSC 52 sequence" error.
    const fake = await registerStarted(t);
    const dir = await handoffDirectory(fake);
    const handoffLine = serverHandoffLine(t, dir, "hello", tmux);
    const handoffFile = path.join(dir, handoffLine.slice("OSC 52 handoff: ".length));
    const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
    const { ctx } = makeContext(dir, "tui", true);

    const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\n${handoffLine}`), ctx, true);

    const content = [{ text: SUMMARY, type: "text" }];
    assert.deepEqual(result, { content, isError: false, structuredContent: { content, isError: false } });
    assert.deepEqual(written, [sequence]);
    assert.equal(existsSync(handoffFile), false);
  });
}

for (const tool of serverToolNames()) {
  test(`a handoff from the server's ${tool} tool, under the name pi gives it, is written to pi's terminal`, async (t) => {
    // Fail vector: the extension spells pi's MCP tool names itself; a drift from pi's own naming, or a
    // server tool the extension does not list, leaves that tool's handoff file unwritten.
    const fake = await registerStarted(t);
    const dir = await handoffDirectory(fake);
    writeFileSync(path.join(dir, HANDOFF_NAME), OSC52_SEQUENCE);
    const [serverName] = fake.servers.keys();
    if (serverName === undefined) {
      throw new Error("the extension registered no server");
    }
    const toolName = await piMcpToolName(serverName, tool);
    const { ctx } = makeContext(dir, "tui", true);

    const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, true);

    const content = [{ text: SUMMARY, type: "text" }];
    assert.deepEqual(result, { content, isError: false, structuredContent: { content, isError: false } });
    assert.deepEqual(written, [OSC52_SEQUENCE]);
  });
}

for (const mode of ["print", "json", "rpc"]) {
  test(`a handoff in pi's ${mode} mode is an error, writes nothing, and deletes the handoff file`, async (t) => {
    const fake = await registerStarted(t);
    const dir = await handoffDirectory(fake);
    writeFileSync(path.join(dir, HANDOFF_NAME), OSC52_SEQUENCE);
    const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
    const { ctx } = makeContext(dir, mode, mode === "rpc");

    const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, true);

    assert.deepEqual(
      result,
      errorResult(
        `clipboard-copy: nothing was copied. The server fell back to OSC 52, which needs pi's interactive terminal, and pi runs in ${mode} mode.`,
      ),
    );
    assert.deepEqual(written, []);
    assert.equal(existsSync(path.join(dir, HANDOFF_NAME)), false);
  });
}

test("a handoff in pi's interactive mode without a terminal on stdout is an error and writes nothing", async (t) => {
  const fake = await registerStarted(t);
  const dir = await handoffDirectory(fake);
  writeFileSync(path.join(dir, HANDOFF_NAME), OSC52_SEQUENCE);
  const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const { ctx } = makeContext(dir, "tui", true);

  const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, false);

  assert.deepEqual(
    result,
    errorResult(
      "clipboard-copy: nothing was copied. The server fell back to OSC 52, which needs pi's interactive terminal, and pi's stdout is not a terminal.",
    ),
  );
  assert.deepEqual(written, []);
  assert.equal(existsSync(path.join(dir, HANDOFF_NAME)), false);
});

test("a handoff file without an OSC 52 sequence is an error, is not written, and is deleted", async (t) => {
  const fake = await registerStarted(t);
  const dir = await handoffDirectory(fake);
  writeFileSync(path.join(dir, HANDOFF_NAME), "\u{1B}]0;window title\u{07}");
  const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const { ctx } = makeContext(dir, "tui", true);

  const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, true);

  assert.deepEqual(
    result,
    errorResult(`clipboard-copy: nothing was copied. The OSC 52 handoff file ${HANDOFF_NAME} holds no OSC 52 sequence.`),
  );
  assert.deepEqual(written, []);
  assert.equal(existsSync(path.join(dir, HANDOFF_NAME)), false);
});

for (const { label, targetDirectory } of [
  { label: "outside the handoff directory", targetDirectory: (t: TestContext): string => realpathSync(makeTemporaryDirectory(t)) },
  { label: "to a file in the handoff directory", targetDirectory: (_t: TestContext, dir: string): string => dir },
]) {
  test(`a handoff file that links ${label} is an error, and the link is removed while its target is neither read nor changed`, async (t) => {
    const fake = await registerStarted(t);
    const dir = await handoffDirectory(fake);
    const target = path.join(targetDirectory(t, dir), "sequence");
    writeFileSync(target, OSC52_SEQUENCE);
    symlinkSync(target, path.join(dir, HANDOFF_NAME));
    const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
    const { ctx } = makeContext(dir, "tui", true);
    const reason = openFailureMessage(path.join(dir, HANDOFF_NAME), "ELOOP");

    const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, true);

    assert.deepEqual(
      result,
      errorResult(`clipboard-copy: nothing was copied. The OSC 52 handoff file ${HANDOFF_NAME} could not be delivered: ${reason}`),
    );
    assert.deepEqual(written, []);
    assert.equal(readdirSync(dir).includes(HANDOFF_NAME), false);
    assert.equal(readFileSync(target, "utf8"), OSC52_SEQUENCE);
  });
}

test("a handoff name holding an empty directory is an error, and the directory is removed", async (t) => {
  const fake = await registerStarted(t);
  const dir = await handoffDirectory(fake);
  mkdirSync(path.join(dir, HANDOFF_NAME));
  const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const { ctx } = makeContext(dir, "tui", true);

  const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, true);

  assert.deepEqual(
    result,
    errorResult(
      `clipboard-copy: nothing was copied. The OSC 52 handoff file ${HANDOFF_NAME} could not be delivered: it is not a regular file owned by the current user`,
    ),
  );
  assert.deepEqual(written, []);
  assert.equal(existsSync(path.join(dir, HANDOFF_NAME)), false);
});

test("a handoff name holding a directory that cannot be removed is an error that also says why the removal failed", async (t) => {
  // Fail vector: a removal failure that is swallowed leaves the entry behind without a word.
  const fake = await registerStarted(t);
  const dir = await handoffDirectory(fake);
  const entry = path.join(dir, HANDOFF_NAME);
  mkdirSync(entry);
  writeFileSync(path.join(entry, "inside"), OSC52_SEQUENCE);
  const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const { ctx } = makeContext(dir, "tui", true);
  const removal = failureMessage(() => {
    rmdirSync(entry);
  }, "ENOTEMPTY");

  const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, true);

  assert.deepEqual(
    result,
    errorResult(
      `clipboard-copy: nothing was copied. The OSC 52 handoff file ${HANDOFF_NAME} could not be delivered: it is not a regular file owned by the current user; removing it failed too: ${removal}`,
    ),
  );
  assert.deepEqual(written, []);
});

test("a FIFO at the handoff name is an error without waiting for a writer, and the FIFO is removed", { timeout: 20_000 }, async (t) => {
  // Fail vector: opening a FIFO for reading blocks until a writer opens it, which would hang pi. The
  // watchdog opens it for writing after two seconds, so a blocking open ends, and leaves a marker
  // saying it had to.
  const fake = await registerStarted(t);
  const dir = await handoffDirectory(fake);
  const fifo = path.join(dir, HANDOFF_NAME);
  // `mkfifo` comes from PATH, as the system's own utility.
  // eslint-disable-next-line sonarjs/no-os-command-from-path
  execFileSync("mkfifo", [fifo]);
  const marker = path.join(makeTemporaryDirectory(t), "watchdog-unblocked");
  // eslint-disable-next-line sonarjs/no-os-command-from-path
  const watchdog = spawn("bash", ["-c", 'sleep 2; if [[ -p "$1" ]]; then : > "$2"; exec 3> "$1"; fi', "bash", fifo, marker], {
    stdio: "ignore",
  });
  t.after(() => {
    watchdog.kill("SIGKILL");
  });
  const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const { ctx } = makeContext(dir, "tui", true);

  const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, true);
  watchdog.kill("SIGKILL");

  assert.equal(existsSync(marker), false, "the handler waited for a writer on the FIFO");
  assert.deepEqual(
    result,
    errorResult(
      `clipboard-copy: nothing was copied. The OSC 52 handoff file ${HANDOFF_NAME} could not be delivered: it is not a regular file owned by the current user`,
    ),
  );
  assert.deepEqual(written, []);
  assert.equal(existsSync(fifo), false);
});

test("a handoff naming a missing file is an error that says why", async (t) => {
  const fake = await registerStarted(t);
  const dir = await handoffDirectory(fake);
  const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const { ctx } = makeContext(dir, "tui", true);
  const reason = openFailureMessage(path.join(dir, HANDOFF_NAME), "ENOENT");

  const { result, written } = runToolResult(t, fake, toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), ctx, true);

  assert.deepEqual(
    result,
    errorResult(`clipboard-copy: nothing was copied. The OSC 52 handoff file ${HANDOFF_NAME} could not be delivered: ${reason}`),
  );
  assert.deepEqual(written, []);
});

test("a handoff result before the session starts is an error saying there is no handoff directory", async (t) => {
  const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const { ctx } = makeContext(makeTemporaryDirectory(t), "tui", true);

  const { result, written } = runToolResult(
    t,
    register(t),
    toolResultEvent(toolName, `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`),
    ctx,
    true,
  );

  assert.deepEqual(
    result,
    errorResult(
      `clipboard-copy: nothing was copied. The OSC 52 handoff file ${HANDOFF_NAME} could not be delivered: the session has not started, so there is no handoff directory`,
    ),
  );
  assert.deepEqual(written, []);
});

test("a result without a handoff line before the session starts is left unchanged", async (t) => {
  const toolName = await piMcpToolName(SERVER_NAME, "clipboard_copy");
  const { ctx } = makeContext(makeTemporaryDirectory(t), "tui", true);

  const { result, written } = runToolResult(t, register(t), toolResultEvent(toolName, "Copied 5 bytes to clipboard via pbcopy"), ctx, true);

  assert.equal(result, undefined);
  assert.deepEqual(written, []);
});

for (const { event, label } of [
  { event: toolResultEvent("mcp__clipboard_copy__clipboard_copy", "Copied 5 bytes to clipboard via pbcopy"), label: "a result without a handoff line" },
  {
    event: toolResultEvent("mcp__clipboard_copy__clipboard_copy", `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`, true),
    label: "an error result",
  },
  {
    event: toolResultEvent("mcp__clipboard_copy__clipboard_copy", `OSC 52 handoff: ${HANDOFF_NAME}\n${SUMMARY}`),
    label: "a result whose handoff line is not the last line",
  },
  {
    event: toolResultEvent("mcp__clipboard_copy__clipboard_copy", `${SUMMARY}\nOSC 52 handoff: ../${HANDOFF_NAME}`),
    label: "a handoff line naming a path instead of a handoff file",
  },
  { event: toolResultEvent("read", `${SUMMARY}\nOSC 52 handoff: ${HANDOFF_NAME}`), label: "another tool's result" },
]) {
  test(`${label} is left unchanged and its handoff file untouched`, async (t) => {
    const fake = await registerStarted(t);
    const dir = await handoffDirectory(fake);
    writeFileSync(path.join(dir, HANDOFF_NAME), OSC52_SEQUENCE);
    const { ctx } = makeContext(dir, "tui", true);

    const { result, written } = runToolResult(t, fake, event, ctx, true);

    assert.equal(result, undefined);
    assert.deepEqual(written, []);
    assert.equal(readFileSync(path.join(dir, HANDOFF_NAME), "utf8"), OSC52_SEQUENCE);
  });
}
