#!/bin/bash
# Shared JSON-RPC driver for suites that run mcp-server-clipboard/server.sh.
# The suite sets SERVER to the server path before the tests run.

# Send one tools/call request to the server and keep its JSON-RPC response.
# Arguments: tool name, arguments JSON object.
call_tool() {
    local request
    request=$(jq -cn --arg name "$1" --argjson args "$2" \
        '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$name,arguments:$args}}')
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr bash -c 'printf "%s\n" "$1" | bash "$2"' _ "${request}" "${SERVER}"
}
