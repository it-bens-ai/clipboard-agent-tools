# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.1] - 2026-10-28

### Added

- The npm package includes the plugin's `docs/` directory.

### Fixed

- A paste-mode `xclip` or `xsel` call could let other calls of the same tool in the same command through (for example, `xclip -i < f; xclip -o`); now each call is checked on its own.
- A paste flag directly followed by `;` or `|`, as in `xclip -o; xsel -o` or `xclip -o|grep x`, no longer blocks the command.

## [2.0.0] - 2026-10-28

### Added

- `.mcp-sdk.lock` and `.github/scripts/vendor-mcp-sdk.sh` at the repository root pin the vendored MCP core to a `shopwareLabs/bash-mcp-sdk` release and its SHA-256. `vendor-mcp-sdk.sh --check` exits non-zero when the vendored copy differs from the pinned release.
- `plugin-tests/clipboard-copy/server_tools_call.bats` drives `server.sh` with JSON-RPC `tools/call` requests and covers the schema refusals.
- Pi support on macOS and Linux, with Node.js 22.19 or newer. The repository root is the npm package `@it-bens-ai/clipboard-agent-tools`, installed with `pi install npm:@it-bens-ai/clipboard-agent-tools` or `pi install git:github.com/it-bens-ai/clipboard-agent-tools`. The npm package is first published with this release, so it is not on the registry before it. On `session_start` its extension, `pi/index.ts`, creates the OSC 52 handoff directory and registers the MCP server with deferred exposure. The model then loads `mcp__clipboard_copy__clipboard_copy` and `mcp__clipboard_copy__clipboard_copy_file` through `tool_search`. It adds the directive to the system prompt as the section `clipboard_copy`, and runs `check-clipboard.sh` before each `bash` tool call. Exit 2 blocks the call, and so does a failing or timed-out check. A check that cannot run therefore blocks every `bash` call, with a warning naming the cause. Pi's `powershell` tool is not checked. The package declares `@earendil-works/pi-coding-agent` as a peer dependency with the range `*`.
- `hooks/prompts/host-pi.md`, which `session-start.sh` appends to the directive when `CLIPBOARD_COPY_HOST=pi`. With `CLIPBOARD_COPY_HOST=pi` the block message uses the Pi tool names, and a name that already carries the Pi prefix is not prefixed again. Both hook scripts fail on any other non-empty `CLIPBOARD_COPY_HOST` with the same message. `session-start.sh` exits 1 before reading the template, and `check-clipboard.sh` exits 1 for every non-empty command, clipboard write or not.
- OSC 52 on Pi. With `CLIPBOARD_COPY_OSC52_DIR` set to a non-empty value and `CLIPBOARD_COPY_HOST=pi`, the server writes the sequence to an owner-only file in that directory, not `/dev/tty`. It names the file on the result's last line. An empty value counts as unset, and another host is refused. The path must be absolute and equal its own physical path, so a symlink, a trailing slash, or a `.` component is refused. It is also refused when it is not owned by the current user, or is writable by group or others. The base64 payload is capped at 100000 characters, checked from the byte count before the encoder runs. The extension writes the sequence to Pi's terminal in interactive mode and returns an error in print, JSON, and RPC mode. It reads the handoff file without following a link and without waiting on a FIFO. When it cannot read the entry, it removes whatever is at that name. A failure inside the server removes the handoff file; a call cancelled after it is written leaves the file until session end.
- `.github/workflows/npm-publish.yml` stages the package on npm on `v*` tags with trusted publishing, using `npm stage publish`. A staged version goes live once a maintainer approves it with 2FA. The workflow runs the Node, ShellCheck, SDK pin, and BATS checks, and stages only when the tag is on `main` and matches every manifest version. `.github/scripts/check-versions.sh` compares those versions, and CI runs it too.

### Changed

- **Breaking**: `shared/mcpserver_core.sh` is now bash-mcp-sdk v6.0.0, replacing a trimmed copy of an earlier release. The server needs `bash` 5.1+ and `jq` 1.7+ on the `PATH` the host starts it with, plus `ps` and `mkfifo`. A host whose first `bash` on `PATH` is older, such as stock macOS `/bin/bash` 3.2, can no longer start the server.
- Tool arguments are checked against each tool's `inputSchema` before the tool runs. `clipboard_copy_file.path` must match `^/`, and both tools set `additionalProperties: false`, so an undeclared argument, a value of the wrong type, or a relative path returns an `isError` result.
- A `tools/call` runs each tool in its own process group, and the core kills that group when the call ends. The Linux backends `wl-copy`, `xclip`, and `xsel` have not been tested against this.
- The server logs to stderr (`MCP_LOG_STDERR=1`) instead of `mcp-server-clipboard/server.log`.
- The SessionStart directive says the Bash equivalents are blocked "by a hook"; it previously said "by a PreToolUse hook".
- `hooks/scripts/session-start.sh` exits 1 with an error on stderr when its directive template or `jq` is missing, naming the template path or `jq`. It previously exited 0 with no output.

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
