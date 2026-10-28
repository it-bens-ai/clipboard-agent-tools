# Clipboard Copy

A Bash MCP server with two clipboard tools: `clipboard_copy` copies inline text, and `clipboard_copy_file` copies the contents of a file at an absolute path. The server picks the clipboard utility for the current platform and falls back to OSC 52 escape sequences when none is available, so it also works over SSH and in headless environments.

The plugin runs on Claude Code, Codex, and Pi. On Claude Code and Codex, hooks name the tools at session start and block native clipboard-write Bash commands. On Pi, the package's extension registers the same server and runs the same hook scripts.

## Quick Start

Install the plugin with the commands for your host in the repository README's [Install](../../README.md#install) section, which also lists the [Requirements](../../README.md#requirements). Then ask the agent to copy something:

> Copy the latest changelog entry to my clipboard.

The agent calls `clipboard_copy` with the text, and the server copies it with the backend for your machine. Pi names the tools differently and loads them on demand; see [Pi](docs/pi.md).

## Tools

- `clipboard_copy` — copies the `text` argument to the clipboard, byte for byte.
- `clipboard_copy_file` — copies the contents of the file at the absolute `path` argument.

## Documentation

| Document | Covers |
|---|---|
| [Tools](docs/tools.md) | Arguments, result text, and argument validation for both tools |
| [Backends](docs/backends.md) | Backend detection order, OSC 52 fallback, supported terminals, native clipboard utilities |
| [Hooks](docs/hooks.md) | The SessionStart directive and the Bash block on Claude Code and Codex |
| [Pi](docs/pi.md) | The Pi extension: tool names, directive, Bash check, OSC 52 on Pi, supported Pi versions |
| [Troubleshooting](docs/troubleshooting.md) | Common failures and their fixes |
| [Architecture](docs/architecture.md) | File layout, host wiring, MCP wire flow, key functions |
| [Testing](docs/testing.md) | Test suites, mocking helpers, manual smoke tests |

## License

MIT
