#!/usr/bin/env bats
# bats file_tags=clipboard-copy,startup
bats_require_minimum_version 1.11.0
load 'test_helper/common_setup'

setup() {
    PLUGIN_COPY="${BATS_TEST_TMPDIR}/plugin"
    cp -R "${PLUGIN_DIR}" "${PLUGIN_COPY}"
    TOOLS="${PLUGIN_COPY}/mcp-server-clipboard/tools.json"
}

run_server() {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        | bash "${PLUGIN_COPY}/mcp-server-clipboard/server.sh"
}

@test "server refuses invalid tools JSON before answering" {
    printf '%s\n' '{invalid' > "${TOOLS}"
    run run_server
    assert_failure
    assert_output --partial 'tools list is missing or invalid'
    refute_output --partial '"jsonrpc"'
}

@test "server refuses multiple tools JSON documents before answering" {
    printf '%s\n%s\n' '{"tools":[]}' '{"tools":[]}' > "${TOOLS}"
    run run_server
    assert_failure
    assert_output --partial 'tools list is missing or invalid'
    refute_output --partial '"jsonrpc"'
}

@test "server refuses a tools list without an array" {
    printf '%s\n' '{"tools":{}}' > "${TOOLS}"
    run run_server
    assert_failure
    assert_output --partial 'tools list is missing or invalid'
    refute_output --partial '"jsonrpc"'
}

@test "server refuses a missing tools list before answering" {
    rm "${TOOLS}"
    run run_server
    assert_failure
    assert_output --partial 'tools list is missing or invalid'
    refute_output --partial '"jsonrpc"'
}

@test "server advertises its shipped tools" {
    run bash -c 'printf "%s\n" \
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}" \
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}" \
        | bash "$1"' _ "${PLUGIN_COPY}/mcp-server-clipboard/server.sh"
    assert_success
    assert_output --partial '"name":"clipboard_copy"'
    assert_output --partial '"name":"clipboard_copy_file"'
}
