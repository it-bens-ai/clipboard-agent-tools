#!/bin/bash
# Core test fixtures shared across all plugin hook tests

# Calculate repo root by walking up until we find .bats/ directory
_get_repo_root() {
    local test_dir="${BATS_TEST_DIRNAME}"
    while [[ ! -d "${test_dir}/.bats" ]] && [[ "${test_dir}" != "/" ]]; do
        test_dir="$(dirname "$test_dir")"
    done
    echo "$test_dir"
}

REPO_ROOT="$(_get_repo_root)"

# Load BATS helper libraries
load "${REPO_ROOT}/.bats/bats-support/load"
load "${REPO_ROOT}/.bats/bats-assert/load"

# Create JSON input for hook scripts
make_hook_input() {
    local command="$1"
    jq -cn --arg cmd "$command" '{tool_input: {command: $cmd}}'
}

# Run a hook script with a command and capture output
# Note: SCRIPTS_DIR must be set by the plugin-specific helper
run_hook() {
    local script="$1"
    local command="$2"

    if [[ -z "${SCRIPTS_DIR:-}" ]]; then
        fail "SCRIPTS_DIR must be set before calling run_hook"
    fi

    local payload
    payload=$(make_hook_input "$command")
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "${SCRIPTS_DIR}/${script}"
}

# Assert the hook rejects a clipboard write and suggests the expected MCP tool.
assert_hook_blocks() {
    local script="$1" command="$2" suggestion="$3"
    run_hook "$script" "$command"
    assert_failure 2
    assert_output --partial "$suggestion"
}
