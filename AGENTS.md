@README.md

# Clipboard Agent Tools - Technical Reference

This repository packages the `clipboard-copy` plugin as its own installable marketplace. The plugin ships a Bash MCP server, two hooks, a SessionStart directive, and a Pi extension. It has no skills, agents, or slash commands. The repository root is also the npm package `@it-bens-ai/clipboard-agent-tools`, which Pi installs.

## Hosts

Claude Code reads `.claude-plugin/marketplace.json`, `plugins/clipboard-copy/.claude-plugin/plugin.json`, and `plugins/clipboard-copy/.mcp.json`. Codex reads `.agents/plugins/marketplace.json` and `plugins/clipboard-copy/.codex-plugin/plugin.json`. The MCP server, hook scripts, and directive prompt are shared. The hook launchers resolve the plugin root from Codex's `PLUGIN_ROOT` or Claude Code's `CLAUDE_PLUGIN_ROOT`, and fail when neither is set.

Pi reads the `pi.extensions` field of the root `package.json`, which names `plugins/clipboard-copy/pi/index.ts`. The extension registers the same MCP server and runs `hooks/scripts/session-start.sh` and `hooks/scripts/check-clipboard.sh` from its own event handlers instead of `hooks/hooks.json`. It sets `CLIPBOARD_COPY_HOST=pi` for the server and both scripts, and `CLIPBOARD_COPY_OSC52_DIR` for the server. Claude Code and Codex leave `CLIPBOARD_COPY_HOST` unset; both hook scripts exit 1 on any other value. The package `files` list limits what npm publishes to the plugin's runtime directories, its README, and its CHANGELOG. npm adds the root `README.md`, `package.json`, and `LICENSE` on its own.

## Repository Architecture

```
.agents/plugins/marketplace.json         # Codex registry → clipboard-copy
.claude-plugin/marketplace.json          # Claude Code registry → clipboard-copy
package.json                             # Pi package manifest (npm), scripts, dev dependencies
package-lock.json                        # Locked npm dependency tree
tsconfig.json                            # TypeScript type-check settings for the Pi sources and tests
eslint.config.mjs                        # ESLint rules for the TypeScript sources
.claude/extensions/software-writer/      # Project extensions for the software-writer skills
plugins/clipboard-copy/                  # THE PLUGIN: MCP server, hooks, host manifests
plugins/clipboard-copy/pi/               # Pi extension (TypeScript)
plugin-tests/clipboard-copy/             # BATS suites mirroring the plugin structure
plugin-tests/clipboard-copy/pi/          # Node tests for the Pi extension
plugin-tests/test_helper/                # Shared BATS helper
.github/scripts/setup-bats.sh            # Installs BATS into .bats/
.github/scripts/check-versions.sh        # Checks that package.json and every manifest share a version
.github/workflows/ci.yml                 # Path-filtered Node and Bash tests, lint, and version check
.github/workflows/npm-publish.yml        # Publishes the Pi package to npm on v* tags
.github/ISSUE_TEMPLATE/                  # Issue forms
.shellcheckrc                            # ShellCheck rules
renovate.json                            # Dependency update rules
.github/scripts/vendor-mcp-sdk.sh        # Vendors the pinned bash-mcp-sdk core
.mcp-sdk.lock                            # Pinned bash-mcp-sdk release and SHA-256
```

Both marketplace files point at the same plugin root, `./plugins/clipboard-copy`. Claude Code sources use `{"name": "<name>", "source": "./plugins/<name>"}`; Codex sources use `{"source": {"source": "local", "path": "./plugins/<name>"}}`. Paths are relative to the marketplace root, which is the repository root.

Plugin changes start at `plugins/clipboard-copy/AGENTS.md`: it maps each task (backend detection, MCP tool, hook pattern, directive text, Pi extension) to the file and function that owns it, and its README covers the tool catalog and backend order.

## Vendored MCP SDK

`plugins/clipboard-copy/shared/mcpserver_core.sh` is a copy of `lib/mcpserver_core.sh` from [`shopwareLabs/bash-mcp-sdk`](https://github.com/shopwareLabs/bash-mcp-sdk). `.mcp-sdk.lock` pins the release tag (`version=`) and the file's SHA-256 (`sha256=`). Do not edit the vendored file; send protocol changes to the SDK repository.

```bash
./.github/scripts/vendor-mcp-sdk.sh            # download the pinned release and overwrite the vendored copy
./.github/scripts/vendor-mcp-sdk.sh --check    # exit non-zero when the vendored copy differs from the pinned release
```

Both modes download the file from GitHub and fail when its SHA-256 differs from the lock. To move to a new release, set `version=` and `sha256=` in `.mcp-sdk.lock`, then run the script. CI runs `--check` after ShellCheck and before BATS; run it locally before committing a change under `plugins/clipboard-copy/shared/`.

## Testing

```bash
npm ci                                      # installs TypeScript, ESLint, and Pi into node_modules/
npm run typecheck
npm run lint
npm test                                    # Node tests matching plugin-tests/clipboard-copy/pi/*.test.ts
./.github/scripts/setup-bats.sh             # one-time: installs bats-core/support/assert to .bats/
.bats/bats-core/bin/bats -r plugin-tests/
find plugins plugin-tests .github/scripts -type f \
  \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) \
  -exec shellcheck --shell=bash --format=gcc {} +
./.github/scripts/vendor-mcp-sdk.sh --check
```

The shared helper at `plugin-tests/test_helper/common_setup.bash` resolves the repository root by walking up to `.bats/`. Each suite loads it through `plugin-tests/clipboard-copy/test_helper/common_setup.bash`, which sets `PLUGIN_DIR`, `SCRIPTS_DIR`, `LIB_DIR`, and `SHARED_DIR`.

`plugin-tests/clipboard-copy/pi_e2e.bats` runs the Pi binary from `node_modules/.bin/pi` offline with a scripted model. It runs the `deferred` scenario against the package laid out as a Git clone and as an installed `npm pack` tarball. The `osc52` and `tui` scenarios run against the Git-clone layout only. It skips when `npm ci` has not run, and fails without GNU `timeout` or `gtimeout` on `PATH` (on macOS, `brew install coreutils`).

CI in `.github/workflows/ci.yml` runs on pushes to `main` and on pull requests when `plugins/**`, `plugin-tests/**`, `.mcp-sdk.lock`, `.shellcheckrc`, `.gitignore`, `.github/workflows/ci.yml`, `.github/workflows/npm-publish.yml`, `.github/scripts/**`, `package.json`, `package-lock.json`, `tsconfig.json`, or `eslint.config.mjs` change. Its Ubuntu job checks out the repository, sets up Node.js 24, and runs `npm ci`. It installs jq, then runs the version check, type-check, lint, and Node tests. Next it installs ShellCheck 0.11.0 and runs ShellCheck and the vendored SDK check. Finally it installs BATS core 1.14.0 and assert 2.2.4 (with support), then runs the BATS suite. Documentation-only changes outside those paths do not trigger CI.

## Development workflow

Read `plugins/clipboard-copy/AGENTS.md` before editing plugin behavior. Update `plugins/clipboard-copy/README.md` when its tool or hook behavior changes, and add user-visible changes to `plugins/clipboard-copy/CHANGELOG.md`. Run the checks under Testing before asking for review.

## Local validation

```bash
claude plugin validate .
codex plugin marketplace add /path/to/clipboard-agent-tools
codex plugin list --available --json
codex plugin add clipboard-copy@clipboard-agent-tools
pi install /path/to/clipboard-agent-tools
pi list
```

The Codex and Pi smoke-test commands alter your Codex and Pi configuration; run them only when you intend to install locally. Pi loads a local path in place, without copying it; `pi remove /path/to/clipboard-agent-tools` removes it again.

## Version bumps

Set the release version in `package.json`, `plugins/clipboard-copy/.claude-plugin/plugin.json`, `plugins/clipboard-copy/.codex-plugin/plugin.json`, and `serverInfo.version` in `plugins/clipboard-copy/mcp-server-clipboard/config.json`, then add a matching entry to `plugins/clipboard-copy/CHANGELOG.md`. The Codex manifest carries a build suffix after `+` (`"version": "1.3.0+codex.<timestamp>"`); the part before `+` must equal the Claude Code manifest version. `.github/scripts/check-versions.sh` compares all four; CI runs it with no argument, and `npm-publish.yml` passes the tag so a publish also requires the tag to match. The script exits 1 and names the file when a manifest has no version or an empty one.

## Pre-release checklist

- [ ] `claude plugin validate .` passes and the Codex marketplace add/list/install smoke test succeeds.
- [ ] `package.json`, both plugin manifests, and `config.json` carry the same release version before the Codex `+codex.<timestamp>` suffix. `.github/scripts/check-versions.sh` passes, and the CHANGELOG has the matching entry.
- [ ] `npm run typecheck`, `npm run lint`, and `npm test` pass.
- [ ] BATS and ShellCheck pass, `pi_e2e.bats` included; `.github/scripts/vendor-mcp-sdk.sh --check` passes.
- [ ] The release tag is `v` plus the release version.
- [ ] CI is green for the release change.

## Distribution

Users install this repository as a marketplace. Claude Code runs `/plugin marketplace add it-bens-ai/clipboard-agent-tools` then `/plugin install clipboard-copy@clipboard-agent-tools`; Codex runs `codex plugin marketplace add it-bens-ai/clipboard-agent-tools` then `codex plugin add clipboard-copy@clipboard-agent-tools`. Pi runs `pi install npm:@it-bens-ai/clipboard-agent-tools` or `pi install git:github.com/it-bens-ai/clipboard-agent-tools`. See README §Install for host restart instructions.

The npm package is not on the registry yet, so `pi install npm:@it-bens-ai/clipboard-agent-tools` returns 404 until the first publish. Publish it with the release that ships Pi support: bump all four versions under Version bumps, add the CHANGELOG entry, tag, and publish. Never publish 1.3.0, which predates Pi support.

Pushing a `v*` tag runs `.github/workflows/npm-publish.yml`. It publishes only a commit that is contained in `origin/main`, and it repeats the Node, ShellCheck, SDK pin, and BATS checks. It also requires the tag to match the versions listed under Version bumps. Publishing uses npm trusted publishing (GitHub OIDC, no token). Trusted publishing cannot create a package, so the first version is published by hand; the workflow skips `npm publish` when the tagged version is already on the registry.

## Commit Messages

Use conventional-commit format. Do not `git add` or commit until asked.
