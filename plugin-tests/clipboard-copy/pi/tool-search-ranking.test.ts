import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import clipboardCopy from "../../../plugins/clipboard-copy/pi/index.ts";
import { registerOnFakePi } from "./fake-pi.ts";
import { loadPiInternal } from "./pi-internals.ts";
import { makeTemporaryDirectory } from "./temporary-directory.ts";

const PLUGIN_DIR = fileURLToPath(new URL("../../../plugins/clipboard-copy", import.meta.url));
const SERVER_NAME = "clipboard-copy";

interface ToolDefinition {
  description: string;
  inputSchema: Record<string, unknown>;
  name: string;
}

interface SearchDocument {
  name: string;
  text: string;
}

interface SearchNamespace {
  description?: string;
  instructions?: string;
  name: string;
}

interface ToolSearchModule {
  Bm25Ranker: new (options?: Record<string, unknown>) => { rank(query: string, documents: SearchDocument[], limit: number): { name: string; score: number }[] };
  createToolSearchDocument: (tool: { description: string; name: string; parameters: unknown }, namespace?: SearchNamespace) => SearchDocument;
  tokenize: (text: string) => string[];
}

interface McpServersModule {
  mcpNamespace: (server: string) => string;
}

interface McpToolsModule {
  createMcpToolName: (server: string, tool: string, isTaken?: (name: string) => boolean) => string;
}

function loadCatalog(): ToolDefinition[] {
  const file = path.join(PLUGIN_DIR, "mcp-server-clipboard", "tools.json");
  const catalog = JSON.parse(readFileSync(file, "utf8")) as { tools: unknown };
  if (!Array.isArray(catalog.tools) || catalog.tools.length === 0) {
    throw new Error(`${file} has no tools`);
  }
  for (const [index, tool] of catalog.tools.entries()) {
    const candidate = tool as Record<string, unknown>;
    if (typeof candidate.name !== "string" || candidate.name === "") {
      throw new TypeError(`${file} tool at index ${String(index)} has no non-empty string "name"`);
    }
    if (typeof candidate.description !== "string") {
      throw new TypeError(`${file} tool "${candidate.name}" has no string "description"`);
    }
    if (typeof candidate.inputSchema !== "object" || candidate.inputSchema === null || Array.isArray(candidate.inputSchema)) {
      throw new TypeError(`${file} tool "${candidate.name}" has no object "inputSchema"`);
    }
  }
  return catalog.tools as ToolDefinition[];
}

/**
 * The server description the extension registers when its session starts.
 */
async function registeredDescription(t: TestContext): Promise<string> {
  const fake = registerOnFakePi(clipboardCopy);
  const start = fake.handlers.get("session_start");
  const shutdown = fake.handlers.get("session_shutdown");
  if (start === undefined || shutdown === undefined) {
    throw new Error("the extension registered no session_start or no session_shutdown handler");
  }
  await start({ reason: "startup", type: "session_start" }, { cwd: makeTemporaryDirectory(t), hasUI: false, mode: "print" });
  const server = fake.servers.get(SERVER_NAME);
  // Removes the handoff directory the session start created.
  await shutdown({ reason: "quit", type: "session_shutdown" }, {});
  if (server?.description === undefined) {
    throw new Error(`the extension registered no "${SERVER_NAME}" server with a description`);
  }
  return server.description;
}

test("tool_search ranks each tool first for its bare name and for pi's name of it", async (t) => {
  // Fail vector: a server description or tool description that pulls the other tool above the
  // one named, for example a description repeating "copy" or "clipboard".
  const { Bm25Ranker: bm25Ranker, createToolSearchDocument } = await loadPiInternal<ToolSearchModule>("extensions/tool-search/tool.js", [
    "Bm25Ranker",
    "createToolSearchDocument",
  ]);
  const { mcpNamespace } = await loadPiInternal<McpServersModule>("core/mcp-servers.js", ["mcpNamespace"]);
  const { createMcpToolName } = await loadPiInternal<McpToolsModule>("extensions/mcp/tools.js", ["createMcpToolName"]);
  const tools = loadCatalog();
  const namespace: SearchNamespace = { description: await registeredDescription(t), name: mcpNamespace(SERVER_NAME) };
  const documents = tools.map((tool) =>
    createToolSearchDocument(
      { description: tool.description, name: createMcpToolName(SERVER_NAME, tool.name), parameters: tool.inputSchema },
      namespace,
    ),
  );
  const ranker = new bm25Ranker();

  const firstRanked = tools.flatMap((tool) =>
    [tool.name, createMcpToolName(SERVER_NAME, tool.name)].map((query) => ({
      first: ranker.rank(query, documents, documents.length)[0]?.name,
      query,
    })),
  );

  assert.deepEqual(
    firstRanked,
    tools.flatMap((tool) =>
      [tool.name, createMcpToolName(SERVER_NAME, tool.name)].map((query) => ({ first: createMcpToolName(SERVER_NAME, tool.name), query })),
    ),
  );
});

test("the server description shares no search term with any tool name", async (t) => {
  // Fail vector: a description word such as "clipboard", "copy", "file", or "mcp", which every tool
  // document then carries and which blurs the ranking between the tools.
  const { tokenize } = await loadPiInternal<ToolSearchModule>("extensions/tool-search/tool.js", ["tokenize"]);
  const { createMcpToolName } = await loadPiInternal<McpToolsModule>("extensions/mcp/tools.js", ["createMcpToolName"]);
  const toolNameTerms = new Set(
    loadCatalog().flatMap((tool) => [...tokenize(tool.name), ...tokenize(createMcpToolName(SERVER_NAME, tool.name))]),
  );

  const shared = tokenize(await registeredDescription(t)).filter((term) => toolNameTerms.has(term));

  assert.deepEqual(shared, []);
});
