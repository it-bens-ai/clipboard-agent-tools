![Clipboard Agent Tools](./.github/assets/social-preview.png)

# Clipboard Agent Tools

[![bash 5.1+](https://img.shields.io/badge/bash-5.1%2B-4EAA25?logo=gnubash&logoColor=white)](#requirements)
[![jq 1.7+](https://img.shields.io/badge/jq-1.7%2B-0E5E8E)](#requirements)
[![CI](https://github.com/it-bens-ai/clipboard-agent-tools/actions/workflows/ci.yml/badge.svg)](https://github.com/it-bens-ai/clipboard-agent-tools/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/it-bens-ai/clipboard-agent-tools)](./LICENSE)

[![Claude Code plugin](https://img.shields.io/badge/Claude_Code-plugin-D97757)](#claude-code)
[![Codex plugin](https://img.shields.io/badge/Codex-plugin-000000)](#codex)
[![Pi package](https://img.shields.io/badge/Pi-package-5A4FCF)](#pi)

A marketplace repository for clipboard tools that AI coding agents call as MCP tools.

The [`clipboard-copy`](./plugins/clipboard-copy/) plugin runs a Bash MCP server exposing `clipboard_copy` (inline text) and `clipboard_copy_file` (contents of a file at an absolute path). It picks the clipboard backend for the current environment — `pbcopy` on macOS, `wl-copy` / `xclip` / `xsel` on Linux, `clip.exe` on WSL, `clip` on Cygwin/MSYS — and falls back to OSC 52 escape sequences over SSH and in headless environments. Hooks on Claude Code and Codex, and the extension on Pi, name the MCP tools at session start and block native clipboard-write Bash commands. The same repository is a Pi package, and its extension registers the server and runs the same hook scripts.

## Components

| Plugin | MCP server | Hooks |
|---|---|---|
| [`clipboard-copy`](./plugins/clipboard-copy/) | `clipboard_copy` and `clipboard_copy_file` | SessionStart directive and PreToolUse Bash block; [Pi](./plugins/clipboard-copy/docs/pi.md) covers how Pi runs them |

## Requirements

- `bash` 5.1+ and `jq` 1.7+, first on the `PATH` the agent host starts the MCP server with. The server exits at startup under an older `bash` or `jq`. macOS ships `/bin/bash` 3.2; install a newer one (for example `brew install bash`).
- `ps` and `mkfifo`, used by the MCP core to supervise tool-call processes
- `base64` or `openssl`, used only by the OSC 52 fallback
- A platform clipboard utility when you want to skip OSC 52; [Backends](./plugins/clipboard-copy/docs/backends.md#native-clipboard-utilities) lists them per platform
- Pi only: Node.js 22.19+ and Pi 1.x. Pi support covers macOS and Linux; [Pi](./plugins/clipboard-copy/docs/pi.md#supported-versions) lists the tested Pi versions.

## Install

### Claude Code

```bash
/plugin marketplace add it-bens-ai/clipboard-agent-tools
/plugin install clipboard-copy@clipboard-agent-tools
```

Restart Claude Code after installation so the MCP server is registered. Run `/mcp` in the new session and check that the clipboard-copy server and its two tools appear.

### Codex

```bash
codex plugin marketplace add it-bens-ai/clipboard-agent-tools
codex plugin add clipboard-copy@clipboard-agent-tools
```

Start a new Codex task after installation.

### Pi

```bash
pi install npm:@it-bens-ai/clipboard-agent-tools
```

To install from the Git repository instead:

```bash
pi install git:github.com/it-bens-ai/clipboard-agent-tools
```

Run `pi list` to check that the package is configured. On Pi the tools are deferred; see the plugin's [Pi](./plugins/clipboard-copy/docs/pi.md) guide.

## Documentation

[`plugins/clipboard-copy/README.md`](./plugins/clipboard-copy/README.md) introduces the plugin and indexes its guides in `plugins/clipboard-copy/docs/`: tools, backends, hooks, Pi, troubleshooting, architecture, and testing. [Development](./docs/development.md) covers the repository layout, hosts, test commands, and CI, and [Releasing](./docs/releasing.md) covers version bumps and npm publishing.

## License

[MIT](./LICENSE).
