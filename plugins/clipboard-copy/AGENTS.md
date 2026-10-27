@README.md

## Compatibility Contract

This plugin must remain compatible with Claude Code, Codex, and Pi.

- Claude Code uses `.claude-plugin/plugin.json` and `.mcp.json`.
- Codex uses `.codex-plugin/plugin.json` and the repo marketplace at `.agents/plugins/marketplace.json`.
- The MCP server implementation, hook scripts, and `hooks/prompts/mcp-tool-directives.md` are shared.
- Keep `hooks/hooks.json` compatible with both runtimes. Resolve the plugin root from Codex's `PLUGIN_ROOT` or Claude Code's `CLAUDE_PLUGIN_ROOT`, and fail when neither is available; do not probe cwd-relative fallback paths.
- Do not replace Claude-specific files while adding Codex support. Codex files are additive.
- Pi loads `pi/index.ts` through the root `package.json`. The extension registers the server and runs the hook scripts itself, so `.mcp.json` and `hooks/hooks.json` are not on the Pi path. It runs the shared server and hook scripts with `CLIPBOARD_COPY_HOST=pi`; Pi-specific wording goes in `hooks/prompts/host-pi.md` or behind that variable, never into the shared directive.

## Directory & File Structure

```
plugins/clipboard-copy/
├── README.md
├── AGENTS.md
├── CHANGELOG.md
├── .claude-plugin/
│   └── plugin.json                  # Claude Code plugin manifest
├── .codex-plugin/
│   └── plugin.json                  # Codex plugin manifest and MCP server declaration
├── .mcp.json                        # Claude Code MCP registration
├── pi/
│   ├── index.ts                     # Pi extension entry point (named in the root package.json)
│   └── gate.ts                      # runScript / runGate: run a hook script, map its exit code
├── shared/
│   └── mcpserver_core.sh            # JSON-RPC 2.0 stdio handler, vendored from bash-mcp-sdk (do not edit)
├── mcp-server-clipboard/
│   ├── server.sh                    # MCP entry point (referenced from .mcp.json)
│   ├── config.json                  # protocolVersion, serverInfo, capabilities for initialize
│   ├── tools.json                   # Tool schemas returned by tools/list
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

## Key Functions

### MCP server (`mcp-server-clipboard/`)

#### `_clipboard_detect_backend()` (in `lib/clipboard.sh`)
Echoes the backend name for the current environment. Resolution order, scoped to `uname -s`:

- **Darwin** → `pbcopy` → `osc52`
- **Linux** → `clip.exe` (WSL) → `wl-copy` (Wayland) → `xclip` / `xsel` (X11) → `wl-copy`/`xclip`/`xsel` again as a headless fallback → `osc52`
- **CYGWIN/MINGW/MSYS** → `clip` → `osc52`
- everything else → `osc52`

Pure function; no side effects.

#### `_clipboard_b64()` (in `lib/clipboard.sh`)
Base64-encodes stdin without line wraps. Uses `base64 -w 0` when GNU base64 is available, falls back to `base64 | tr -d '\r\n'` for BSD/macOS, and to `openssl base64 -A` if neither is present. A failing `base64` or `openssl` returns non-zero instead of an empty payload. The server already runs with `pipefail`; the function sets it again, scoped by `local -`, so the BSD pipeline keeps base64's status when `lib/clipboard.sh` is sourced on its own, as the tests do. Returns 1 if neither is reachable.

#### `_clipboard_write_backend(backend, bytes)` (in `lib/clipboard.sh`)
Reads stdin and dispatches to the right utility (`pbcopy`, `wl-copy`, `xclip -selection clipboard`, `xsel --clipboard --input`, `clip.exe`, `clip`). For `osc52` it buffers stdin, base64-encodes, and wraps in a tmux DCS pass-through when `$TMUX` is set. It writes the escape sequence to `/dev/tty`, so it stays out of the JSON-RPC channel. When `CLIPBOARD_COPY_OSC52_DIR` is set to a non-empty value, it hands the sequence off instead. That path runs only with `CLIPBOARD_COPY_HOST=pi`; another host is refused, and an empty value counts as unset. On that path it needs `bytes`, and refuses a missing count. It derives the base64 length from the byte count and refuses a payload over 100000 characters before any encoder runs. An unknown backend name is refused with `Error: unknown clipboard backend: <id>`. Returns 1 if `/dev/tty` is not writable in OSC 52 mode.

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
Writes a host-neutral block message to stderr and exits 2 (deny). The message includes the offending command, the suggested MCP tool, the supplied hint, and a generic explanation of why the MCP path is preferred. Keep this text free of Claude-only or Codex-only terminology. With `CLIPBOARD_COPY_HOST=pi` it prefixes the tool names in the tool and the hint with `mcp__clipboard_copy__`, the way Pi names them. An already-qualified name is left as it is, so it is never prefixed twice. In the hint only a bare `clipboard_copy` is qualified. Unset or empty keeps the default wording.

#### `check-clipboard.sh` (entry point)
Sources `lib/common.sh`, calls `parse_hook_input`, then calls `validate_clipboard_host`, so an unsupported `CLIPBOARD_COPY_HOST` exits 1 for every command with content, clipboard write or not. An empty command is allowed before the host is read. It then runs a series of grep -E checks against `$COMMAND`. Blocks `pbcopy`, `wl-copy`, `clip.exe`, and `clip` at the start of any command segment (`^|;|&&|\|`). Blocks `xclip` / `xsel` only when no paste flag (`-o` / `-out` / `--output`) is present in the same segment — `[^|;&]*` keeps the lookup scoped so a later `xsel -o` cannot excuse an earlier `xclip -i`.

### Pi extension (`pi/`)

#### `clipboardCopy(pi)` (default export of `pi/index.ts`)
On `session_start` it creates the OSC 52 handoff directory (`mkdtemp` under the system temp directory, mode 700) and registers `mcp-server-clipboard/server.sh` as MCP server `clipboard-copy`. Registration uses `exposure: "deferred"` and the env `CLIPBOARD_COPY_HOST=pi`, `CLIPBOARD_COPY_OSC52_DIR=<dir>` (with `$` escaped as `$$`, since Pi expands `$NAME` in env values). Loading the extension alone creates nothing. Its handlers:

- `session_start` creates the directory and registers the server. It then runs `hooks/scripts/session-start.sh` and keeps its `additionalContext`; a failure, a 5-second timeout, or unusable output leaves no directive and shows a warning.
- `before_agent_start` sets the system prompt section `clipboard_copy` to the directive.
- `tool_call` runs `hooks/scripts/check-clipboard.sh` through `runGate` for the `bash` tool only. Exit 2 blocks with the script's stderr as the reason. An exit 2 with blank stderr blocks with a fixed reason saying the check gave none. Any other failure also blocks, with a reason naming the failure, and warns. That covers exit 1 for an unsupported `CLIPBOARD_COPY_HOST`, the 127 a missing `jq` on Pi's `PATH` produces, the 5-second timeout, or a failed spawn. So when the clipboard check cannot run, every `bash` call on Pi is blocked rather than let through.
- `tool_result` acts on a successful `clipboard_copy` or `clipboard_copy_file` result whose last line is `OSC 52 handoff: osc52.XXXXXXXX`, and replaces the result with `handBack`'s. Before the session starts there is no handoff directory, so a handoff line then becomes an error result naming that.
- `session_shutdown` removes the handoff directory when the session created one.

#### `handBack(dir, name, summary, ctx)` (in `pi/index.ts`)
Opens the handoff file with `O_NOFOLLOW` and `O_NONBLOCK`, then checks with `fstat` that it is a regular file owned by the current user. A symlink at the name fails instead of being followed out of `dir`, and a FIFO opens at once instead of waiting for a writer, then fails the regular-file check. The name pattern admits no path separator, so the joined path is a direct child and no containment check is needed. Reads the sequence through the descriptor, closes it in `finally`, then deletes the file by name. It writes the sequence to `process.stdout` and returns `summary` as the result. When the open, type, ownership, or read check fails, it first removes whatever is at the name. That is nothing when there is no entry, `rmdir` for a directory, and otherwise unlink without following a link. A removal that fails is appended to the error as `; removing it failed too: <reason>`. Returns an error result, with nothing written, when the file cannot be opened or read. It does the same when the file holds no OSC 52 sequence (plain or tmux-wrapped), `ctx.mode` is not `"tui"`, or stdout is not a TTY. The `tool_result` handler turns a thrown error into an error result too, because Pi drops a handler's exception and keeps the original result.

#### `runScript(script, input, timeoutMs, kill)` / `runGate(script, input, timeoutMs)` (in `pi/gate.ts`)
`runScript` runs `bash <script>` in its own process group with `input` as JSON on stdin and `CLIPBOARD_COPY_HOST=pi` added to the environment. It never rejects: a failed spawn or the timeout resolves with `code: null`. The timeout kills the whole process group with `kill`, an optional parameter that defaults to `process.kill`. A kill error other than `ESRCH` is reported as `killFailure`, which the failure description appends. `runGate` maps exit 2 to a block with the trimmed stderr as the reason, or a fixed reason when that is blank. Exit 0 allows. Anything else blocks with a `failure` description.

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

## MCP Wire Flow

1. Claude Code spawns `mcp-server-clipboard/server.sh` per `.mcp.json`; Codex spawns the same server through `.codex-plugin/plugin.json`.
2. `server.sh` exports `MCP_CONFIG_FILE`, `MCP_TOOLS_LIST_FILE`, `MCP_LOG_STDERR=1`, and sources `mcpserver_core.sh` + `lib/clipboard.sh`. Before `run_mcp_server`, it requires `tools.json` to contain exactly one JSON object with a `tools` array; a missing or invalid list exits non-zero and prints an error to stderr.
3. The loop reads JSON-RPC requests one per line on stdin and writes responses on stdout. Log lines go to stderr; a `MCP_LOG_FILE` set in the host environment also receives them. The core merges a tool call's stderr into the tool result, so the tool functions and the helpers they call do not log.
4. `tools/call clipboard_copy` → `tool_clipboard_copy` → `_clipboard_send_stdin <backend>` → `_clipboard_write_backend <backend>` → backend utility or OSC 52 escape to `/dev/tty`.
5. On Pi, `pi/index.ts` registers the server on `session_start` and sets `CLIPBOARD_COPY_OSC52_DIR`. The OSC 52 escape goes to a handoff file instead of `/dev/tty`, `_clipboard_handoff_note` names it on the result's last line, and the extension's `tool_result` handler writes it to Pi's terminal.

## Codex Smoke Test

After installing the Codex plugin and restarting Codex, the MCP tools should be discoverable as clipboard-copy tools. A verified local install exposed them under `mcp__clipboard_copy` and successfully returned `Copied N bytes to clipboard via pbcopy` for `clipboard_copy`.

## Testing

BATS tests live in `plugin-tests/clipboard-copy/`, and Node tests for the Pi extension in `plugin-tests/clipboard-copy/pi/`:

```bash
# Setup (first time only)
./.github/scripts/setup-bats.sh

# Run all clipboard-copy tests
.bats/bats-core/bin/bats plugin-tests/clipboard-copy/*.bats

# Filter by tag
.bats/bats-core/bin/bats --filter-tags hook          plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags detect        plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags tool          plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags block         plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags allow         plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags validate      plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags session-start plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags server        plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags send          plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags plugin-launch plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags osc52         plugin-tests/clipboard-copy/*.bats
.bats/bats-core/bin/bats --filter-tags pi-e2e        plugin-tests/clipboard-copy/*.bats

# Pi extension (run from the repository root after npm ci)
npm test
```

Files:

- `check_clipboard.bats` — block/allow matrix for the PreToolUse hook (pbcopy/wl-copy/clip/clip.exe/xclip/xsel × direct/piped/chained, plus paste-mode and false-positive guards). Also the block message per `CLIPBOARD_COPY_HOST`: unprefixed when unset, Pi names for `pi`, and an already-qualified tool name left single-prefixed. An unsupported host exits 1 with the message naming the value, on a clipboard write and on an unrelated command alike. An empty command is allowed first.
- `detect_backend.bats` — `_clipboard_detect_backend` cascade across OS × installed-utility × WAYLAND_DISPLAY/DISPLAY combinations.
- `tool_clipboard_copy_file.bats` — every path-validation branch in the function (missing/empty/nonexistent/directory/unreadable) plus byte-exact dispatcher capture for the success path. Smoke-checks `tool_clipboard_copy` text validation too.
- `server_startup_tools_list.bats` — checks startup rejects missing, invalid, multi-document, and wrongly shaped tool lists before answering requests.
- `tool_dispatch_declaration.bats` — checks that an undeclared sourced tool cannot dispatch while a declared tool can.
- `tool_schemas.bats` — checks required fields against properties and calls the SDK validator with valid and missing arguments for both tools.
- `server_tools_call.bats` — drives `server.sh` with JSON-RPC `tools/call` requests: schema refusals (relative path, undeclared argument, wrong type) return `isError` without running the tool, and an absolute path reaches a stubbed backend. Also covers a result text holding only the copy summary for both tools, trailing-newline, newline-only, NUL-containing and NUL-only text reaching the backend byte for byte, UTF-8 byte counts for both tools, a succeeding backend's stderr kept out of the result, and a failing backend's status and stderr returned as `isError`.
- `send_stdin.bats` — `_clipboard_send_stdin` and `_clipboard_b64` on their own: the OSC 52 branch's encoder error comes back as a failure with its message, an unreadable stderr capture fails a call only when the backend failed, a call without `MCP_CALL_TMPDIR` is refused before the backend runs, and a failing `base64` or `openssl` fails the encoder.
- `plugin_launch.bats` — Codex MCP launcher shape and its `initialize` from the declared cwd, and the hook launchers in `hooks/hooks.json`: they resolve the plugin root from `PLUGIN_ROOT` or `CLAUDE_PLUGIN_ROOT` only, and fail when the host sets neither.
- `session_start.bats` — JSON shape (`hookEventName`, non-empty `additionalContext`), directive content (ALWAYS/NEVER framing, both tool names, every blocked Bash command, paste-mode escape hatch), plus the failing paths when the prompt template or `jq` is missing. Also covers `CLIPBOARD_COPY_HOST`: unset or empty emits the shared directive alone, `pi` appends the addendum after a blank line, another value fails, and `pi` with a missing addendum fails.
- `osc52_handoff.bats` — drives `server.sh` with `CLIPBOARD_COPY_OSC52_DIR` set and a `uname` shim that forces `osc52`. The result's last line names the handoff file, and the file holds the plain or tmux-wrapped sequence with owner-only permissions. The 100000-character payload limit holds for both tools and is checked before either encoder runs. A non-canonical directory is refused: a symlink, a trailing slash, a `.` component, a doubled slash, or a relative path. A missing or non-directory path is refused too, as is one not owned by the current user, group- or other-writable, unreadable, or unwritable. A set variable without `CLIPBOARD_COPY_HOST=pi` is refused. Without the variable, or with it empty, the sequence goes to `/dev/tty`. Sourcing the library separately, it forces a failed sequence write and an unknown backend. It checks that each failure removes the handoff file or writes nothing.
- `pi_e2e.bats` — tagged `pi-e2e`. Runs the real Pi binary (`node_modules/.bin/pi`) offline with a scripted model (`fixtures/pi/driver.ts`) and a stubbed `pbcopy`. The `deferred` scenario runs against a Git-clone layout and an `npm pack` layout of the package. `tool_search` loads each tool, both tools reach the backend, `printf | pbcopy` is blocked, and the first request carries both the `clipboard_copy` section and the Pi addendum. With no native backend, the OSC 52 fallback fails in JSON mode with the exact error, and its handoff file is gone before session shutdown. The `tui` scenario runs interactive Pi under a pseudo-terminal (`script`) with no native backend. The OSC 52 sequence reaches the terminal, and the model sees the copy summary. The handoff file is gone before shutdown, and the handoff directory is gone after it. It uses the Git-clone layout. `backend_write_uname_stub` from `test_helper/backend_setup.bash` writes the `uname` shim. Skips without `npm ci`; needs GNU `timeout` or `gtimeout`, and a `script` that takes a command (BSD) or `-c` (util-linux).
- `pi/gate.test.ts` — `runScript` and `runGate`: stdin and environment, exit 0, 2, and other statuses, a missing script, and a gate that exits without reading its input. Also an exit 2 with blank stderr, and a timeout that kills background children. A kill that fails after the timeout is covered too: ESRCH stays quiet, another error is reported.
- `pi/index.test.ts` — the extension against a fake Pi (`pi/fake-pi.ts`) and Pi's own validators (`pi/pi-internals.ts`). Covers loading creating nothing, server registration on `session_start`, the handoff directory and its removal, and the directive section. A failing or timed-out check blocks the bash call with the exact reason, and `powershell` is not checked. Also the `handBack` outcomes for a written sequence, no terminal on stdout, a file without a sequence, and a symlink inside or outside the directory. The refused entries covered are a FIFO and an empty directory, which are removed, and a non-empty directory, whose removal fails and is named in the error. A name that is not a regular file, or is missing, is an error too. A handoff line before the session started is an error. The directory is asserted owner-only even under a umask that clears owner bits. One test writes a handoff with the real server library and feeds it to the handler. The tool names it accepts come from `tools.json` through Pi's own name builder.
- `pi/tool-search-ranking.test.ts` — Pi's `tool_search` ranks each tool first for its bare name and for its Pi name, and the server description shares no search term with a tool name.
- `pi/temporary-directory.ts` — `makeTemporaryDirectory(t)` creates a directory under the system temp directory and removes it after the test; the three Node test files import it.

### Mocking

`plugin-tests/clipboard-copy/test_helper/backend_setup.bash` provides `backend_set os=... pbcopy=1 xclip=0 ...` for PATH-based mocking. It restricts PATH to the mock dir alone (so `command -v pbcopy` is deterministic on macOS where the real binary lives in `/usr/bin`) and captures absolute paths to `cat`/`chmod`/`rm`/`uname` for its own use. `backend_write_uname_stub <dir> <os>` writes the same `uname` shim into another directory. Call `backend_setup_init` in `setup()` and `backend_setup_cleanup` in `teardown()`.

`plugin-tests/clipboard-copy/test_helper/server_request.bash` provides `call_tool <tool> <args-json>`, which sends one `tools/call` request to the `SERVER` path the suite sets and keeps the JSON-RPC response. `server_tools_call.bats` and `osc52_handoff.bats` load it.

The `tool_clipboard_copy_file.bats` suite stubs `_clipboard_send_stdin` to capture bytes to a tempfile rather than touching the real clipboard, so the success path is verified without depending on any platform utility being installed.

## Manual Smoke Test

The MCP server is just a stdio process — drive it with hand-crafted JSON-RPC:

```bash
SERVER=./mcp-server-clipboard/server.sh

# Initialize + list + copy
{
  jq -c -n '{jsonrpc:"2.0",id:1,method:"initialize",params:{}}'
  jq -c -n '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}'
  jq -c -n '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"clipboard_copy",arguments:{text:"hello"}}}'
} | "$SERVER" | jq -c .

pbpaste   # macOS: should show "hello"

# clipboard_copy_file end-to-end
echo "from disk" > /tmp/cliptest.txt
jq -c -n --arg p /tmp/cliptest.txt \
  '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"clipboard_copy_file",arguments:{path:$p}}}' \
  | "$SERVER" | jq -c .
pbpaste
rm /tmp/cliptest.txt
```

Drive the hook with synthetic PreToolUse JSON:

```bash
HOOK=./hooks/scripts/check-clipboard.sh

# Expect exit 2 + block message on stderr
printf '%s' '{"tool_input":{"command":"echo hi | pbcopy"}}' | bash "$HOOK"

# Expect exit 0 (allow) for paste reads and unrelated commands
printf '%s' '{"tool_input":{"command":"xclip -o > out.txt"}}' | bash "$HOOK"
printf '%s' '{"tool_input":{"command":"git status"}}'         | bash "$HOOK"
```
