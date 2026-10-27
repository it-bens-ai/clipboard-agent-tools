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
.github/workflows/ci.yml                  # Path-filtered Bash tests and lint
.github/ISSUE_TEMPLATE/                  # Issue forms
.shellcheckrc                            # ShellCheck rules
renovate.json                            # Dependency update rules
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

Both modes download the file from GitHub and fail when its SHA-256 differs from the lock. To move to a new release, set `version=` and `sha256=` in `.mcp-sdk.lock`, then run the script. CI runs `--check` after ShellCheck and before BATS; run it locally before committing a change under `plugins/clipboard-copy/shared/`.

## Testing

```bash
./.github/scripts/setup-bats.sh             # one-time: installs bats-core/support/assert to .bats/
.bats/bats-core/bin/bats -r plugin-tests/
find plugins plugin-tests .github/scripts -type f \
  \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) \
  -exec shellcheck --shell=bash --format=gcc {} +
./.github/scripts/vendor-mcp-sdk.sh --check
```

The shared helper at `plugin-tests/test_helper/common_setup.bash` resolves the repository root by walking up to `.bats/`. Each suite loads it through `plugin-tests/clipboard-copy/test_helper/common_setup.bash`, which sets `PLUGIN_DIR`, `SCRIPTS_DIR`, `LIB_DIR`, and `SHARED_DIR`.

CI in `.github/workflows/ci.yml` runs on pushes to `main` and on pull requests when `plugins/**`, `plugin-tests/**`, `.mcp-sdk.lock`, `.shellcheckrc`, `.github/workflows/ci.yml`, or `.github/scripts/**` change. Its Ubuntu job checks out the repository, installs jq and ShellCheck 0.11.0, runs ShellCheck and the vendored SDK check, installs BATS core 1.14.0 and assert 2.2.4 (with support), then runs the BATS suite. Documentation-only changes outside those paths do not trigger CI.

## Development workflow

Read `plugins/clipboard-copy/AGENTS.md` before editing plugin behavior. Update `plugins/clipboard-copy/README.md` when its tool or hook behavior changes, and add user-visible changes to `plugins/clipboard-copy/CHANGELOG.md`. Run the checks under Testing before asking for review.

## Local validation

```bash
claude plugin validate .
codex plugin marketplace add /path/to/clipboard-agent-tools
codex plugin list --available --json
codex plugin add clipboard-copy@clipboard-agent-tools
```

The Codex smoke-test commands alter your Codex configuration; run them only when you intend to install locally.

## Version bumps

Set the release version in `plugins/clipboard-copy/.claude-plugin/plugin.json` and `plugins/clipboard-copy/.codex-plugin/plugin.json`, then add a matching entry to `plugins/clipboard-copy/CHANGELOG.md`. The Codex manifest carries a build suffix after `+` (`"version": "1.3.0+codex.<timestamp>"`); the part before `+` must equal the Claude Code manifest version.

## Pre-release checklist

- [ ] `claude plugin validate .` passes and the Codex marketplace add/list/install smoke test succeeds.
- [ ] Both plugin manifests carry the same release version before the Codex `+codex.<timestamp>` suffix; the CHANGELOG has the matching entry.
- [ ] BATS and ShellCheck pass; `.github/scripts/vendor-mcp-sdk.sh --check` passes.
- [ ] CI is green for the release change.

## Distribution

Users install this repository as a marketplace. Claude Code runs `/plugin marketplace add it-bens-ai/clipboard-agent-tools` then `/plugin install clipboard-copy@clipboard-agent-tools`; Codex runs `codex plugin marketplace add it-bens-ai/clipboard-agent-tools` then `codex plugin add clipboard-copy@clipboard-agent-tools`. See README §Install for host restart instructions.

## Commit Messages

Use conventional-commit format. Do not `git add` or commit until asked.
