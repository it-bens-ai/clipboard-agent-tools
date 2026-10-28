# Hooks

On Claude Code and Codex the plugin registers two hooks in `hooks/hooks.json`: a `SessionStart` hook that tells the model to use the MCP tools, and a `PreToolUse` hook on the `Bash` tool that blocks native clipboard-write commands. Each hook command resolves the plugin root from Codex's `PLUGIN_ROOT` or Claude Code's `CLAUDE_PLUGIN_ROOT` and fails when neither is set. On Pi the extension runs the same two scripts itself; see [Pi](pi.md).

## SessionStart directive

At the start of every session, the hook adds a short directive to the conversation context. It names `clipboard_copy` and `clipboard_copy_file` as the way to write to the clipboard and lists the Bash commands that are blocked. The model sees the directive before it reaches for `pbcopy`, instead of only being corrected by the Bash block afterwards.

The directive also bans reprinting copied content into the session. After a copy the model reports the tool result — byte count, backend, and the path for `clipboard_copy_file` — and stays silent about the content itself, even when the surrounding instruction asks for that content to be output. Printing it is correct only when the user asks for it after the copy has already happened. The tool descriptions carry the same rule; see [Tools](tools.md#no-echo-rule).

The directive text lives in `hooks/prompts/mcp-tool-directives.md` and is static. The script `hooks/scripts/session-start.sh` emits it as `hookSpecificOutput.additionalContext`. The script exits 1 with an error on stderr when the directive file or `jq` is missing, or, with `CLIPBOARD_COPY_HOST=pi`, the Pi addendum.

## Bash enforcement

The `PreToolUse` hook runs `hooks/scripts/check-clipboard.sh` before each `Bash` tool call. It blocks native clipboard-write commands and points the model to `clipboard_copy` / `clipboard_copy_file`.

| Command | Action |
|---|---|
| `pbcopy` | Block |
| `wl-copy` | Block |
| `clip.exe` | Block |
| `clip` | Block |
| `xclip` without `-o` / `-out` | Block |
| `xsel` without `-o` / `--output` | Block |
| `pbpaste`, `wl-paste`, `xclip -o`, `xsel -o` | Allow (clipboard reads are not the target) |

A command is matched only at the start of a command segment. A segment starts at the beginning of the command or after a pipe, `;`, `&&`, or `||`, so chained invocations are caught. A paste flag must follow the same tool name within one segment, so `xsel -o` cannot excuse `xclip -i`. A paste-mode invocation anywhere in the command allows every invocation of that same tool: `xclip -i < f; xclip -o` is allowed.

```bash
echo "secret" | pbcopy            # blocked
date && wl-copy < file            # blocked
xclip -selection clipboard < f    # blocked
xclip -o > out.txt                # allowed (paste)
```

### Exit codes

| Exit code | Meaning |
|---|---|
| 0 | The command is allowed. An empty command is allowed before anything else is checked. |
| 1 | `CLIPBOARD_COPY_HOST` holds an unsupported value. |
| 2 | The command is blocked. The message on stderr names the command and the MCP tool to use instead. |

### Unsupported host

`CLIPBOARD_COPY_HOST` is unset on Claude Code and Codex and `pi` on Pi. For any other non-empty value, both hook scripts print `clipboard-copy: unsupported CLIPBOARD_COPY_HOST "<value>"; expected pi or unset` on stderr and exit 1. `check-clipboard.sh` does this for every non-empty command, whether or not it writes the clipboard. `session-start.sh` does it before reading the directive file.
