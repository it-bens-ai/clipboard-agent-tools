#!/usr/bin/env bash
# Cross-platform clipboard MCP server.
# Provides the clipboard_copy tool, dispatching to the right backend per environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "${SCRIPT_DIR}/../shared" && pwd)"

MCP_CONFIG_FILE="${SCRIPT_DIR}/config.json"
MCP_TOOLS_LIST_FILE="${SCRIPT_DIR}/tools.json"
MCP_LOG_STDERR=1

export SCRIPT_DIR SHARED_DIR MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE MCP_LOG_STDERR

# Sourced before enabling inherit_errexit: the core rejects bash < 5.1 with a
# clear message, while the shopt would fail first on an older shell.
source "${SHARED_DIR}/mcpserver_core.sh"
shopt -s inherit_errexit
source "${SCRIPT_DIR}/lib/clipboard.sh"

trap 'log "ERROR" "Unexpected error on line ${LINENO}"' ERR

if ! jq -e -s 'length == 1 and (.[0] | type) == "object" and (.[0].tools | type) == "array"' \
    -- "${MCP_TOOLS_LIST_FILE}" >/dev/null 2>&1; then
    log "ERROR" "Tools list is missing or invalid: ${MCP_TOOLS_LIST_FILE}"
    printf 'Error: tools list is missing or invalid: %s\n' "${MCP_TOOLS_LIST_FILE}" >&2
    exit 1
fi

log "INFO" "======================================"
log "INFO" "Clipboard MCP Server starting"
log "INFO" "Script dir: ${SCRIPT_DIR}"
log "INFO" "OS: $(uname -s)"
log "INFO" "Detected backend: $(_clipboard_detect_backend)"
log "INFO" "======================================"

run_mcp_server "$@"
