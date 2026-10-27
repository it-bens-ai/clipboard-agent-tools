#!/usr/bin/env bats
# bats file_tags=clipboard-copy,dispatch
bats_require_minimum_version 1.11.0
load 'test_helper/common_setup'

setup() {
    PLUGIN_COPY="${BATS_TEST_TMPDIR}/plugin"
    cp -R "${PLUGIN_DIR}" "${PLUGIN_COPY}"
    printf '\ntool_undeclared_probe() { printf "unexpected dispatch\\n"; }\n' \
        >> "${PLUGIN_COPY}/mcp-server-clipboard/lib/clipboard.sh"
}

call_tool() {
    local request
    request=$(jq -nc --arg name "$1" \
        '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$name,arguments:{}}}')
    printf '%s\n' "$request" | bash "${PLUGIN_COPY}/mcp-server-clipboard/server.sh" 2>/dev/null \
        | jq -c 'select(.id == 1)'
}

@test "an undeclared sourced tool cannot be dispatched" {
    run call_tool undeclared_probe
    assert_success
    jq -e '.error.code == -32601 and (.error.message | contains("Tool not found"))' \
        <<<"${output}" >/dev/null
}

@test "a declared tool still reaches its argument validation" {
    run call_tool clipboard_copy
    assert_success
    jq -e '.result.isError == true and (.result.content[0].text | contains("text"))' \
        <<<"${output}" >/dev/null
}
