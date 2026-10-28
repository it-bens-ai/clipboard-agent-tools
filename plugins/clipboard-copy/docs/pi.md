# Pi

The repository root is a Pi package whose extension is `pi/index.ts`. The extension registers the clipboard-copy MCP server and runs the plugin's two hook scripts from its own event handlers; Pi does not read `.mcp.json` or `hooks/hooks.json`. The install commands are in the repository README's [Pi](../../../README.md#pi) section.

## Supported versions

Pi support covers Pi 1.x; the platform and Node.js requirements are in the repository README's [Requirements](../../../README.md#requirements). CI tests the package against Pi 1.0.0, the oldest supported release, and against the release pinned in `devDependencies`. Pi has shipped breaking changes in 1.x minor and patch releases, so a release newer than the pinned one is untested. The package declares `@earendil-works/pi-coding-agent` as a peer dependency with the range `*`, as Pi's package documentation asks, because Pi loads the extension against its own copy and does not check the range.

## Tools

When the session starts, the extension registers `mcp-server-clipboard/server.sh` as the MCP server `clipboard-copy` with `exposure: "deferred"`. Pi declares deferred tools to the model only after `tool_search` loads them, under the names `mcp__clipboard_copy__clipboard_copy` and `mcp__clipboard_copy__clipboard_copy_file`. Deferred exposure keeps Pi's declared tool set lean. The server runs with `CLIPBOARD_COPY_HOST=pi` and `CLIPBOARD_COPY_OSC52_DIR` set.

The tools take the same arguments and return the same results as on the other hosts; see [Tools](tools.md).

## Directive

At session start the extension runs `hooks/scripts/session-start.sh` with `CLIPBOARD_COPY_HOST=pi`. The script appends `hooks/prompts/host-pi.md` to the shared directive; the addendum gives the Pi tool names and tells the model how to load them with `tool_search`. The extension adds the result to the system prompt as the section `clipboard_copy`. [Hooks](hooks.md#sessionstart-directive) describes the shared directive.

When the script fails, times out after 5 seconds, or prints no `additionalContext`, the session gets no section. Pi then shows a warning, or writes it to stderr when Pi runs without a UI.

## Bash check

Before each call of Pi's `bash` tool, the extension runs `hooks/scripts/check-clipboard.sh` with the call's input. [Hooks](hooks.md#bash-enforcement) lists which commands the script blocks. Exit 2 blocks the call, with the script's message as the reason. When the script exits 2 without a message, the block carries a fixed reason saying so. On Pi the message names the tools as `mcp__clipboard_copy__…`. Pi's `powershell` tool is not checked.

Any exit other than 0 or 2, a missing `jq` on Pi's `PATH`, a 5-second timeout, or a script that cannot start blocks the call too, with a reason naming the failure, and the extension shows a warning. That includes the exit 1 for an unsupported `CLIPBOARD_COPY_HOST`, so when the check cannot run at all, every `bash` call on Pi is blocked.

## OSC 52 on Pi

Pi starts MCP servers without a controlling terminal, so the server cannot reach `/dev/tty`. When `CLIPBOARD_COPY_OSC52_DIR` is set to a non-empty value, the server writes the OSC 52 sequence to a new owner-only file in that directory. It adds `OSC 52 handoff: <file name>` as the result's last line. The extension creates the directory on `session_start` with mode 700 under the system temp directory, and removes it when the session ends.

The variable is honoured only with `CLIPBOARD_COPY_HOST=pi`; any other host is refused. The path must be absolute and equal its own physical path, so a symlink, a trailing slash, or a `.` component is refused. It is also refused when it is not owned by the current user, or writable by group or others.

The extension's `tool_result` handler reads the file, deletes it, and writes the sequence to Pi's terminal. The model then sees the copy summary without the handoff line. When the file cannot be read, the handler removes it and returns an error.

- The handoff works only in Pi's interactive mode with a terminal on stdout. In print, JSON, and RPC mode the result is an error, and nothing is copied.
- The base64 payload is capped at 100000 characters, about 75 KB of input, and the server checks the byte count before encoding. A larger copy returns an error.
- As everywhere, OSC 52 cannot confirm that the terminal accepted the sequence.

[Backends](backends.md#osc-52-fallback) covers the OSC 52 fallback on the other hosts.
