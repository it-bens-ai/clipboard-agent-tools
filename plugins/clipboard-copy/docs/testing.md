# Testing

BATS suites for the server and hooks live in `plugin-tests/clipboard-copy/`, and Node tests for the Pi extension in `plugin-tests/clipboard-copy/pi/`. Paths below are relative to `plugin-tests/clipboard-copy/`.

## Running the suites

Setup and the full check list are in [Development](https://github.com/it-bens-ai/clipboard-agent-tools/blob/main/docs/development.md#testing). To run one area, filter by its file tag from the repository root:

```bash
.bats/bats-core/bin/bats --filter-tags hook plugin-tests/clipboard-copy/*.bats
```

Each suite carries the file tag `clipboard-copy` plus one area tag: `hook`, `detect`, `tool`, `startup`, `dispatch`, `tool-schemas`, `server`, `send`, `plugin-launch`, `session-start`, `osc52`, or `pi-e2e`. Individual tests carry finer tags such as `block`, `allow`, and `validate`, which `--filter-tags` accepts as well.

## Suites

- `check_clipboard.bats` — the PreToolUse block/allow matrix, chaining and false-positive guards, the block message per `CLIPBOARD_COPY_HOST`, the unsupported-host exit, and the empty command.
- `detect_backend.bats` — the `_clipboard_detect_backend` cascade across OS, installed utilities, and display variables.
- `tool_clipboard_copy_file.bats` — every path-validation branch and byte-exact capture on success, with `_clipboard_send_stdin` stubbed; smoke-checks `tool_clipboard_copy` text validation.
- `server_startup_tools_list.bats` — startup refuses a missing, invalid, multi-document, or wrongly shaped tool list.
- `tool_dispatch_declaration.bats` — an undeclared sourced tool cannot dispatch; a declared one can.
- `tool_schemas.bats` — required fields against properties, and the SDK validator with valid and missing arguments.
- `server_tools_call.bats` — `tools/call` through `server.sh`: schema refusals, result text, newline and NUL bytes reaching the backend, UTF-8 byte counts, and backend stderr on success and failure.
- `send_stdin.bats` — `_clipboard_send_stdin` and `_clipboard_b64`: encoder failures, unreadable stderr capture, and a missing `MCP_CALL_TMPDIR`.
- `plugin_launch.bats` — the Codex MCP launcher and its `initialize`, and the plugin-root resolution of the hook launchers in `hooks/hooks.json`.
- `session_start.bats` — the JSON shape, the directive content, the failure paths, and the output per `CLIPBOARD_COPY_HOST`.
- `osc52_handoff.bats` — the handoff through `server.sh` with a `uname` shim forcing `osc52`: file contents and mode, the size cap, every directory refusal, the host check, and cleanup after failures.
- `pi_e2e.bats` — the real Pi binary (`node_modules/.bin/pi`) offline with a scripted model (`fixtures/pi/driver.ts`) and a stubbed `pbcopy`. Scenarios: `deferred` (Git-clone and `npm pack` layouts), `osc52`, and `tui` under a pseudo-terminal.
- `pi/gate.test.ts` — `runScript` and `runGate`: input, environment, exit statuses, a missing script, blank stderr, the timeout, and kill failures.
- `pi/index.test.ts` — the extension against a fake Pi (`pi/fake-pi.ts`) and Pi's own validators (`pi/pi-internals.ts`): registration, directive, Bash check failures, and every `handBack` outcome.
- `pi/tool-search-ranking.test.ts` — Pi's `tool_search` ranks each tool first for its bare and Pi name.
- `pi/temporary-directory.ts` — `makeTemporaryDirectory(t)`, a per-test temp directory the Node test files import.

`pi_e2e.bats` skips without `npm ci`. It needs GNU `timeout` or `gtimeout`, and a `script` that takes a command (BSD) or `-c` (util-linux).

## Mocking

`test_helper/backend_setup.bash` provides `backend_set os=... pbcopy=1 xclip=0 ...` for PATH-based mocking. It restricts PATH to the mock dir alone (so `command -v pbcopy` is deterministic on macOS where the real binary lives in `/usr/bin`) and captures absolute paths to `cat`/`chmod`/`rm`/`uname` for its own use. `backend_write_uname_stub <dir> <os>` writes the same `uname` shim into another directory. Call `backend_setup_init` in `setup()` and `backend_setup_cleanup` in `teardown()`.

`test_helper/server_request.bash` provides `call_tool <tool> <args-json>`, which sends one `tools/call` request to the `SERVER` path the suite sets and keeps the JSON-RPC response.

## Manual smoke tests

Run these from `plugins/clipboard-copy/`. The MCP server is a stdio process, so hand-crafted JSON-RPC drives it:

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

## Codex smoke test

After installing the Codex plugin and restarting Codex, the tools appear under `mcp__clipboard_copy`; a verified local install returned `Copied N bytes to clipboard via pbcopy` for `clipboard_copy`.
