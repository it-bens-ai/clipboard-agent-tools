# Clipboard Copy

A bash-based MCP server that provides cross-platform clipboard tools: `clipboard_copy` (inline text) and `clipboard_copy_file` (contents of a file at an absolute path). Auto-detects the right backend (pbcopy / wl-copy / xclip / xsel / clip.exe / clip) and falls back to OSC 52 escape sequences when no native utility is available — so it still works over SSH and in headless environments.

The plugin is intentionally compatible with Claude Code, Codex, and Pi. Claude Code uses `.claude-plugin/plugin.json` plus `.mcp.json`; Codex uses `.codex-plugin/plugin.json` and the repo marketplace at `.agents/plugins/marketplace.json`. The MCP server, hook scripts, and directive prompt are shared. Pi loads the extension in `pi/`, which registers the same server and runs the same hook scripts; see [Pi Extension](#pi-extension).

## Quick Start

### Claude Code

```bash
/plugin install clipboard-copy@clipboard-agent-tools
```

Restart Claude Code so the MCP server is registered. Then ask Claude to copy something:

> Copy the latest changelog entry to my clipboard.

Claude will call `clipboard_copy` with the text; the server picks the backend appropriate for your machine.

### Codex

From a clone of this repository, add the repo marketplace once:

```bash
codex plugin marketplace add <repo-root>
```

Then install `clipboard-copy` from Codex's plugin browser, restart Codex, and ask Codex to copy something:

> Copy the latest changelog entry to my clipboard.

Codex exposes the same MCP tools. In the tested local install, they appear under the `mcp__clipboard_copy` namespace as `clipboard_copy` and `clipboard_copy_file`.

### Pi

Pi installs the package from npm or from the Git repository. The [repository README](https://github.com/it-bens-ai/clipboard-agent-tools#pi) holds both commands and the `pi list` check.

Then ask Pi to copy something. Pi names the tools `mcp__clipboard_copy__clipboard_copy` and `mcp__clipboard_copy__clipboard_copy_file`, and the model loads them through `tool_search` before the first call.

## Tools

### `clipboard_copy`

Writes inline text to the system clipboard.

| Argument | Type   | Required | Description                                                     |
|----------|--------|----------|-----------------------------------------------------------------|
| `text`   | string | yes      | The text to copy. Sent verbatim — no trailing newline appended. |

On success returns `Copied N bytes to clipboard via <backend>`.

### `clipboard_copy_file`

Writes the contents of a file to the system clipboard. Useful when the content is already on disk — for example a temp file the model just wrote — and would be wasteful to send back through the MCP channel as inline text.

| Argument | Type   | Required | Description                                                                  |
|----------|--------|----------|------------------------------------------------------------------------------|
| `path`   | string | yes      | Absolute filesystem path to the file whose contents should be copied.        |

The path must be absolute, point to an existing regular file, and be readable. On success returns `Copied N bytes from <path> to clipboard via <backend>`.

The server checks each call's arguments against the tool's `inputSchema` in `mcp-server-clipboard/tools.json` before the tool runs. A path that does not start with `/`, a value of the wrong type, or an argument the tables above do not list returns an error result, and nothing is copied.

The server exits non-zero before reading requests if `tools.json` is missing, invalid JSON, or not exactly one JSON object containing a `tools` array. Check the MCP host's stderr for the error.

Both tool descriptions carry the no-echo rule described under [SessionStart Hook](#sessionstart-hook), so it applies even on a host that registers the MCP server without the plugin's hooks.

## Backend Detection

The server picks the first available backend in this order, scoped to the OS:

| OS                              | Detection order                                                           |
|---------------------------------|---------------------------------------------------------------------------|
| macOS (`Darwin`)                | `pbcopy` → `osc52`                                                        |
| Linux                           | `clip.exe` (WSL) → `wl-copy` (Wayland) → `xclip` → `xsel` (X11) → `osc52` |
| Cygwin / MinGW / MSYS (Windows) | `clip` → `osc52`                                                          |
| Other                           | `osc52`                                                                   |

## SessionStart Hook

A `SessionStart` hook injects a short directive into the conversation context at the start of every session, naming `clipboard_copy` / `clipboard_copy_file` as the right way to write to the clipboard and listing the Bash commands that are blocked. This complements the reactive `PreToolUse` block message below: the model sees the directive *before* it ever reaches for `pbcopy`, instead of only being corrected after the fact.

The directive also bans reprinting copied content into the session. After a copy the model reports the tool result — byte count, backend, and the path for `clipboard_copy_file` — and stays silent about the content itself, even when the surrounding instruction asks for that content to be output. Printing it is correct only when the user asks for it after the copy has already happened.

The directive text lives in `hooks/prompts/mcp-tool-directives.md`. The hook script (`hooks/scripts/session-start.sh`) emits it via `hookSpecificOutput.additionalContext`.

The hook registration is shared between Claude Code and Codex. It resolves the plugin root from Codex's `PLUGIN_ROOT` or Claude Code's `CLAUDE_PLUGIN_ROOT` and fails explicitly when neither host-provided variable is available.

## Bash Enforcement Hook

A `PreToolUse` hook on the `Bash` tool blocks native clipboard-write commands and routes them to the MCP tools. Blocked invocations exit with code 2 and a hint pointing to `clipboard_copy` / `clipboard_copy_file`. An unsupported `CLIPBOARD_COPY_HOST` exits 1 with a message naming the value, for every non-empty command, whether or not it writes the clipboard. An empty command is allowed before the host is read.

| Command | Action |
|---|---|
| `pbcopy` (anywhere in segment) | Block |
| `wl-copy` (anywhere in segment) | Block |
| `clip.exe` (anywhere in segment) | Block |
| `clip` (at start of segment) | Block |
| `xclip` without `-o` / `-out` | Block |
| `xsel` without `-o` / `--output` | Block |
| `pbpaste`, `wl-paste`, `xclip -o`, `xsel -o` | Allow (clipboard reads are not the target) |

`xclip` and `xsel` write to the clipboard by default, so each call needs its own paste flag before the next `|`, `;` or `&`. A paste flag on one call does not cover another call of the same tool.

Pipes, `;`, `&&`, and `\|\|` are recognized as command separators so chained invocations are caught:

```bash
echo "secret" | pbcopy            # blocked
date && wl-copy < file            # blocked
xclip -selection clipboard < f    # blocked
xclip -i < f; xclip -o            # blocked (the first call writes)
xclip -o > out.txt                # allowed (paste)
xclip -selection clipboard -o|grep x   # allowed (paste)
```

## OSC 52 Fallback

When no native utility is available — over SSH, in containers, in restricted environments — the server falls back to writing an [OSC 52](https://www.xfree86.org/current/ctlseqs.html) terminal escape sequence to `/dev/tty`. The escape is wrapped in a tmux DCS pass-through when `$TMUX` is set.

OSC 52 is supported by most modern terminal emulators, including:

- iTerm2
- kitty
- Alacritty
- WezTerm
- Windows Terminal
- foot
- tmux (with the wrapping the server applies automatically)

If your terminal does not honor OSC 52 the copy will silently no-op as far as the system clipboard is concerned — there is no way for the server to detect that.

On Pi the server does not write to `/dev/tty`; see [OSC 52 on Pi](#osc-52-on-pi).

## Pi Extension

The root `package.json` makes the repository a Pi package; its `pi.extensions` field names `pi/index.ts`. Pi support covers macOS and Linux.

### Tools

The extension registers `mcp-server-clipboard/server.sh` as the MCP server `clipboard-copy` with `exposure: "deferred"` when the session starts. Pi declares deferred tools to the model only after `tool_search` loads them, under the names `mcp__clipboard_copy__clipboard_copy` and `mcp__clipboard_copy__clipboard_copy_file`. Deferred exposure keeps Pi's declared tool set lean. The server runs with `CLIPBOARD_COPY_HOST=pi` and `CLIPBOARD_COPY_OSC52_DIR` set.

### Directive

At session start the extension runs `hooks/scripts/session-start.sh` with `CLIPBOARD_COPY_HOST=pi`. The script appends `hooks/prompts/host-pi.md` to the shared directive; the addendum gives the Pi tool names and tells the model how to load them with `tool_search`. The extension adds the result to the system prompt as the section `clipboard_copy`. When the script fails, times out after 5 seconds, or prints no `additionalContext`, the session gets no section. Pi then shows a warning, or writes it to stderr when Pi runs without a UI.

### Bash check

Before each call of Pi's `bash` tool, the extension runs `hooks/scripts/check-clipboard.sh` with the call's input. Exit 2 blocks the call, with the script's message as the reason. When the script exits 2 without a message, the block carries a fixed reason saying so. On Pi the message names the tools as `mcp__clipboard_copy__…`. Any other failure blocks the call too, with a reason naming the failure. The extension also shows a warning. Pi's `powershell` tool is not checked.

The script exits 1 for an unsupported `CLIPBOARD_COPY_HOST`, and any failure blocks too. So when the check cannot run at all, every `bash` call on Pi is blocked, with a warning naming the cause. That covers a missing `jq` on Pi's `PATH`, a timeout, or a script that cannot start.

### OSC 52 on Pi

Pi starts MCP servers without a controlling terminal, so the server cannot reach `/dev/tty`. When `CLIPBOARD_COPY_OSC52_DIR` is set to a non-empty value, the server writes the OSC 52 sequence to a new owner-only file in that directory. It adds `OSC 52 handoff: <file name>` as the result's last line. The extension creates the directory on `session_start` with mode 700 under the system temp directory, and removes it when the session ends. The variable is honoured only with `CLIPBOARD_COPY_HOST=pi`; any other host is refused. The path must be absolute and equal its own physical path, so a symlink, a trailing slash, or a `.` component is refused. It is also refused when it is not owned by the current user, or writable by group or others.

The extension's `tool_result` handler reads the file, deletes it, and writes the sequence to Pi's terminal. The model then sees the copy summary without the handoff line. When the file cannot be read, the handler removes it and returns an error.

- The handoff works only in Pi's interactive mode with a terminal on stdout. In print, JSON, and RPC mode the result is an error, and nothing is copied.
- The base64 payload is capped at 100000 characters, about 75 KB of input, and the server checks the byte count before encoding. A larger copy returns an error.
- As everywhere, OSC 52 cannot confirm that the terminal accepted the sequence.

## Requirements

- `bash` 5.1+ and `jq` 1.7+, first on the `PATH` the agent host starts the MCP server with. The server exits at startup under an older `bash` or `jq`. macOS ships `/bin/bash` 3.2; install a newer one (for example `brew install bash`).
- `ps` and `mkfifo`, used by the MCP core to run each tool call
- `base64` or `openssl` (only used by the OSC 52 fallback)
- A clipboard utility for your platform if you want to skip OSC 52:
  - macOS: `pbcopy` (preinstalled)
  - Linux Wayland: `wl-clipboard` (`wl-copy`)
  - Linux X11: `xclip` or `xsel`
  - WSL: `clip.exe` (preinstalled on Windows)
  - Cygwin/MSYS: `clip`
- Pi only: Node.js 22.19 or newer and Pi 1.x. CI tests the package against Pi 1.0.0, the oldest supported release, and against the release pinned in `devDependencies`. Pi has shipped breaking changes in 1.x minor and patch releases, so a release newer than the pinned one is untested. The package declares `@earendil-works/pi-coding-agent` as a peer dependency with the range `*`, as Pi's package documentation asks, because Pi loads the extension against its own copy and does not check the range.

## Troubleshooting

- **Server not starting:** Run `bash --version` and `jq --version` in the host's environment. The first `bash` on `PATH` must be 5.1 or newer and `jq` must be 1.7 or newer; stock macOS `/bin/bash` is 3.2. Check the MCP host's stderr for server startup logs. The server sets `MCP_LOG_STDERR=1`; it does not write a plugin-local `server.log`.
- **Tools missing after installation:** Restart Claude Code or start a new Codex task. In Claude Code, inspect the server with `/mcp`. On Pi, start a new session; the tools appear after `tool_search` loads them.
- **Codex hook not blocking clipboard commands:** Open `/hooks` in Codex and trust the bundled hooks; untrusted plugin hooks do not run.
- **Pi copy fails with "nothing was copied":** The server fell back to OSC 52, and Pi is not running in interactive mode in a terminal. Install a native clipboard utility, or run Pi interactively. See [OSC 52 on Pi](#osc-52-on-pi).
- **OSC 52 reports success but nothing is copied:** The terminal must support and permit OSC 52. The server writes to `/dev/tty`, or, on Pi, hands the sequence to the extension to write in interactive mode. It wraps the sequence for tmux when `TMUX` is set, but it cannot detect whether the terminal accepted it.

## Layout

```
plugins/clipboard-copy/
├── AGENTS.md                      # Shared development guidance for Claude Code, Codex, and Pi
├── .claude-plugin/
│   └── plugin.json                 # Claude Code plugin manifest
├── .codex-plugin/
│   └── plugin.json                 # Codex plugin manifest
├── .mcp.json                       # Claude Code MCP registration
├── README.md
├── pi/
│   ├── index.ts                    # Pi extension: server registration, directive, Bash check, OSC 52 handoff
│   └── gate.ts                     # Runs a hook script and maps its exit code to allow or block
├── shared/
│   └── mcpserver_core.sh           # JSON-RPC 2.0 stdio handler, vendored from bash-mcp-sdk
├── hooks/
│   ├── hooks.json                  # SessionStart + PreToolUse(Bash) registration
│   ├── prompts/
│   │   ├── mcp-tool-directives.md  # Static template injected at SessionStart
│   │   └── host-pi.md              # Pi addendum: tool names and tool_search loading
│   └── scripts/
│       ├── session-start.sh        # Emits the directive as additionalContext
│       ├── check-clipboard.sh      # Pattern-matches and blocks native writes
│       └── lib/
│           └── common.sh           # parse_hook_input + validate_clipboard_host + block_clipboard
└── mcp-server-clipboard/
    ├── server.sh                    # Entry point (registered in .mcp.json)
    ├── config.json                  # MCP protocolVersion, serverInfo, capabilities
    ├── tools.json                   # Tool schemas (clipboard_copy, clipboard_copy_file)
    └── lib/
        └── clipboard.sh             # Backend detection + tool implementations
```

Codex marketplace metadata lives outside the plugin directory at `.agents/plugins/marketplace.json`, with `source.path` pointing back to `./plugins/clipboard-copy`. The Pi package manifest is the repository root `package.json`.

## License

MIT
