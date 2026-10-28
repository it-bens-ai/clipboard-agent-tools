# Releasing

A release sets one version across the package and plugin manifests, passes the checks in [Development](development.md#testing), and is published to npm by pushing a `v*` tag. Claude Code and Codex users install from the repository itself; see the README's [Install](../README.md#install) section.

## Version bumps

Set the release version in `package.json`, `plugins/clipboard-copy/.claude-plugin/plugin.json`, `plugins/clipboard-copy/.codex-plugin/plugin.json`, and `serverInfo.version` in `plugins/clipboard-copy/mcp-server-clipboard/config.json`, then add a matching entry to `plugins/clipboard-copy/CHANGELOG.md`. The Codex manifest carries a build suffix after `+` (`"version": "2.0.0+codex.<timestamp>"`); the part before `+` must equal the Claude Code manifest version.

`.github/scripts/check-versions.sh` compares all four. CI runs it with no argument, and `npm-publish.yml` passes the tag so a publish also requires the tag to match. The script exits 1 and names the file when a manifest has no version or an empty one.

## Pre-release checklist

- [ ] `claude plugin validate .` passes and the Codex marketplace add/list/install smoke test succeeds (see [Local validation](development.md#local-validation)).
- [ ] `package.json`, both plugin manifests, and `config.json` carry the same release version before the Codex `+codex.<timestamp>` suffix. `.github/scripts/check-versions.sh` passes, and the CHANGELOG has the matching entry.
- [ ] `npm run typecheck`, `npm run lint`, and `npm test` pass.
- [ ] BATS and ShellCheck pass, `pi_e2e.bats` included; `.github/scripts/vendor-mcp-sdk.sh --check` passes.
- [ ] The release tag is `v` plus the release version.
- [ ] CI is green for the release change.

## Publishing to npm

Pushing a `v*` tag runs `.github/workflows/npm-publish.yml`. It stages only a commit that is contained in `origin/main`, and it repeats the Node, ShellCheck, SDK pin, and BATS checks. It also requires the tag to match the versions listed under [Version bumps](#version-bumps).

The workflow authenticates with npm trusted publishing (GitHub OIDC, no token), and the trusted publisher allows `npm stage publish` only. The workflow stages the version, and it goes live once a maintainer approves it with 2FA: `npm stage list` shows the stage ID, and `npm stage approve <stage-id>` publishes it.

Trusted publishing cannot create a package, so the first version was published by hand. The workflow skips staging when the tagged version is already on the registry.
