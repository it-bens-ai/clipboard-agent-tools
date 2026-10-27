#!/usr/bin/env bats
# bats file_tags=clipboard-copy,tool-schemas
bats_require_minimum_version 1.11.0
load 'test_helper/common_setup'

setup() {
    export MCP_TOOLS_LIST_FILE="${PLUGIN_DIR}/mcp-server-clipboard/tools.json"
    export MCP_CONFIG_FILE="${PLUGIN_DIR}/mcp-server-clipboard/config.json"
    export MCP_LOG_STDERR=1
    source "${SHARED_DIR}/mcpserver_core.sh"
}

@test "every required tool argument appears in its properties" {
    run jq -r '.tools[] | .name as $tool | .inputSchema as $schema
        | ($schema.required // [])[] | . as $field
        | select((($schema.properties // {}) | has($field)) | not)
        | "\($tool) requires \($field) without a property"' "$MCP_TOOLS_LIST_FILE"
    assert_success
    assert_output ''
}

@test "clipboard_copy accepts valid text arguments" {
    run validate_tool_arguments clipboard_copy '{"text":"hello"}'
    assert_success
    assert_output ''
}

@test "clipboard_copy_file accepts an absolute path argument" {
    run validate_tool_arguments clipboard_copy_file '{"path":"/tmp/clipboard-payload"}'
    assert_success
    assert_output ''
}

@test "clipboard_copy rejects missing required text" {
    run validate_tool_arguments clipboard_copy '{}'
    assert_failure
    assert_output --partial 'text'
}

@test "clipboard_copy_file rejects missing required path" {
    run validate_tool_arguments clipboard_copy_file '{}'
    assert_failure
    assert_output --partial 'path'
}
