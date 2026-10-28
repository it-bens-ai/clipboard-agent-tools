# Troubleshooting

- **Server not starting:** Run `bash --version` and `jq --version` in the host's environment and compare them with the repository README's [Requirements](../../../README.md#requirements). Check the MCP host's stderr for server startup logs. The server sets `MCP_LOG_STDERR=1`; it does not write a plugin-local `server.log`. A missing or invalid `tools.json` also stops the server at startup; see [Tools](tools.md#argument-validation).
- **Tools missing after installation:** Restart Claude Code or start a new Codex task. In Claude Code, inspect the server with `/mcp`. On Pi, start a new session; the tools appear after `tool_search` loads them (see [Pi](pi.md#tools)).
- **Codex hook not blocking clipboard commands:** Open `/hooks` in Codex and trust the bundled hooks; untrusted plugin hooks do not run.
- **Pi copy fails with "nothing was copied":** The server fell back to OSC 52, and Pi is not running in interactive mode in a terminal. Install a native clipboard utility (see [Backends](backends.md#native-clipboard-utilities)), or run Pi interactively. See [OSC 52 on Pi](pi.md#osc-52-on-pi).
- **OSC 52 reports success but nothing is copied:** The terminal must support and permit OSC 52, and the server cannot detect whether it accepted the sequence. See [Backends](backends.md#osc-52-fallback).
