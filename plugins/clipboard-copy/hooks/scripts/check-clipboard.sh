#!/bin/bash
# Clipboard-copy MCP enforcer.
# Blocks native clipboard-write Bash commands in favor of the
# clipboard_copy / clipboard_copy_file MCP tools.
#
# Read-only invocations of xclip/xsel (-o / --output) are NOT blocked —
# this hook targets only writes to the system clipboard. pbpaste,
# wl-paste, and similar paste utilities are likewise not touched.
#
# Exit codes:
#   0 - command allowed
#   1 - unsupported CLIPBOARD_COPY_HOST
#   2 - command blocked with a message shown to the agent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_hook_input
validate_clipboard_host

HINT="Use clipboard_copy with the text directly, or clipboard_copy_file with an absolute path when the content is already on disk."

# pbcopy (macOS) — always writes to clipboard.
if echo "$COMMAND" | grep -qE '(^|;|&&|\|)\s*pbcopy(\s|$)'; then
    block_clipboard "clipboard_copy" "$HINT"
fi

# wl-copy (Linux Wayland) — always writes to clipboard.
if echo "$COMMAND" | grep -qE '(^|;|&&|\|)\s*wl-copy(\s|$)'; then
    block_clipboard "clipboard_copy" "$HINT"
fi

# clip.exe (WSL) — always writes to clipboard.
if echo "$COMMAND" | grep -qE '(^|;|&&|\|)\s*clip\.exe(\s|$)'; then
    block_clipboard "clipboard_copy" "$HINT"
fi

# clip (Windows Cygwin/MSYS) — always writes to clipboard.
# Anchored to the start of a command segment to avoid matching unrelated
# binaries like 'clipper' or paths containing 'clip-'.
if echo "$COMMAND" | grep -qE '(^|;|&&|\|)\s*clip(\s|$)'; then
    block_clipboard "clipboard_copy" "$HINT"
fi

#######################################
# Block a command whose xclip or xsel call has no paste flag of its own.
# Both tools write to the clipboard unless the call asks for a paste, so
# every call needs -o / -out / --output before the next |, ; or &.
# Globals:
#   COMMAND - the Bash command being checked.
# Arguments:
#   $1 - tool name, interpolated into the segment regex unescaped; callers
#        pass a plain name such as xclip, never a pattern.
#   $2 - POSIX ERE that a paste call of that tool matches.
#   $3 - hint naming the paste flags, appended to the block message.
# Outputs:
#   Nothing on stdout; the block message goes to stderr.
# Returns:
#   Does not return when a call lacks a paste flag: it exits 2 through
#   block_clipboard. A scan that fails also blocks, so no failure is read as
#   a paste. Otherwise returns 0.
#######################################
check_paste_segments() {
    local tool="$1" paste_pattern="$2" hint="$3"
    local segment_pattern segments segment rc

    [[ $COMMAND == *"$tool"* ]] || return 0

    segment_pattern="(^|;|&&|\|)[[:space:]]*${tool}([[:space:]]|$)[^|;&]*"
    rc=0
    segments=$(printf '%s\n' "$COMMAND" | grep -oE "$segment_pattern") || rc=$?
    if (( rc >= 2 )); then
        block_clipboard "clipboard_copy" "$HINT $hint"
    fi

    while IFS= read -r segment; do
        # An empty $segments still gives one empty line here; testing it would
        # block a command that only mentions the name, such as "echo xclipo".
        [[ -n $segment ]] || continue
        # No match (status 1) and an invalid pattern (status 2) both block.
        if [[ ! $segment =~ $paste_pattern ]]; then
            block_clipboard "clipboard_copy" "$HINT $hint"
        fi
    done <<< "$segments"
}

check_paste_segments "xclip" 'xclip[^|;&]*[[:space:]]-o(ut)?([[:space:]]|$)' \
    '(xclip -o / -out for paste is allowed.)'
check_paste_segments "xsel" 'xsel[^|;&]*[[:space:]](-o|--output)([[:space:]]|$)' \
    '(xsel -o / --output for paste is allowed.)'

exit 0
