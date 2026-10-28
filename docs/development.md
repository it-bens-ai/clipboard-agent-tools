# Development

This repository packages the `clipboard-copy` plugin as its own installable marketplace. The plugin ships a Bash MCP server, two hooks, a SessionStart directive, and a Pi extension. It has no skills, agents, or slash commands. The repository root is also the npm package `@it-bens-ai/clipboard-agent-tools`, which Pi installs.

The plugin's own documentation, including its file layout and test suites, starts at [`plugins/clipboard-copy/README.md`](../plugins/clipboard-copy/README.md). Releases are covered in [Releasing](releasing.md).

## Hosts

Claude Code reads `.claude-plugin/marketplace.json`, `plugins/clipboard-copy/.claude-plugin/plugin.json`, and `plugins/clipboard-copy/.mcp.json`. Codex reads `.agents/plugins/marketplace.json` and `plugins/clipboard-copy/.codex-plugin/plugin.json`. The MCP server, hook scripts, and directive prompt are shared. The hook launchers resolve the plugin root from Codex's `PLUGIN_ROOT` or Claude Code's `CLAUDE_PLUGIN_ROOT`, and fail when neither is set.

Pi reads the `pi.extensions` field of the root `package.json`, which names `plugins/clipboard-copy/pi/index.ts`. The extension registers the same MCP server and runs `hooks/scripts/session-start.sh` and `hooks/scripts/check-clipboard.sh` from its own event handlers instead of `hooks/hooks.json`. It sets `CLIPBOARD_COPY_HOST=pi` for the server and both scripts, and `CLIPBOARD_COPY_OSC52_DIR` for the server. Claude Code and Codex leave `CLIPBOARD_COPY_HOST` unset; both hook scripts exit 1 on any other value.

The package `files` list limits what npm publishes to the plugin's runtime directories, its `docs/` directory, its README, and its CHANGELOG. npm adds the root `README.md`, `package.json`, and `LICENSE` on its own.

## Repository layout

```
.agents/plugins/marketplace.json         # Codex registry → clipboard-copy
.claude-plugin/marketplace.json          # Claude Code registry → clipboard-copy
package.json                             # Pi package manifest (npm), scripts, dev dependencies
package-lock.json                        # Locked npm dependency tree
tsconfig.json                            # TypeScript type-check settings for the Pi sources and tests
eslint.config.mjs                        # ESLint rules for the TypeScript sources
docs/                                    # Development and release guides
.claude/extensions/software-writer/      # Project extensions for the software-writer skills
plugins/clipboard-copy/                  # THE PLUGIN: MCP server, hooks, host manifests, docs/
plugins/clipboard-copy/pi/               # Pi extension (TypeScript)
plugin-tests/clipboard-copy/             # BATS suites mirroring the plugin structure
plugin-tests/clipboard-copy/pi/          # Node tests for the Pi extension
plugin-tests/test_helper/                # Shared BATS helper
.github/scripts/setup-bats.sh            # Installs BATS into .bats/
.github/scripts/check-versions.sh        # Checks that package.json and every manifest share a version
.github/workflows/ci.yml                 # Path-filtered Node and Bash tests, lint, and version check
.github/workflows/npm-publish.yml        # Publishes the Pi package to npm on v* tags
.github/ISSUE_TEMPLATE/                  # Issue forms
.github/assets/social-preview.png        # README header image and Pi gallery preview (pi.image)
.shellcheckrc                            # ShellCheck rules
renovate.json                            # Dependency update rules
.github/scripts/vendor-mcp-sdk.sh        # Vendors the pinned bash-mcp-sdk core
.mcp-sdk.lock                            # Pinned bash-mcp-sdk release and SHA-256
```

Both marketplace files point at the same plugin root, `./plugins/clipboard-copy`. Claude Code sources use `{"name": "<name>", "source": "./plugins/<name>"}`; Codex sources use `{"source": {"source": "local", "path": "./plugins/<name>"}}`. Paths are relative to the marketplace root, which is the repository root.

## Vendored MCP SDK

`plugins/clipboard-copy/shared/mcpserver_core.sh` is a copy of `lib/mcpserver_core.sh` from [`shopwareLabs/bash-mcp-sdk`](https://github.com/shopwareLabs/bash-mcp-sdk). `.mcp-sdk.lock` pins the release tag (`version=`) and the file's SHA-256 (`sha256=`). The vendored file is not edited in this repository; protocol changes go to the SDK repository.

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

The shared helper at `plugin-tests/test_helper/common_setup.bash` resolves the repository root by walking up to `.bats/`. Each suite loads it through `plugin-tests/clipboard-copy/test_helper/common_setup.bash`, which sets `PLUGIN_DIR`, `SCRIPTS_DIR`, `LIB_DIR`, and `SHARED_DIR`. The plugin's [Testing](../plugins/clipboard-copy/docs/testing.md) guide lists the suites, their tags, and the mocking helpers.

Run the Pi E2E suite with `.bats/bats-core/bin/bats plugin-tests/clipboard-copy/pi_e2e.bats`. See [Testing](../plugins/clipboard-copy/docs/testing.md) for its scenarios and prerequisites.

## CI

CI in `.github/workflows/ci.yml` runs on pushes to `main` and on pull requests when `plugins/**`, `plugin-tests/**`, `.mcp-sdk.lock`, `.shellcheckrc`, `.gitignore`, `.github/workflows/ci.yml`, `.github/workflows/npm-publish.yml`, `.github/scripts/**`, `package.json`, `package-lock.json`, `tsconfig.json`, or `eslint.config.mjs` change. Documentation-only changes outside those paths do not trigger CI.

Its Ubuntu job checks out the repository, sets up Node.js 24, and runs `npm ci`. The job runs as two matrix legs: the `oldest` leg installs Pi 1.0.0 over the locked version after `npm ci` and checks that it was installed, and the `latest` leg keeps the version pinned in `package.json`. To raise the oldest supported version, edit `pi-version` in `ci.yml`.

The job then installs jq and runs the version check, type-check, lint, and Node tests. Next it installs ShellCheck 0.11.0 and runs ShellCheck and the vendored SDK check. Finally it installs BATS core 1.14.0 and assert 2.2.4 (with support), then runs the BATS suite.

## Local validation

```bash
claude plugin validate .
codex plugin marketplace add /path/to/clipboard-agent-tools
codex plugin list --available --json
codex plugin add clipboard-copy@clipboard-agent-tools
pi install /path/to/clipboard-agent-tools
pi list
```

The Codex and Pi commands alter your Codex and Pi configuration; run them only when you intend to install locally. Pi loads a local path in place, without copying it; `pi remove /path/to/clipboard-agent-tools` removes it again.
