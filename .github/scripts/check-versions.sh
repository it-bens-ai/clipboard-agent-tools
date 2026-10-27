#!/usr/bin/env bash
# Checks that every manifest carries the same release version. With a tag argument it also requires
# the tag (leading "v" accepted) to name that version, so a publish runs only for a tagged release.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if [[ $# -gt 1 ]]; then
    printf 'usage: %s [tag]\n' "${0##*/}" >&2
    exit 2
fi

# Reads one manifest's version string. `jq -e` fails on a missing field, which
# it would otherwise print as `null`; an empty string still passes that test, so
# it is refused here too. Either failure names the file and exits.
# Args: $1=manifest path relative to the repository root, $2=jq path to the field
manifest_version() {
    local file="$1" query="$2" version
    if ! version=$(jq -er "${query}" "${repo_root}/${file}"); then
        printf 'Version check: %s carries no version at %s\n' "${file}" "${query}" >&2
        exit 1
    fi
    if [[ -z "${version}" ]]; then
        printf 'Version check: %s carries an empty version at %s\n' "${file}" "${query}" >&2
        exit 1
    fi
    printf '%s\n' "${version}"
}

package_version=$(manifest_version package.json '.version')
claude_version=$(manifest_version plugins/clipboard-copy/.claude-plugin/plugin.json '.version')
codex_version=$(manifest_version plugins/clipboard-copy/.codex-plugin/plugin.json '.version')
codex_version="${codex_version%%+*}"
config_version=$(manifest_version plugins/clipboard-copy/mcp-server-clipboard/config.json '.serverInfo.version')

problems=()
for entry in \
    "package.json=${package_version}" \
    "plugins/clipboard-copy/.claude-plugin/plugin.json=${claude_version}" \
    "plugins/clipboard-copy/.codex-plugin/plugin.json=${codex_version}" \
    "plugins/clipboard-copy/mcp-server-clipboard/config.json=${config_version}"; do
    if [[ "${entry#*=}" != "${package_version}" ]]; then
        problems+=("${entry}")
    fi
done

if [[ $# -eq 1 ]]; then
    tag_version="${1#v}"
    if [[ "${tag_version}" != "${package_version}" ]]; then
        problems+=("tag=${1}")
    fi
fi

if [[ ${#problems[@]} -gt 0 ]]; then
    printf 'Version mismatch: package.json is %s, but:\n' "${package_version}" >&2
    printf '  %s\n' "${problems[@]}" >&2
    exit 1
fi

printf 'Versions agree: %s\n' "${package_version}"
