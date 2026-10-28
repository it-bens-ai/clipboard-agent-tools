# clipboard-copy — Agent Guide

Human-facing documentation is in `README.md` and `docs/`. This file routes tasks to files and lists the rules for editing the plugin.

## Documentation

| Topic | File |
|---|---|
| Tool arguments, results, schema validation | `docs/tools.md` |
| Backend detection order, OSC 52 fallback | `docs/backends.md` |
| SessionStart directive, Bash block matrix, hook exit codes | `docs/hooks.md` |
| Pi extension behavior, Pi tool names, supported Pi versions | `docs/pi.md` |
| Failure symptoms and fixes | `docs/troubleshooting.md` |
| File layout, host wiring, terms, MCP wire flow, key functions | `docs/architecture.md` |
| Test suites, tags, mocking helpers, manual smoke tests | `docs/testing.md` |
| Repository layout, test and lint commands, CI, vendored SDK | `../../docs/development.md` |

## Before editing

- Keep the plugin working on Claude Code, Codex, and Pi (`docs/architecture.md` §Host wiring).
- Keep `hooks/hooks.json` valid for both Claude Code and Codex. Resolve the plugin root from `PLUGIN_ROOT` or `CLAUDE_PLUGIN_ROOT` and fail when neither is set; never probe cwd-relative fallback paths (`docs/hooks.md` §Hook registration).
- Codex files are additive. Never replace a Claude Code file to add Codex support.
- Pi-specific wording goes in `hooks/prompts/host-pi.md` or behind `CLIPBOARD_COPY_HOST=pi`, never into `hooks/prompts/mcp-tool-directives.md` (`docs/pi.md` §Directive).
- Keep the `block_clipboard` message free of Claude-only or Codex-only terminology (`docs/architecture.md` §Key functions).
- Never edit `shared/mcpserver_core.sh`. It is vendored from `shopwareLabs/bash-mcp-sdk`; protocol changes go to that repository (`../../docs/development.md` §Vendored MCP SDK).
- When behavior changes, update the `docs/` file that owns it (table above) and add an entry to `CHANGELOG.md`. A new test suite gets a bullet in `docs/testing.md` §Suites.

## Navigation

| Task | File |
|---|---|
| Change backend detection cascade | `mcp-server-clipboard/lib/clipboard.sh` — `_clipboard_detect_backend` |
| Add a new clipboard backend | `mcp-server-clipboard/lib/clipboard.sh` — extend `_clipboard_detect_backend` and `_clipboard_write_backend` |
| Change OSC 52 wrapping (e.g. screen support) | `mcp-server-clipboard/lib/clipboard.sh` — `osc52` branch in `_clipboard_write_backend` |
| Change how backend stderr and failures reach the tool result | `mcp-server-clipboard/lib/clipboard.sh` — `_clipboard_send_stdin` |
| Add a new MCP tool | Add `tool_<name>` to `lib/clipboard.sh` and a schema entry to `mcp-server-clipboard/tools.json` |
| Update tool descriptions / schemas | `mcp-server-clipboard/tools.json` |
| Adjust the SessionStart directive text | `hooks/prompts/mcp-tool-directives.md` |
| Change how the SessionStart directive is assembled or emitted | `hooks/scripts/session-start.sh` |
| Adjust which Bash patterns get blocked | `hooks/scripts/check-clipboard.sh` |
| Adjust the block message or the unsupported-host message | `hooks/scripts/lib/common.sh` — `block_clipboard`, `validate_clipboard_host` |
| Adjust the hook timeout | `hooks/hooks.json` |
| Re-register the Claude Code MCP server entry point | `.mcp.json` |
| Re-register the Codex MCP server entry point | `.codex-plugin/plugin.json` |
| Update Codex marketplace metadata | `.agents/plugins/marketplace.json` at repo root |
| Change the Pi server registration, directive section, or Bash check | `pi/index.ts` — `clipboardCopy` |
| Change how a hook script's exit code maps to allow or block on Pi | `pi/gate.ts` — `runGate` |
| Change how the OSC 52 sequence reaches Pi's terminal | `mcp-server-clipboard/lib/clipboard.sh` — `_clipboard_osc52_handoff`, `_clipboard_handoff_note`; `pi/index.ts` — `handBack` and the `tool_result` handler |
| Adjust the Pi-only directive text | `hooks/prompts/host-pi.md` |
| Adjust Pi tool names in the block message | `hooks/scripts/lib/common.sh` — `block_clipboard` |
| Update the Pi package manifest or published files | `package.json` at repo root |

