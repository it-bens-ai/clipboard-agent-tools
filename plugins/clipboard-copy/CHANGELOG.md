# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `.mcp-sdk.lock` and `.github/scripts/vendor-mcp-sdk.sh` at the repository root pin the vendored MCP core to a `shopwareLabs/bash-mcp-sdk` release and its SHA-256. `vendor-mcp-sdk.sh --check` exits non-zero when the vendored copy differs from the pinned release.
- `plugin-tests/clipboard-copy/server_tools_call.bats` drives `server.sh` with JSON-RPC `tools/call` requests and covers the schema refusals.

### Changed

- **Breaking**: `shared/mcpserver_core.sh` is now bash-mcp-sdk v6.0.0, replacing a trimmed copy of an earlier release. The server needs `bash` 5.1+ and `jq` 1.7+ on the `PATH` the host starts it with, plus `ps` and `mkfifo`. A host whose first `bash` on `PATH` is older, such as stock macOS `/bin/bash` 3.2, can no longer start the server.
- Tool arguments are checked against each tool's `inputSchema` before the tool runs. `clipboard_copy_file.path` must match `^/`, and both tools set `additionalProperties: false`, so an undeclared argument, a value of the wrong type, or a relative path returns an `isError` result.
- A `tools/call` runs each tool in its own process group, and the core kills that group when the call ends. The Linux backends `wl-copy`, `xclip`, and `xsel` have not been tested against this.
- The server logs to stderr (`MCP_LOG_STDERR=1`) instead of `mcp-server-clipboard/server.log`.

### Removed

- The absolute-path check in `tool_clipboard_copy_file`; the `pattern` in `tools.json` covers it.
- The `instructions` field in `mcp-server-clipboard/config.json`. The core never sent it in the `initialize` response.

### Fixed

- The server now fails at startup when `tools.json` is missing, invalid JSON, or not exactly one JSON object containing a `tools` array.
- `clipboard_copy` dropped trailing newlines and NUL bytes from `text`, and treated text made only of newlines as empty. A NUL byte also put a bash `ignored null byte` warning into the result. The text now reaches the backend byte for byte, NUL bytes and trailing newlines included, and text made only of newlines or NUL bytes is copied. A missing `text` or `""` is still an error.
- `clipboard_copy` reported the character count as bytes, so `"é€"` gave `Copied 2 bytes` under a UTF-8 locale. It now counts the bytes sent to the backend, `Copied 5 bytes` for that text, in any locale.
- A backend's stderr no longer appears in a successful tool result. The server drops it when the backend exits 0. When the backend exits non-zero, both tools return an error result that names the exit status and carries the backend's stderr.
- Every successful tool result started with the tool's own log line, such as `[…] [INFO] clipboard_copy: backend=pbcopy bytes=2`. The regression came from logging to stderr: the core merges a tool's stderr into its result, so tool log lines appeared in every successful result. `tool_clipboard_copy` and `tool_clipboard_copy_file` no longer log. The server's startup log lines are unchanged.

## [1.3.0] - 2026-08-21

### Added

- **No-echo directive** in `hooks/prompts/mcp-tool-directives.md` — after a clipboard copy the agent reports the tool result (byte count, backend, path) and does not reprint the copied content, overriding an instruction to output that same content. Covered by `plugin-tests/clipboard-copy/session_start.bats`.
- **No-echo clause in both tool descriptions** (`mcp-server-clipboard/tools.json`) — carries the same rule on the channel that survives context summarization and reaches hosts that register the MCP server without the hooks.

## [1.2.1] - 2026-07-13

### Fixed

- Codex now launches the MCP server from the plugin root, and shared hook launchers require host-provided plugin-root variables instead of probing repo-local paths.

## [1.2.0] - 2026-07-09

### Added

- Codex plugin metadata (`.codex-plugin/plugin.json`) and repo marketplace metadata (`.agents/plugins/marketplace.json`) while keeping the existing Claude Code manifest and `.mcp.json` path.
- Shared `AGENTS.md` development guidance with `CLAUDE.md` reduced to an `@AGENTS.md` compatibility wrapper.

### Changed

- Hook launcher commands now resolve either Codex or Claude Code plugin-root environments before falling back to repo-local paths.
- Block-message wording is host-neutral so the shared hook prompt works in both Claude Code and Codex.
- Plugin and MCP server metadata now report version `1.2.0`.

## [1.1.0] - 2026-05-10

### Added

- **SessionStart hook** (`hooks/scripts/session-start.sh`) — injects clipboard-copy MCP tool directives into the conversation context at session start so the model prefers `clipboard_copy` / `clipboard_copy_file` from the first turn, instead of relying solely on the reactive `PreToolUse` block message. The directive is held in `hooks/prompts/mcp-tool-directives.md` and emitted via the standard `hookSpecificOutput.additionalContext` channel.
- **BATS coverage** for the SessionStart hook (`plugin-tests/clipboard-copy/session_start.bats`) — asserts JSON shape (`hookEventName`, non-empty `additionalContext`), directive content (ALWAYS/NEVER framing, both tool names, every blocked Bash command, paste-mode escape hatch), and the silent-success no-op when the prompt template is absent.

## [1.0.0] - 2026-05-08

Initial release.

### Added

- **`clipboard-copy` MCP server** (`mcp-server-clipboard/server.sh`) — bash-based JSON-RPC 2.0 stdio server, registered via `.mcp.json`. Reuses the generic protocol handler in `shared/mcpserver_core.sh`.
- **`clipboard_copy` tool** — copies inline text to the system clipboard. Returns `Copied N bytes to clipboard via <backend>`.
- **`clipboard_copy_file` tool** — copies the contents of a file at an absolute path. Validates that the path is non-empty, absolute, exists, is a regular file, and is readable; rejects everything else with a specific error message.
- **Auto-detected backend cascade** in `_clipboard_detect_backend`:
  - macOS → `pbcopy` → `osc52`
  - Linux → `clip.exe` (WSL) → `wl-copy` (Wayland) → `xclip` / `xsel` (X11) → headless fallback → `osc52`
  - Cygwin / MinGW / MSYS → `clip` → `osc52`
  - everything else → `osc52`
- **OSC 52 fallback** writes a base64-encoded escape sequence to `/dev/tty` (wrapped in a tmux DCS pass-through when `$TMUX` is set), so the server still copies over SSH and in headless environments.
- **PreToolUse(Bash) enforcement hook** (`hooks/scripts/check-clipboard.sh`) — blocks native clipboard-write commands and routes the model to the MCP tools. Recognizes `pbcopy`, `wl-copy`, `clip.exe`, `clip`, and copy-mode `xclip` / `xsel`. Allows paste-mode invocations (`pbpaste`, `wl-paste`, `xclip -o`, `xsel -o`/`--output`). Block message follows the friendly `🤖 Down, model!` voice used by the rest of the marketplace.
