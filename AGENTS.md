# Clipboard Agent Tools — Agent Guide

This file routes tasks to files and lists the rules for working in the repository.

## Documentation

| Topic | File |
|---|---|
| Pitch, requirements, install commands | `README.md` |
| Hosts, layout, SDK, tests, CI | `docs/development.md` |
| Versions, checklist, npm publishing | `docs/releasing.md` |
| Plugin navigation and editing rules | `plugins/clipboard-copy/AGENTS.md` |
| Plugin behavior and topic docs | `plugins/clipboard-copy/README.md` |
| Released changes | `plugins/clipboard-copy/CHANGELOG.md` |

Plugin changes start at `plugins/clipboard-copy/AGENTS.md`.

## Rules

- Do not `git add` or commit until asked. Commit messages use conventional-commit format.
- Run the checks in `docs/development.md` §Testing before asking for review.
- Never edit `plugins/clipboard-copy/shared/mcpserver_core.sh`; change `.mcp-sdk.lock` and re-vendor with `.github/scripts/vendor-mcp-sdk.sh` (`docs/development.md` §Vendored MCP SDK).
- The Codex and Pi commands in `docs/development.md` §Local validation alter the user's Codex and Pi configuration. Run them only when the task is to install locally.
- A change to `package.json` `files` changes what npm publishes; keep `docs/development.md` §Hosts in step with it.
