## Post-Step-9

For changes under `plugins/clipboard-copy/` or `plugin-tests/clipboard-copy/`, use the scope `clipboard-copy`, even when other files change too. Omit the scope when only repository-level files change (marketplace manifests, root docs, `.github/`, `.claude/`).

## Post-Step-10

Put identifiers, file paths, flags and patterns in the body in backticks, and keep the subject plain. Describe the change as it lands: no origin story, review rounds or fix history. In squash mode, leave out documentation syncs (README, AGENTS.md, CHANGELOG) and version bumps.
