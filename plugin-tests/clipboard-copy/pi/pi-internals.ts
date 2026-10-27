import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

/**
Loads a pi internal by its path under pi's `dist` directory, since these modules are not in the
package `exports` map, and checks that it has every named function export. A pi upgrade that
moves, renames, or removes one fails the test that loads it instead of silently losing coverage.
*/
export async function loadPiInternal<T>(relativePath: string, exportNames: readonly string[]): Promise<T> {
  const piPackageDirectory = path.dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")));
  if (path.basename(piPackageDirectory) !== "dist" || path.basename(path.dirname(piPackageDirectory)) !== "pi-coding-agent") {
    throw new Error(`resolved pi package directory "${piPackageDirectory}" is not ".../pi-coding-agent/dist"`);
  }
  const absolute = path.join(piPackageDirectory, relativePath);
  const loaded = (await import(pathToFileURL(absolute).href)) as Record<string, unknown>;
  for (const exportName of exportNames) {
    if (typeof loaded[exportName] !== "function") {
      throw new TypeError(`pi internal "${relativePath}" has no function export "${exportName}"`);
    }
  }
  return loaded as unknown as T;
}

export interface McpToolsModule {
  createMcpToolName: (server: string, tool: string, isTaken?: (name: string) => boolean) => string;
}

/**
pi's own name for a tool of an MCP server, from pi's MCP bridge.
*/
export async function piMcpToolName(server: string, tool: string): Promise<string> {
  const { createMcpToolName } = await loadPiInternal<McpToolsModule>("extensions/mcp/tools.js", ["createMcpToolName"]);
  return createMcpToolName(server, tool);
}

interface ResolveConfigValueModule {
  resolveConfigValueUncached: (config: string, env?: NodeJS.ProcessEnv) => string | undefined;
}

/**
An MCP server env value as pi resolves it before it starts the server.
*/
export async function piResolveEnvironmentValue(value: string): Promise<string | undefined> {
  const { resolveConfigValueUncached } = await loadPiInternal<ResolveConfigValueModule>("core/resolve-config-value.js", [
    "resolveConfigValueUncached",
  ]);
  return resolveConfigValueUncached(value, process.env);
}

interface McpServersModule {
  validateMcpServerConfig: (name: string, raw: unknown) => unknown;
}

/**
pi's check of an MCP server registration: an error message, or the accepted config.
*/
export async function piValidateMcpServerConfig(name: string, config: unknown): Promise<unknown> {
  const { validateMcpServerConfig } = await loadPiInternal<McpServersModule>("core/mcp-servers.js", ["validateMcpServerConfig"]);
  return validateMcpServerConfig(name, config);
}
