#!/bin/bash
# Shared functions for the clipboard-copy hook scripts. Claude Code and Codex
# run them as hooks; the Pi extension runs them directly.
#
# Globals set by parse_hook_input:
#   COMMAND - The bash command being checked

# Read the JSON tool-call input from stdin and extract .tool_input.command.
# Exits 0 (allow) when the command field is empty so we never block on
# malformed/empty input.
parse_hook_input() {
    local input
    input=$(cat)
    COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty')
    if [[ -z "$COMMAND" ]]; then
        exit 0
    fi
}

# Reject a CLIPBOARD_COPY_HOST this plugin does not support. Claude Code and
# Codex leave it unset; the Pi extension sets it to pi.
validate_clipboard_host() {
    case "${CLIPBOARD_COPY_HOST:-}" in
        ""|pi)
            ;;
        *)
            printf 'clipboard-copy: unsupported CLIPBOARD_COPY_HOST "%s"; expected pi or unset\n' "${CLIPBOARD_COPY_HOST}" >&2
            exit 1
            ;;
    esac
}

# Block the command with a formatted hint and exit 2 (deny).
# With CLIPBOARD_COPY_HOST=pi, the tool names in the message are spelled the
# way pi exposes them.
# Args:
#   $1 = MCP tool to suggest (e.g. "clipboard_copy")
#   $2 = hint shown to the model
block_clipboard() {
    local tool="$1"
    local hint="$2"

    if [[ "${CLIPBOARD_COPY_HOST:-}" == "pi" ]]; then
        # pi names MCP tools mcp__<server>__<tool>, with the server's hyphen as
        # an underscore. Qualify bare names only: an already-qualified name
        # keeps its prefix, and the [^_] guard does the same in the hint.
        case "$tool" in
            mcp__clipboard_copy__*) ;;
            *) tool="mcp__clipboard_copy__${tool}" ;;
        esac
        hint=$(printf '%s' "$hint" | sed -E 's/(^|[^_])clipboard_copy/\1mcp__clipboard_copy__clipboard_copy/g')
    fi

    {
        echo "Use the ${tool} MCP tool instead."
        echo ""
        echo "Bad command detected: ${COMMAND}"
        echo ""
        echo "${hint}"
        echo ""
        echo "The clipboard-copy MCP tool:"
        echo "  - Auto-detects the right backend per OS (pbcopy / wl-copy / xclip / xsel / clip.exe / clip)"
        echo "  - Falls back to OSC 52 over SSH and in headless environments"
    } >&2
    exit 2
}
