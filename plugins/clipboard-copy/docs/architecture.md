# Architecture

The plugin is one Bash MCP server, two hook scripts with their prompt files, and a Pi extension. Claude Code, Codex, and Pi share the server, the hook scripts, and the directive prompt; the repository's [Development](https://github.com/it-bens-ai/clipboard-agent-tools/blob/main/docs/development.md#hosts) guide lists which manifest each host reads.

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
│   ├── index.ts                     # Pi extension entry point (named in the root package.json)
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

## MCP wire flow

1. Claude Code spawns `mcp-server-clipboard/server.sh` per `.mcp.json`, Codex through `.codex-plugin/plugin.json`, and Pi from `pi/index.ts` on `session_start`.
2. `server.sh` exports `MCP_CONFIG_FILE`, `MCP_TOOLS_LIST_FILE`, `MCP_LOG_STDERR=1`, sources `mcpserver_core.sh` + `lib/clipboard.sh`, and checks `tools.json` before `run_mcp_server` (see [Argument validation](tools.md#argument-validation)).
3. The loop reads JSON-RPC requests one per line on stdin and writes responses on stdout. Log lines go to stderr; a `MCP_LOG_FILE` set in the host environment also receives them. The core merges a tool call's stderr into the tool result, so the tool functions and the helpers they call do not log.
4. `tools/call clipboard_copy` → `tool_clipboard_copy` → `_clipboard_send_stdin <backend>` → `_clipboard_write_backend <backend>` → backend utility or OSC 52 escape to `/dev/tty`, or on Pi to a handoff file (see [OSC 52 on Pi](pi.md#osc-52-on-pi)).

## Key functions

### MCP server (`mcp-server-clipboard/`)

#### `_clipboard_detect_backend()` (in `lib/clipboard.sh`)
Echoes a backend name with no side effects, in the [Detection order](backends.md#detection-order).

#### `_clipboard_b64()` (in `lib/clipboard.sh`)
Base64-encodes stdin without line wraps: `base64 -w 0` (GNU), `base64 | tr -d '\r\n'` (BSD/macOS), else `openssl base64 -A`. Returns 1 when the encoder fails or neither is reachable. It sets `pipefail` scoped by `local -`, so the BSD pipeline keeps base64's status when `lib/clipboard.sh` is sourced on its own, as the tests do.

#### `_clipboard_write_backend(backend, bytes)` (in `lib/clipboard.sh`)
Pipes stdin to the backend utility (`pbcopy`, `wl-copy`, `xclip -selection clipboard`, `xsel --clipboard --input`, `clip.exe`, `clip`). For `osc52` it builds the sequence, tmux-wrapped when `$TMUX` is set, and writes it to `/dev/tty`, or passes it to `_clipboard_osc52_handoff` when `CLIPBOARD_COPY_OSC52_DIR` is non-empty. The handoff path needs `bytes`: it derives the base64 length from the count and applies the size cap before any encoder runs. An unknown backend returns 1 with `Error: unknown clipboard backend: <id>`.

#### `_clipboard_check_handoff_dir(dir)` (in `lib/clipboard.sh`)
Returns 0 when `dir` passes the [OSC 52 on Pi](pi.md#osc-52-on-pi) directory rules, checked in order: absolute, exists, directory, equal to its `pwd -P`, owned by the current user, not writable by group or others. Otherwise prints `Error: CLIPBOARD_COPY_OSC52_DIR …` naming the value on stderr and returns 1. The write-bit check uses `find -perm`, since GNU and BSD `stat` print modes differently.

#### `_clipboard_owned_by_current_user(dir)` (in `lib/clipboard.sh`)
Returns 0 when the current user owns `dir`. A test overrides it in a child shell to exercise that refusal without root.

#### `_clipboard_osc52_handoff(seq)` (in `lib/clipboard.sh`)
Checks `CLIPBOARD_COPY_OSC52_DIR` with `_clipboard_check_handoff_dir`, writes `seq` to a new file `osc52.XXXXXXXX` from `mktemp` under `umask 077`, and leaves its path in `_CLIPBOARD_HANDOFF_FILE`; no file under `MCP_CALL_TMPDIR` records it. Every failure prints an error on stderr and returns 1, and a failure after the file exists removes it. A call killed after the write leaves the file until the session's handoff directory is removed.

#### `_clipboard_handoff_note()` (in `lib/clipboard.sh`)
Prints `OSC 52 handoff: <file name>` when the same shell created a handoff file, and nothing otherwise; always returns 0. Both tool functions call it after their copy summary, so the marker is the result's last line.

#### `_clipboard_send_stdin(backend, bytes)` (in `lib/clipboard.sh`)
Runs `_clipboard_write_backend` with its stderr captured in `backend-stderr` under `MCP_CALL_TMPDIR`, the per-call directory the core exports and removes. On success the capture is dropped unread; on failure it prints the error in [Results](tools.md#results) and returns 1. Also returns 1 when a failing backend's capture cannot be read, and without running the backend when `MCP_CALL_TMPDIR` is unset.

#### `tool_clipboard_copy(args)` (in `lib/clipboard.sh`)
Checks `.text` with `jq -e` against the rule in [`clipboard_copy`](tools.md#clipboard_copy), writes its bytes with `jq -j '.text'` to `text` in `MCP_CALL_TMPDIR` so NUL bytes and trailing newlines survive, and redirects that file into `_clipboard_send_stdin`. N is `wc -c` of that file, so it does not depend on the locale. Returns 1 when jq fails or `MCP_CALL_TMPDIR` is unset.

#### `tool_clipboard_copy_file(args)` (in `lib/clipboard.sh`)
Checks that `.path` is non-empty, exists, is a regular file, and is readable, then redirects the file into `_clipboard_send_stdin`. The absolute-path rule is not checked here: the `"pattern": "^/"` in `tools.json` rejects a relative path before the function runs. Size is read with `wc -c < "$path" | tr -d ' '` for portability between BSD and GNU `wc`.

#### `run_mcp_server` (in `shared/mcpserver_core.sh`)
The vendored SDK loop (see [Vendored MCP SDK](https://github.com/it-bens-ai/clipboard-agent-tools/blob/main/docs/development.md#vendored-mcp-sdk)). Handles `initialize`, `tools/list`, `tools/call`, `ping`, `notifications/initialized`, and `notifications/cancelled`. A `tools/call` runs `tool_<name>` only when `tools.json` declares `<name>`; an undeclared name, or a declared one with no function, returns JSON-RPC error -32601. Arguments are checked against the `inputSchema` first. Each call runs in its own subshell and process group, with stdin from `/dev/null`.

### Hook scripts (`hooks/scripts/`)

#### `session-start.sh` (entry point)
Drains stdin, reads `hooks/prompts/mcp-tool-directives.md` relative to its own path, appends a blank line and `hooks/prompts/host-pi.md` with `CLIPBOARD_COPY_HOST=pi`, encodes the text with `jq -Rs '.'`, and prints a `hookSpecificOutput.additionalContext` object. Failure exits are in [SessionStart directive](hooks.md#sessionstart-directive) and [Unsupported host](hooks.md#unsupported-host).

#### `parse_hook_input()` (in `lib/common.sh`)
Reads the hook input JSON from stdin, puts `.tool_input.command` in the `COMMAND` global, and exits 0 (allow) when it is empty.

#### `validate_clipboard_host()` (in `lib/common.sh`)
Exits 1 with the [Unsupported host](hooks.md#unsupported-host) message for any `CLIPBOARD_COPY_HOST` other than `pi` or unset. Both entry scripts call it.

#### `block_clipboard(tool, hint)` (in `lib/common.sh`)
Writes a host-neutral block message (the command, the MCP tool, the hint, and why the MCP path is preferred) to stderr and exits 2. With `CLIPBOARD_COPY_HOST=pi` it prefixes bare tool names in the tool and the hint with `mcp__clipboard_copy__`; an already-qualified name is never prefixed twice, and in the hint only a bare `clipboard_copy` is qualified.

#### `check-clipboard.sh` (entry point)
Calls `parse_hook_input`, then `validate_clipboard_host`, then matches `$COMMAND` with `grep -E` patterns anchored at segment starts (`^|;|&&|\|`). [Bash enforcement](hooks.md#bash-enforcement) lists what they block.

### Pi extension (`pi/`)

#### `clipboardCopy(pi)` (default export of `pi/index.ts`)
Registers the event handlers; loading the extension alone creates nothing. [Pi](pi.md) describes the behavior.

- `session_start` creates the handoff directory with `mkdtemp` and registers the server as [Tools](pi.md#tools) describes, with `$` in the directory path escaped as `$$`, since Pi expands `$NAME` in env values. It then runs `session-start.sh` and keeps its `additionalContext`.
- `before_agent_start` sets the system prompt section `clipboard_copy` to the directive.
- `tool_call` runs `check-clipboard.sh` through `runGate` for the `bash` tool only.
- `tool_result` passes a successful `clipboard_copy` or `clipboard_copy_file` result whose last line is `OSC 52 handoff: osc52.XXXXXXXX` to `handBack` and returns its result. Before the session starts there is no handoff directory, so a handoff line then becomes an error result naming that.
- `session_shutdown` removes the handoff directory when the session created one.

#### `handBack(dir, name, summary, ctx)` (in `pi/index.ts`)
Opens the handoff file with `O_NOFOLLOW` and `O_NONBLOCK`, then checks with `fstat` that it is a regular file owned by the current user. A symlink at the name fails instead of being followed out of `dir`, and a FIFO opens at once and then fails the regular-file check. The name pattern admits no path separator, so no containment check is needed. Reads through the descriptor, deletes the file, writes the sequence to `process.stdout`, and returns `summary`. When a check fails it first removes whatever is at the name (`rmdir` for a directory, otherwise unlink without following a link) and appends `; removing it failed too: <reason>` when that fails. It returns an error result, with nothing written, when the file holds no OSC 52 sequence (plain or tmux-wrapped), `ctx.mode` is not `"tui"`, or stdout is not a TTY. The `tool_result` handler turns a thrown error into an error result, because Pi drops a handler's exception and keeps the original result.

#### `runScript(script, input, timeoutMs, kill)` / `runGate(script, input, timeoutMs)` (in `pi/gate.ts`)
`runScript` runs `bash <script>` in its own process group with `input` as JSON on stdin and `CLIPBOARD_COPY_HOST=pi` added to the environment. It never rejects: a failed spawn or the timeout resolves with `code: null`. The timeout kills the whole process group with `kill`, which defaults to `process.kill`; a kill error other than `ESRCH` is reported as `killFailure`. `runGate` maps exit 0 to allow, exit 2 to a block with the trimmed stderr as the reason (a fixed reason when it is blank), and anything else to a block with a `failure` description.
