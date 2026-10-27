// Scripted model for pi_e2e.bats. Registers the faux provider (model faux/faux-1), answers each
// model request with the next turn of the $SCENARIO script, and records every request's messages
// in $TRACE so the suite can assert the system prompt section the package extension adds.
import { appendFileSync, readdirSync, writeFileSync } from "node:fs";
import {
  fauxAssistantMessage,
  fauxProvider,
  type FauxResponseFactory,
  fauxText,
  fauxToolCall,
  type ToolCall,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function requiredEnvironmentVariable(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(`driver.ts: ${name} must be set`);
  }
  return value;
}

const SCENARIO = requiredEnvironmentVariable("SCENARIO");
const TRACE = requiredEnvironmentVariable("TRACE");
const FILE_PATH = requiredEnvironmentVariable("CLIPBOARD_COPY_FILE");
// Only the `tui` scenario sets it: interactive pi keeps waiting for editor input after the last
// turn, so the suite needs a marker to close the pipe it holds open on pi's stdin.
const SETTLE_FILE = process.env.SETTLE_FILE;
// eslint-disable-next-line sonarjs/publicly-writable-directories -- the suite points TMPDIR at its own directory
const TMPDIR = process.env.TMPDIR;

/**
 * Records the entries under $TMPDIR before each model request in the scenarios that hand OSC 52 off
 * through it. The request that follows the tool call runs after the extension's tool_result handler
 * and before pi's session_shutdown removes the whole handoff directory, so the suite can tell
 * whether the handler deleted the handoff file itself.
 */
function recordTemporaryDirectoryEntries(): void {
  if (TMPDIR === undefined || TMPDIR === "" || (SCENARIO !== "osc52" && SCENARIO !== "tui")) {
    return;
  }
  appendFileSync(`${TRACE}.tmpdir`, `${JSON.stringify(readdirSync(TMPDIR, { recursive: true }))}\n`);
}

const searchCopy = fauxToolCall("tool_search", { limit: 1, query: "clipboard_copy" }, { id: "search-copy" });

const copyText = fauxToolCall(
  "mcp__clipboard_copy__clipboard_copy",
  { text: "hello pi" },
  { id: "copy-text" },
);

const searchCopyFile = fauxToolCall(
  "tool_search",
  { limit: 1, query: "clipboard_copy_file" },
  { id: "search-copy-file" },
);

const copyFile = fauxToolCall(
  "mcp__clipboard_copy__clipboard_copy_file",
  { path: FILE_PATH },
  { id: "copy-file" },
);

const bashPbcopy = fauxToolCall("bash", { command: "printf x | pbcopy" }, { id: "bash-pbcopy" });

/**
 * One assistant turn per model request; the last turn ends the run with plain text.
 */
const SCENARIOS: Record<string, (ToolCall | ToolCall[] | string)[]> = {
  deferred: [searchCopy, copyText, searchCopyFile, copyFile, bashPbcopy, "done"],
  osc52: [
    searchCopy,
    fauxToolCall(
      "mcp__clipboard_copy__clipboard_copy",
      { text: "osc52 pi" },
      { id: "copy-text-osc52" },
    ),
    "done",
  ],
  tui: [
    searchCopy,
    fauxToolCall(
      "mcp__clipboard_copy__clipboard_copy",
      { text: "osc52 pi" },
      { id: "copy-text-tui" },
    ),
    "done",
  ],
};

const turns = SCENARIOS[SCENARIO];
if (turns === undefined) {
  throw new Error(`driver.ts: unknown SCENARIO ${SCENARIO}`);
}

const responses: FauxResponseFactory[] = turns.map((turn) => (context) => {
  recordTemporaryDirectoryEntries();
  appendFileSync(TRACE, `${JSON.stringify(context.messages)}\n`);
  return fauxAssistantMessage(typeof turn === "string" ? fauxText(turn) : turn);
});

export default function driver(pi: ExtensionAPI): void {
  const faux = fauxProvider();
  faux.setResponses(responses);
  pi.registerProvider(faux.provider);
  // Interactive pi blocks on its editor after the last turn, so the `tui` scenario ends through
  // ctx.shutdown(). The marker file tells the suite pi has settled, which closes the pipe it holds
  // open on stdin; pi then exits normally, which runs session_shutdown.
  if (SETTLE_FILE !== undefined) {
    pi.on("agent_settled", (_event, ctx) => {
      writeFileSync(SETTLE_FILE, "settled\n");
      ctx.shutdown();
    });
  }
}
