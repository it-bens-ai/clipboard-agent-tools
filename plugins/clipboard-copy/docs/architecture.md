# Architecture

The plugin is one Bash MCP server, two hook scripts with their prompt files, and a Pi extension. Claude Code, Codex, and Pi share the server, the hook scripts, and the directive prompt; each host reaches them through its own manifest.

## Terms

- `backend` — the clipboard utility a copy goes through: `pbcopy`, `wl-copy`, `xclip`, `xsel`, `clip-exe` (WSL's `clip.exe`), `clip`, or `osc52`.
- `OSC 52` — the terminal escape sequence the server writes when no native utility is available; see [Backends](backends.md#osc-52-fallback).
- `OSC 52 handoff` — the file the server leaves in `CLIPBOARD_COPY_OSC52_DIR` for the Pi extension to write to the terminal; see [Pi](pi.md#osc-52-on-pi).
- `SessionStart directive` — the text in `hooks/prompts/mcp-tool-directives.md` that the SessionStart hook adds to the model's context.
- `PreToolUse block` — the exit 2 from `check-clipboard.sh` that denies a Bash command.
- `plugin root` — the plugin directory, which the hook commands resolve from `PLUGIN_ROOT` (Codex) or `CLAUDE_PLUGIN_ROOT` (Claude Code).
- `CLIPBOARD_COPY_HOST` — unset on Claude Code and Codex, `pi` on Pi. The server and both hook scripts read it.

## File layout

```
plugins/clipboard-copy/
├── README.md
├── AGENTS.md                        # Routing and editing rules for coding agents
├── CHANGELOG.md
├── docs/                            # Tools, backends, hooks, Pi, troubleshooting, architecture, testing
├── .claude-plugin/
│   └── plugin.json                  # Claude Code plugin manifest
├── .codex-plugin/
│   └── plugin.json                  # Codex plugin manifest and MCP server declaration
├── .mcp.json                        # Claude Code MCP registration
├── pi/
│   ├── index.ts                     # Pi extension entry point (named in the root package.json): server registration, directive, Bash check, OSC 52 handoff
│   └── gate.ts                      # runScript / runGate: run a hook script, map its exit code to allow or block
├── shared/
│   └── mcpserver_core.sh            # JSON-RPC 2.0 stdio handler, vendored from bash-mcp-sdk
├── mcp-server-clipboard/
│   ├── server.sh                    # MCP entry point (referenced from .mcp.json)
│   ├── config.json                  # protocolVersion, serverInfo, capabilities for initialize
│   ├── tools.json                   # Tool schemas returned by tools/list (clipboard_copy, clipboard_copy_file)
│   └── lib/
│       └── clipboard.sh             # Backend detection + tool implementations
└── hooks/
    ├── hooks.json                   # SessionStart + PreToolUse(Bash) registration
    ├── prompts/
    │   ├── mcp-tool-directives.md   # Static directive injected at SessionStart
    │   └── host-pi.md               # Pi addendum appended when CLIPBOARD_COPY_HOST=pi
    └── scripts/
        ├── session-start.sh         # Emits the directive as additionalContext
        ├── check-clipboard.sh       # Pattern-matches and blocks native writes
        └── lib/
            └── common.sh            # parse_hook_input + validate_clipboard_host + block_clipboard helpers
```

## Host wiring

| Host | Reads | MCP server | Hooks |
|---|---|---|---|
| Claude Code | `.claude-plugin/marketplace.json` at the repository root, then `.claude-plugin/plugin.json` | `.mcp.json` runs `${CLAUDE_PLUGIN_ROOT}/mcp-server-clipboard/server.sh` | `hooks/hooks.json` |
| Codex | `.agents/plugins/marketplace.json` at the repository root, then `.codex-plugin/plugin.json` | `.codex-plugin/plugin.json` runs `bash ./mcp-server-clipboard/server.sh` with `"cwd": "."` | `hooks/hooks.json` |
| Pi | `pi.extensions` in the repository root `package.json`, which names `pi/index.ts` | `pi/index.ts` registers `mcp-server-clipboard/server.sh` on `session_start` | `pi/index.ts` runs `hooks/scripts/session-start.sh` and `hooks/scripts/check-clipboard.sh` from its event handlers |

Both marketplace files point at `./plugins/clipboard-copy`. [Hooks](hooks.md) and [Pi](pi.md) describe what the hooks and the extension do.

## MCP wire flow

1. Claude Code spawns `mcp-server-clipboard/server.sh` per `.mcp.json`; Codex spawns the same server through `.codex-plugin/plugin.json`.
2. `server.sh` exports `MCP_CONFIG_FILE`, `MCP_TOOLS_LIST_FILE`, `MCP_LOG_STDERR=1`, and sources `mcpserver_core.sh` + `lib/clipboard.sh`. Before `run_mcp_server`, it requires `tools.json` to contain exactly one JSON object with a `tools` array; a missing or invalid list exits non-zero and prints an error to stderr.
3. The loop reads JSON-RPC requests one per line on stdin and writes responses on stdout. Log lines go to stderr; a `MCP_LOG_FILE` set in the host environment also receives them. The core merges a tool call's stderr into the tool result, so the tool functions and the helpers they call do not log.
4. `tools/call clipboard_copy` → `tool_clipboard_copy` → `_clipboard_send_stdin <backend>` → `_clipboard_write_backend <backend>` → backend utility or OSC 52 escape to `/dev/tty`.
5. On Pi, `pi/index.ts` registers the server on `session_start` and sets `CLIPBOARD_COPY_OSC52_DIR`. The OSC 52 escape goes to a handoff file instead of `/dev/tty`, `_clipboard_handoff_note` names it on the result's last line, and the extension's `tool_result` handler writes it to Pi's terminal.

## Key functions

### MCP server (`mcp-server-clipboard/`)

#### `_clipboard_detect_backend()` (in `lib/clipboard.sh`)
Echoes the backend name for the current environment without side effects. See [Detection order](backends.md#detection-order) for the selection order.

#### `_clipboard_b64()` (in `lib/clipboard.sh`)
Base64-encodes stdin without line wraps. Uses `base64 -w 0` when GNU base64 is available, falls back to `base64 | tr -d '\r\n'` for BSD/macOS, and to `openssl base64 -A` if neither is present. A failing `base64` or `openssl` returns non-zero instead of an empty payload. The server already runs with `pipefail`; the function sets it again, scoped by `local -`, so the BSD pipeline keeps base64's status when `lib/clipboard.sh` is sourced on its own, as the tests do. Returns 1 if neither is reachable.

#### `_clipboard_write_backend(backend, bytes)` (in `lib/clipboard.sh`)
Reads stdin and dispatches to the right utility (`pbcopy`, `wl-copy`, `xclip -selection clipboard`, `xsel --clipboard --input`, `clip.exe`, `clip`). For `osc52` it buffers stdin, base64-encodes, and wraps in a tmux DCS pass-through when `$TMUX` is set. It writes the escape sequence to `/dev/tty`, so it stays out of the JSON-RPC channel. When `CLIPBOARD_COPY_OSC52_DIR` is set to a non-empty value, it hands the sequence off instead. That path runs only with `CLIPBOARD_COPY_HOST=pi`; another host is refused, and an empty value counts as unset. On that path it needs `bytes`, and refuses a missing count. It derives the base64 length from the byte count before running an encoder. See [OSC 52 on Pi](pi.md#osc-52-on-pi). An unknown backend name is refused with `Error: unknown clipboard backend: <id>`. Returns 1 if `/dev/tty` is not writable in OSC 52 mode.

#### `_clipboard_check_handoff_dir(dir)` (in `lib/clipboard.sh`)
Requires an absolute `dir` that equals its own physical path (`pwd -P`). A symlink, a trailing slash, a `.` component, and a doubled slash are all refused. The checks run in this order: absolute, exists, directory, canonical, owned by the current user, and not writable by group or others. Returns 1 with an `Error: CLIPBOARD_COPY_OSC52_DIR …` message on stderr naming the value when a check fails. The write-bit check uses `find -perm`, since GNU and BSD `stat` print modes differently.

#### `_clipboard_owned_by_current_user(dir)` (in `lib/clipboard.sh`)
Returns 0 when the current user owns `dir`. `_clipboard_check_handoff_dir` calls it; a test overrides it in a child shell to exercise that refusal without root.

#### `_clipboard_osc52_handoff(seq)` (in `lib/clipboard.sh`)
Checks `CLIPBOARD_COPY_OSC52_DIR` with `_clipboard_check_handoff_dir`, then writes `seq` to a new file `osc52.XXXXXXXX` created by `mktemp` under `umask 077`. Leaves the new path in `_CLIPBOARD_HANDOFF_FILE` for `_clipboard_handoff_note`; no file under `MCP_CALL_TMPDIR` records it. Every failure prints an error on stderr and returns 1, and a failure after the file exists also removes it. A call cancelled or killed after the file is written leaves the file until the session's handoff directory is removed at session end. The size cap is checked by `_clipboard_write_backend` before this function runs.

#### `_clipboard_handoff_note()` (in `lib/clipboard.sh`)
Prints `OSC 52 handoff: <file name>` from `_CLIPBOARD_HANDOFF_FILE` when the same shell created a handoff file, and nothing otherwise. Both tool functions call it after their copy summary, so the marker is the result's last line, where the Pi extension looks for it. Always returns 0; removing the handoff file is the extension's job.

#### `_clipboard_send_stdin(backend, bytes)` (in `lib/clipboard.sh`)
Runs `_clipboard_write_backend` with the byte count. Its stderr goes to `backend-stderr` in `MCP_CALL_TMPDIR`, the per-call directory the core exports and removes when the call ends. The core merges a tool's stderr into the tool result, so the redirect keeps backend chatter out of it. When the backend exits 0 the captured stderr is dropped unread. When it exits non-zero the function prints `Error: backend <backend> failed with status <N>: <stderr>` and returns 1, which the core reports as an `isError` result; it also returns 1 when the capture file cannot be read. Returns 1 without running the backend when `MCP_CALL_TMPDIR` is unset.

#### `tool_clipboard_copy(args)` (in `lib/clipboard.sh`)
Checks with `jq -e` that `.text` is a non-empty string: a missing `text` or `""` is an error, while text made only of newlines or NUL bytes is copied. A jq failure is an error too. Writes the string's bytes with `jq -j '.text'` to `text` in `MCP_CALL_TMPDIR`, so NUL bytes and trailing newlines survive, and returns 1 when `MCP_CALL_TMPDIR` is unset. Picks a backend, redirects that file into `_clipboard_send_stdin`, and emits `Copied N bytes to clipboard via <backend>`. N is `wc -c` of that file, the bytes sent, so it does not depend on the locale.

#### `tool_clipboard_copy_file(args)` (in `lib/clipboard.sh`)
Reads `.path` from the JSON args. Validates that the path is non-empty, exists, is a regular file (rejects directories and special files), and is readable. The absolute-path rule is not checked here: the `"pattern": "^/"` in `tools.json` rejects a relative path before the function runs. Picks a backend, redirects the file directly into `_clipboard_send_stdin`, and emits `Copied N bytes from <path> to clipboard via <backend>`. Size is read with `wc -c < "$path" | tr -d ' '` for portability between BSD and GNU `wc`.

#### `run_mcp_server` (in `shared/mcpserver_core.sh`)
JSON-RPC 2.0 stdio loop from the vendored `shopwareLabs/bash-mcp-sdk` core; the pinned release is in `.mcp-sdk.lock` at the repository root, and the file is replaced only through `.github/scripts/vendor-mcp-sdk.sh`. Handles `initialize`, `tools/list`, `tools/call`, `ping`, `notifications/initialized`, and `notifications/cancelled`. A `tools/call` runs `tool_<name>` only when `tools.json` declares `<name>`; an undeclared name, or a declared one with no function, returns JSON-RPC error -32601. Arguments are checked against the tool's `inputSchema` first, and a mismatch returns an `isError` result without running the tool. Each call runs in its own subshell and process group, with stdin from `/dev/null`.

### SessionStart hook (`hooks/`)

#### `session-start.sh` (entry point)
Drains stdin, locates `hooks/prompts/mcp-tool-directives.md` relative to its own path, JSON-encodes it via `jq -Rs '.'`, and emits a `hookSpecificOutput.additionalContext` object on stdout so the host agent can splice the directive into conversation context at session start. Exits 1 with an error on stderr when the prompt file is missing, naming its path, and when `jq` is unavailable. With `CLIPBOARD_COPY_HOST=pi` it appends a blank line and `hooks/prompts/host-pi.md` before encoding, and exits 1 when that file is missing. Any other non-empty `CLIPBOARD_COPY_HOST` exits 1 with a message naming the value, before the prompt file is read. `validate_clipboard_host` in `lib/common.sh` prints that message for both scripts. The directive itself (`hooks/prompts/mcp-tool-directives.md`) is static: clipboard-copy has no per-project config.

### PreToolUse hook (`hooks/`)

#### `parse_hook_input()` (in `scripts/lib/common.sh`)
Reads the hook input JSON from stdin, extracts `.tool_input.command` into the `COMMAND` global, and exits 0 (allow) when the command is empty.

#### `validate_clipboard_host()` (in `scripts/lib/common.sh`)
Rejects any `CLIPBOARD_COPY_HOST` other than `pi` or unset with `clipboard-copy: unsupported CLIPBOARD_COPY_HOST "<value>"; expected pi or unset` on stderr, then exits 1. Both entry scripts call it and so print the same message.

#### `block_clipboard(tool, hint)` (in `scripts/lib/common.sh`)
Writes a host-neutral block message to stderr and exits 2 (deny). The message includes the offending command, the suggested MCP tool, the supplied hint, and a generic explanation of why the MCP path is preferred. With `CLIPBOARD_COPY_HOST=pi` it prefixes the tool names in the tool and the hint with `mcp__clipboard_copy__`, the way Pi names them. An already-qualified name is left as it is, so it is never prefixed twice. In the hint only a bare `clipboard_copy` is qualified. Unset or empty keeps the default wording.

#### `check-clipboard.sh` (entry point)
Sources `lib/common.sh`, calls `parse_hook_input`, then calls `validate_clipboard_host`, so an unsupported `CLIPBOARD_COPY_HOST` exits 1 for every command with content, clipboard write or not. An empty command is allowed before the host is read. It then runs a series of grep -E checks against `$COMMAND`. Blocks `pbcopy`, `wl-copy`, `clip.exe`, and `clip` at the start of any command segment (`^|;|&&|\|`). For `xclip` / `xsel`, a paste flag must follow the same tool name within one segment; `xsel -o` cannot excuse `xclip -i`. A paste-mode invocation anywhere in the command allows every invocation of that same tool: `xclip -i < f; xclip -o` is allowed.

### Pi extension (`pi/`)

#### `clipboardCopy(pi)` (default export of `pi/index.ts`)
On `session_start` it creates the OSC 52 handoff directory (`mkdtemp` under the system temp directory, mode 700) and registers `mcp-server-clipboard/server.sh` as MCP server `clipboard-copy`. Registration uses `exposure: "deferred"` and the env `CLIPBOARD_COPY_HOST=pi`, `CLIPBOARD_COPY_OSC52_DIR=<dir>` (with `$` escaped as `$$`, since Pi expands `$NAME` in env values). Loading the extension alone creates nothing. Its handlers:

- `session_start` creates the directory and registers the server. It then runs `hooks/scripts/session-start.sh` and keeps its `additionalContext`; a failure, a 5-second timeout, or unusable output leaves no directive and shows a warning.
- `before_agent_start` sets the system prompt section `clipboard_copy` to the directive.
- `tool_call` runs `hooks/scripts/check-clipboard.sh` through `runGate` for the `bash` tool only. See [Pi Bash check](pi.md#bash-check) for failure behavior.
- `tool_result` acts on a successful `clipboard_copy` or `clipboard_copy_file` result whose last line is `OSC 52 handoff: osc52.XXXXXXXX`, and replaces the result with `handBack`'s. Before the session starts there is no handoff directory, so a handoff line then becomes an error result naming that.
- `session_shutdown` removes the handoff directory when the session created one.

#### `handBack(dir, name, summary, ctx)` (in `pi/index.ts`)
Opens the handoff file with `O_NOFOLLOW` and `O_NONBLOCK`, then checks with `fstat` that it is a regular file owned by the current user. A symlink at the name fails instead of being followed out of `dir`, and a FIFO opens at once instead of waiting for a writer, then fails the regular-file check. The name pattern admits no path separator, so the joined path is a direct child and no containment check is needed. Reads the sequence through the descriptor, closes it in `finally`, then deletes the file by name. It writes the sequence to `process.stdout` and returns `summary` as the result. When the open, type, ownership, or read check fails, it first removes whatever is at the name. That is nothing when there is no entry, `rmdir` for a directory, and otherwise unlink without following a link. A removal that fails is appended to the error as `; removing it failed too: <reason>`. Returns an error result, with nothing written, when the file cannot be opened or read. It does the same when the file holds no OSC 52 sequence (plain or tmux-wrapped), `ctx.mode` is not `"tui"`, or stdout is not a TTY. The `tool_result` handler turns a thrown error into an error result too, because Pi drops a handler's exception and keeps the original result.

#### `runScript(script, input, timeoutMs, kill)` / `runGate(script, input, timeoutMs)` (in `pi/gate.ts`)
`runScript` runs `bash <script>` in its own process group with `input` as JSON on stdin and `CLIPBOARD_COPY_HOST=pi` added to the environment. It never rejects: a failed spawn or the timeout resolves with `code: null`. The timeout kills the whole process group with `kill`, an optional parameter that defaults to `process.kill`. A kill error other than `ESRCH` is reported as `killFailure`, which the failure description appends. `runGate` maps exit 2 to a block with the trimmed stderr as the reason, or a fixed reason when that is blank. Exit 0 allows. Anything else blocks with a `failure` description.

