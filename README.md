# Clipboard Agent Tools

A marketplace repository for clipboard tools that AI coding agents call as MCP tools.

The [`clipboard-copy`](./plugins/clipboard-copy/) plugin runs a Bash MCP server exposing `clipboard_copy` (inline text) and `clipboard_copy_file` (contents of a file at an absolute path). It picks the clipboard backend for the current environment — `pbcopy` on macOS, `wl-copy` / `xclip` / `xsel` on Linux, `clip.exe` on WSL, `clip` on Cygwin/MSYS — and falls back to OSC 52 escape sequences over SSH and in headless environments. Shared Claude Code and Codex hooks name the MCP tools at session start and block native clipboard-write Bash commands.

## Requirements

- `bash` 4+
- `jq`
- `base64` or `openssl`, used only by the OSC 52 fallback
- A platform clipboard utility when you want to skip OSC 52

## Install

### Claude Code

```bash
/plugin marketplace add it-bens-ai/clipboard-agent-tools
/plugin install clipboard-copy@clipboard-agent-tools
```

Restart Claude Code after installation so the MCP server is registered.

### Codex

```bash
codex plugin marketplace add it-bens-ai/clipboard-agent-tools
codex plugin add clipboard-copy@clipboard-agent-tools
```

Start a new Codex task after installation.

## Documentation

[`plugins/clipboard-copy/README.md`](./plugins/clipboard-copy/README.md) covers both tools, backend detection, the hooks, and the plugin layout. [`AGENTS.md`](./AGENTS.md) covers the repository layout, test commands, and version bumps.

## License

[MIT](./LICENSE).
