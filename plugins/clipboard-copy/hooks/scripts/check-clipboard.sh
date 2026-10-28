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

# Each xclip or xsel segment must have its own paste flag.
check_paste_segments() {
    local tool="$1" paste_pattern="$2" hint="$3"
    local remaining segment_pattern segment
    segment_pattern="(^|;|&&|\|)[[:space:]]*${tool}([[:space:]]|$)[^|;&]*"

    while IFS= read -r remaining; do
        while [[ "$remaining" =~ $segment_pattern ]]; do
            segment="${BASH_REMATCH[0]}"
            remaining="${remaining#*"$segment"}"
            if [[ ! "$segment" =~ $paste_pattern ]]; then
                block_clipboard "clipboard_copy" "$HINT $hint"
            fi
        done
    done <<< "$COMMAND"
}

check_paste_segments "xclip" 'xclip[^|;&]*[[:space:]]-o(ut)?([[:space:]]|$)' \
    '(xclip -o / -out for paste is allowed.)'
check_paste_segments "xsel" 'xsel[^|;&]*[[:space:]](-o|--output)([[:space:]]|$)' \
    '(xsel -o / --output for paste is allowed.)'

exit 0
