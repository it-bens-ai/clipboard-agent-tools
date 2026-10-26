## Named-value assignments

- `project.stacks` =
  - `bash` — `plugins/**/*.sh`, `.github/scripts/*.sh`, `plugin-tests/**/*.{bats,bash,sh}`. There is no other stack: no npm package, no TypeScript, no vendored SDK.
- `code.primitives` =
  | Call shape | Raw primitive | Helper | Invariant carried |
  |---|---|---|---|
  | Pick the clipboard backend | Ad hoc `command -v` checks at the call site | `_clipboard_detect_backend` (`mcp-server-clipboard/lib/clipboard.sh`) | One `uname -s`-scoped cascade per call; every unmatched OS falls through to `osc52`; no side effects |
  | Send bytes to the clipboard | Calling `pbcopy` / `wl-copy` / `xclip` / `xsel` / `clip.exe` / `clip` directly | `_clipboard_send_stdin <backend>` (`mcp-server-clipboard/lib/clipboard.sh`) | OSC 52 writes to `/dev/tty`, never stdout, and wraps in a tmux DCS pass-through when `$TMUX` is set; returns 1 when `/dev/tty` is unwritable |
  | Base64-encode the OSC 52 payload | Raw `base64` | `_clipboard_b64` (`mcp-server-clipboard/lib/clipboard.sh`) | GNU `base64 -w 0`, BSD `base64 \| tr -d '\r\n'`, then `openssl base64 -A`; returns 1 when neither exists |
  | Read a tool argument | Hand-parsed JSON | `jq -r '.text // empty'` / `jq -r '.path // empty'` inside each `tool_*` function | A missing argument produces an error text result; it is never defaulted |
  | Validate a file argument | Ad hoc `[[ ]]` chains | the guard chain in `tool_clipboard_copy_file` (`mcp-server-clipboard/lib/clipboard.sh`) | Empty, relative, missing, non-regular, and unreadable paths each get their own error and return 1 |
  | Dispatch a JSON-RPC tool call | Ad hoc `case` on the tool name | `handle_tools_call` → `tool_<name>()` (`shared/mcpserver_core.sh`) | Tool name validated against `^[a-zA-Z_][a-zA-Z0-9_]*$`; an unregistered `tool_<name>` returns JSON-RPC -32601 |
  | Log from the server | `echo` | `log <level> <message>` (`shared/mcpserver_core.sh`) | Writes to `$MCP_LOG_FILE`; stdout carries JSON-RPC responses only |
  | Reject a blocked Bash command | Ad hoc `echo … >&2; exit 2` | `block_clipboard <tool> <hint>` (`hooks/scripts/lib/common.sh`) | Exit 2 is the deny signal; the message stays host-neutral |
  | Read the PreToolUse command | Ad hoc JSON parsing in the entry script | `parse_hook_input` (`hooks/scripts/lib/common.sh`) | Sets the `COMMAND` global and exits 0 (allow) when the command field is empty |
- `code.di_pattern` = Bash. A tool function `tool_<name>()` receives the JSON arguments string as `$1` and writes its user-visible result to stdout; `run_mcp_server` dispatches on the function name alone. Context enters through environment variables exported at the entry point: `mcp-server-clipboard/server.sh` sets `SCRIPT_DIR`, `SHARED_DIR`, `MCP_CONFIG_FILE`, `MCP_TOOLS_LIST_FILE`, and `MCP_LOG_FILE`; `hooks/scripts/session-start.sh` resolves its prompt path from its own location. Clipboard utilities resolve from `PATH`, so tests substitute stubbed executables and a `PATH`-only mock directory rather than mocking calls.
- `code.export_conventions` =
  - A new MCP tool is a `tool_<name>()` in `mcp-server-clipboard/lib/clipboard.sh` plus a schema entry in `mcp-server-clipboard/tools.json`; `tools/list` advertises only the tools that file declares, while `handle_tools_call` runs any defined `tool_<name>()`, so a function without a schema entry is still callable. Read `plugins/clipboard-copy/AGENTS.md` §Navigation before adding one.
  - Hook logic shared by more than one script lives in `hooks/scripts/lib/common.sh`; the entry scripts source it and stay thin.
  - Scripts open with `#!/usr/bin/env bash` or `#!/bin/bash`; `mcp-server-clipboard/server.sh` and `shared/mcpserver_core.sh` run under `set -euo pipefail`, and `lib/clipboard.sh` inherits it by being sourced from `server.sh`.
- `code.footgun_additions` =
  - OSC 52 output must reach `/dev/tty`. Writing the escape sequence to stdout corrupts the JSON-RPC stream.
  - A tool function's stdout becomes the MCP `content[].text`; diagnostics belong in `log`, never in `echo` on stdout.
  - The hook launchers resolve the plugin root from `PLUGIN_ROOT` or `CLAUDE_PLUGIN_ROOT` and fail when neither is set. No cwd-relative fallback; `plugin-tests/clipboard-copy/plugin_launch.bats` asserts it.
  - Size is read with `wc -c < "$path" | tr -d ' '` because `wc` pads the count differently across platforms.
  - `hooks/hooks.json` carries the hook registration for both hosts. Changing a command there needs a matching assertion in `plugin_launch.bats`.
- `comments.preserve_patterns` =
  - The `# Tools: clipboard_copy, clipboard_copy_file` header line in `mcp-server-clipboard/lib/clipboard.sh`
  - The `# Globals set by parse_hook_input:` block above `parse_hook_input` in `hooks/scripts/lib/common.sh`
  - The `# Args:` blocks documenting `block_clipboard` and `tool_clipboard_copy`
- `domain.terms` = `clipboard_copy`, `clipboard_copy_file`, `backend` (one of `pbcopy`, `wl-copy`, `xclip`, `xsel`, `clip-exe`, `clip`, `osc52`), `clip-exe` (the backend ID for WSL's `clip.exe`), `OSC 52`, `SessionStart directive`, `PreToolUse block`, `plugin root`, `PLUGIN_ROOT`, `CLAUDE_PLUGIN_ROOT`, `additionalContext`
- `docs.surfaces` =
  | Surface | Owns | Shape | Single-owner |
  |---|---|---|---|
  | `README.md` | Marketplace pitch, requirements, per-host install commands, pointers into plugin docs | Root README | enforced |
  | `AGENTS.md` | Two-host model, repository architecture, test commands, version bumps | Architecture document | enforced |
  | `plugins/clipboard-copy/README.md` | Tool catalog, backend detection order, hook behavior, plugin layout, requirements | Module README | enforced |
  | `plugins/clipboard-copy/AGENTS.md` | Plugin file layout, key functions, task-to-file navigation, MCP wire flow, test suites, manual smoke tests | Module architecture and navigation document | enforced |
  | `plugins/clipboard-copy/CHANGELOG.md` | Released changes per version | Changelog | exempt: each entry restates what its release changed |

  Runtime prompt text under `plugins/clipboard-copy/hooks/prompts/` is a runtime file, not a documentation surface.

## Post-Step-6

After editing a `.sh` file, run `shellcheck --shell=bash` on it when ShellCheck is installed, then run `.bats/bats-core/bin/bats -r plugin-tests/`. No CI catches either step.
