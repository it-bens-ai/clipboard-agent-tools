@README.md

# Clipboard Agent Tools - Technical Reference

This repository packages the `clipboard-copy` plugin as its own installable marketplace. The plugin ships a Bash MCP server, two hooks, and a SessionStart directive. It has no skills, agents, or slash commands.

## Hosts

Claude Code reads `.claude-plugin/marketplace.json`, `plugins/clipboard-copy/.claude-plugin/plugin.json`, and `plugins/clipboard-copy/.mcp.json`. Codex reads `.agents/plugins/marketplace.json` and `plugins/clipboard-copy/.codex-plugin/plugin.json`. The MCP server, hook scripts, and directive prompt are shared. The hook launchers resolve the plugin root from Codex's `PLUGIN_ROOT` or Claude Code's `CLAUDE_PLUGIN_ROOT`, and fail when neither is set.

## Repository Architecture

```
.agents/plugins/marketplace.json         # Codex registry → clipboard-copy
.claude-plugin/marketplace.json          # Claude Code registry → clipboard-copy
.claude/extensions/software-writer/      # Project extensions for the software-writer skills
plugins/clipboard-copy/                  # THE PLUGIN: MCP server, hooks, host manifests
plugin-tests/clipboard-copy/             # BATS suites mirroring the plugin structure
plugin-tests/test_helper/                # Shared BATS helper
.github/scripts/setup-bats.sh            # Installs BATS into .bats/
.github/scripts/vendor-mcp-sdk.sh        # Vendors the pinned bash-mcp-sdk core
.mcp-sdk.lock                            # Pinned bash-mcp-sdk release and SHA-256
```

Both marketplace files point at the same plugin root, `./plugins/clipboard-copy`. Claude Code sources use `{"name": "<name>", "source": "./plugins/<name>"}`; Codex sources use `{"source": {"source": "local", "path": "./plugins/<name>"}}`. Paths are relative to the marketplace root, which is the repository root.

Plugin changes start at `plugins/clipboard-copy/AGENTS.md`: it maps each task (backend detection, MCP tool, hook pattern, directive text) to the file and function that owns it, and its README covers the tool catalog and backend order.

## Vendored MCP SDK

`plugins/clipboard-copy/shared/mcpserver_core.sh` is a copy of `lib/mcpserver_core.sh` from [`shopwareLabs/bash-mcp-sdk`](https://github.com/shopwareLabs/bash-mcp-sdk). `.mcp-sdk.lock` pins the release tag (`version=`) and the file's SHA-256 (`sha256=`). Do not edit the vendored file; send protocol changes to the SDK repository.

```bash
./.github/scripts/vendor-mcp-sdk.sh            # download the pinned release and overwrite the vendored copy
./.github/scripts/vendor-mcp-sdk.sh --check    # exit non-zero when the vendored copy differs from the pinned release
```

Both modes download the file from GitHub and fail when its SHA-256 differs from the lock. To move to a new release, set `version=` and `sha256=` in `.mcp-sdk.lock`, then run the script. No CI runs `--check`; run it before committing a change under `plugins/clipboard-copy/shared/`.

## Testing

```bash
./.github/scripts/setup-bats.sh             # one-time: installs bats-core/support/assert to .bats/
.bats/bats-core/bin/bats -r plugin-tests/
```

The shared helper at `plugin-tests/test_helper/common_setup.bash` resolves the repository root by walking up to `.bats/`. Each suite loads it through `plugin-tests/clipboard-copy/test_helper/common_setup.bash`, which sets `PLUGIN_DIR`, `SCRIPTS_DIR`, `LIB_DIR`, and `SHARED_DIR`.

## Version bumps

Set the release version in `plugins/clipboard-copy/.claude-plugin/plugin.json` and `plugins/clipboard-copy/.codex-plugin/plugin.json`, then add a matching entry to `plugins/clipboard-copy/CHANGELOG.md`. The Codex manifest carries a build suffix after `+` (`"version": "1.3.0+codex.<timestamp>"`); the part before `+` must equal the Claude Code manifest version.

## Commit Messages

Use conventional-commit format. Do not `git add` or commit until asked.
