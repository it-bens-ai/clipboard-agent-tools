# Testing

BATS suites for the server and hooks live in `plugin-tests/clipboard-copy/`, and Node tests for the Pi extension in `plugin-tests/clipboard-copy/pi/`. The repository-wide checks that CI runs, including the BATS and ShellCheck setup, are in the repository's [Development](https://github.com/it-bens-ai/clipboard-agent-tools/blob/main/docs/development.md) guide.

## Running the suites

Run these from the repository root:

```bash
# Setup (first time only)
./.github/scripts/setup-bats.sh

# Run all clipboard-copy suites
.bats/bats-core/bin/bats plugin-tests/clipboard-copy/*.bats

# Run one area by its file tag
.bats/bats-core/bin/bats --filter-tags hook plugin-tests/clipboard-copy/*.bats

# Pi extension (after npm ci)
npm test
```

Each suite carries the file tag `clipboard-copy` plus one area tag: `hook`, `detect`, `tool`, `startup`, `dispatch`, `tool-schemas`, `server`, `send`, `plugin-launch`, `session-start`, `osc52`, or `pi-e2e`. Individual tests carry finer tags such as `block`, `allow`, and `validate`, which `--filter-tags` accepts as well.

## Suites

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

## Mocking

`plugin-tests/clipboard-copy/test_helper/backend_setup.bash` provides `backend_set os=... pbcopy=1 xclip=0 ...` for PATH-based mocking. It restricts PATH to the mock dir alone (so `command -v pbcopy` is deterministic on macOS where the real binary lives in `/usr/bin`) and captures absolute paths to `cat`/`chmod`/`rm`/`uname` for its own use. `backend_write_uname_stub <dir> <os>` writes the same `uname` shim into another directory. Call `backend_setup_init` in `setup()` and `backend_setup_cleanup` in `teardown()`.

`plugin-tests/clipboard-copy/test_helper/server_request.bash` provides `call_tool <tool> <args-json>`, which sends one `tools/call` request to the `SERVER` path the suite sets and keeps the JSON-RPC response. `server_tools_call.bats` and `osc52_handoff.bats` load it.

The `tool_clipboard_copy_file.bats` suite stubs `_clipboard_send_stdin` to capture bytes to a tempfile rather than touching the real clipboard, so the success path is verified without depending on any platform utility being installed.

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

After installing the Codex plugin and restarting Codex, the MCP tools should be discoverable as clipboard-copy tools. A verified local install exposed them under `mcp__clipboard_copy` and successfully returned `Copied N bytes to clipboard via pbcopy` for `clipboard_copy`.
