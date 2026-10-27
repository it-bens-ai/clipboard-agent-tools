#!/usr/bin/env bash
# Inject the clipboard-copy MCP tool usage directives into conversation context.
# Claude Code and Codex run it as a SessionStart hook; the Pi extension runs it
# directly. Reads the static template from hooks/prompts/mcp-tool-directives.md,
# appends hooks/prompts/host-pi.md when CLIPBOARD_COPY_HOST is pi, and emits the
# result as JSON additionalContext on stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

cat > /dev/null  # drain stdin

HOOK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROMPT_FILE="${HOOK_DIR}/prompts/mcp-tool-directives.md"
HOST_PI_FILE="${HOOK_DIR}/prompts/host-pi.md"

validate_clipboard_host
HOST="${CLIPBOARD_COPY_HOST:-}"

if [[ ! -f "$PROMPT_FILE" ]]; then
    printf 'clipboard-copy: the directive template is missing: %s\n' "$PROMPT_FILE" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'clipboard-copy: jq is required to emit the directive\n' >&2
    exit 1
fi

if [[ "$HOST" == "pi" ]]; then
    if [[ ! -f "$HOST_PI_FILE" ]]; then
        printf 'clipboard-copy: the pi addendum is missing: %s\n' "$HOST_PI_FILE" >&2
        exit 1
    fi
    # The directive ends in a newline, so the extra one leaves a blank line before the addendum.
    context=$({ cat "$PROMPT_FILE"; printf '\n'; cat "$HOST_PI_FILE"; } | jq -Rs '.')
else
    context=$(jq -Rs '.' < "$PROMPT_FILE")
fi
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ${context}
  }
}
EOF

exit 0
