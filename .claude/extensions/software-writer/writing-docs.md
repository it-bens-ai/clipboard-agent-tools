## Named-value assignments

- `docs.surfaces` =
  | Surface | Owns | Shape | Single-owner |
  |---|---|---|---|
  | `README.md` | Marketplace pitch, requirements, per-host install commands, pointers into the docs | Root README | enforced |
  | `AGENTS.md` | Routing to the repository docs, repository working rules for agents | LLM pointer file | enforced |
  | `docs/development.md` | Host model (Claude Code, Codex, Pi), repository layout, vendored MCP SDK, test commands, CI, local validation | Architecture document | enforced |
  | `docs/releasing.md` | Version bumps, pre-release checklist, npm publishing | Procedural guide | enforced |
  | `plugins/clipboard-copy/README.md` | Plugin introduction, tool summary, index of the plugin docs | Module README | enforced |
  | `plugins/clipboard-copy/AGENTS.md` | Task-to-file navigation, plugin editing rules for agents, routing to the plugin docs | LLM pointer file | enforced |
  | `plugins/clipboard-copy/docs/tools.md` | Tool arguments, result text, schema validation, startup failure on a bad `tools.json`, no-echo rule in the tool descriptions | Module topic guide | enforced |
  | `plugins/clipboard-copy/docs/backends.md` | Backend detection order, native utilities, OSC 52 fallback, supported terminals | Module topic guide | enforced |
  | `plugins/clipboard-copy/docs/hooks.md` | Plugin-root resolution, SessionStart directive, Bash block matrix, hook exit codes, unsupported host | Module topic guide | enforced |
  | `plugins/clipboard-copy/docs/pi.md` | Pi package wiring, supported Pi and Node versions, Pi tool names, Pi directive, Pi Bash check, OSC 52 on Pi | Module topic guide | enforced |
  | `plugins/clipboard-copy/docs/troubleshooting.md` | Failure symptoms and fixes | Module topic guide | enforced |
  | `plugins/clipboard-copy/docs/architecture.md` | Plugin file layout, MCP wire flow, key function contracts | Architecture document | enforced |
  | `plugins/clipboard-copy/docs/testing.md` | Plugin test suites and tags, mocking helpers, manual smoke tests, Codex smoke test | Module topic guide | enforced |
  | `plugins/clipboard-copy/CHANGELOG.md` | Released changes per version | Changelog | exempt: each entry restates what its release changed |

  Runtime prompt text under `plugins/clipboard-copy/hooks/prompts/` is a runtime file, not a documentation surface.
- `docs.pointer_file` = `AGENTS.md`. Both `AGENTS.md` files route with plain file paths and no `@` include. `plugins/clipboard-copy/AGENTS.md` also keeps its `## Navigation` task-to-file table, which is exempt from the pointer line limit.
- `docs.jargon_home` = none; each topic doc defines the terms it uses
- `docs.changelog` = `plugins/clipboard-copy/CHANGELOG.md`; Keep a Changelog with `## [x.y.z] - YYYY-MM-DD` entries. Each release version matches `package.json`, `plugins/clipboard-copy/.claude-plugin/plugin.json`, the part before `+` in `plugins/clipboard-copy/.codex-plugin/plugin.json`, and `serverInfo.version` in `plugins/clipboard-copy/mcp-server-clipboard/config.json`

## Post-Step-5

When the change documents altered tool, backend, hook, or Pi behavior, update the `plugins/clipboard-copy/docs/` file that owns it per `docs.surfaces`, and the one-line tool summary in `plugins/clipboard-copy/README.md` when a tool is added, removed, or renamed. Update `plugins/clipboard-copy/AGENTS.md` §Navigation when a file or function moves. Then add or extend the `## [Unreleased]` entry in `plugins/clipboard-copy/CHANGELOG.md`.

Before finishing, re-check every path, command, and file name the diff introduces against the repository. No CI checks documentation here.
