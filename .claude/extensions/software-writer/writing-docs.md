## Named-value assignments

- `docs.surfaces` =
  | Surface | Owns | Shape | Single-owner |
  |---|---|---|---|
  | `README.md` | Marketplace pitch, requirements, per-host install commands, pointers into plugin docs | Root README | enforced |
  | `AGENTS.md` | Host model (Claude Code, Codex, Pi), repository architecture, test commands, version bumps | Architecture document | enforced |
  | `plugins/clipboard-copy/README.md` | Tool catalog, backend detection order, hook behavior, plugin layout, requirements | Module README | enforced |
  | `plugins/clipboard-copy/AGENTS.md` | Plugin file layout, key functions, task-to-file navigation, MCP wire flow, test suites, manual smoke tests | Module architecture and navigation document | enforced |
  | `plugins/clipboard-copy/CHANGELOG.md` | Released changes per version | Changelog | exempt: each entry restates what its release changed |

  Runtime prompt text under `plugins/clipboard-copy/hooks/prompts/` is a runtime file, not a documentation surface.
- `docs.pointer_file` = none; the repository tracks no `CLAUDE.md`, and `AGENTS.md` opens with `@README.md`
- `docs.jargon_home` = `AGENTS.md`
- `docs.changelog` = `plugins/clipboard-copy/CHANGELOG.md`; Keep a Changelog with `## [x.y.z] - YYYY-MM-DD` entries. Each release version matches `package.json`, `plugins/clipboard-copy/.claude-plugin/plugin.json`, the part before `+` in `plugins/clipboard-copy/.codex-plugin/plugin.json`, and `serverInfo.version` in `plugins/clipboard-copy/mcp-server-clipboard/config.json`

## Post-Step-5

When the change documents altered tool behavior, confirm both `plugins/clipboard-copy/README.md` and `plugins/clipboard-copy/AGENTS.md` were updated, then add or extend the `plugins/clipboard-copy/CHANGELOG.md` entry for the release.

Before finishing, re-check every path, command, and file name the diff introduces against the repository. No CI checks documentation here.
