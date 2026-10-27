#!/usr/bin/env bats
# bats file_tags=clipboard-copy,session-start
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

PROMPTS_DIR="${PLUGIN_DIR}/hooks/prompts"

run_session_start() {
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run env -u CLIPBOARD_COPY_HOST bash -c 'echo "{}" | bash "$1"' _ "$SESSION_SCRIPT"
}

# Run a session-start script with the given CLIPBOARD_COPY_HOST, stderr kept apart.
# Arguments: host value, script path.
run_session_start_on_host() {
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr env CLIPBOARD_COPY_HOST="$1" bash -c 'echo "{}" | bash "$1"' _ "$2"
}

# Print the SessionStart JSON the script emits for a given additionalContext,
# in the script's exact layout.
# Arguments: additionalContext as a JSON string.
session_start_json() {
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": %s\n  }\n}' "$1"
}

extract_context() {
    echo "$output" | jq -r '.hookSpecificOutput.additionalContext'
}

# ============================================================================
# JSON output structure
# ============================================================================

# bats test_tags=output
@test "outputs valid JSON" {
    run_session_start
    assert_success
    echo "$output" | jq -e . >/dev/null
}

@test "hookEventName is SessionStart" {
    run_session_start
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
}

@test "additionalContext is a non-empty string" {
    run_session_start
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | type == "string"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null
}

# ============================================================================
# Directive content — names tools and the Bash commands they replace
# ============================================================================

# bats test_tags=content
@test "directive opens with ALWAYS / NEVER framing" {
    run_session_start
    assert_success
    local context
    context=$(extract_context)
    [[ "$context" == *"ALWAYS"*"clipboard-copy MCP tools"* ]]
    [[ "$context" == *"NEVER"*"Bash"* ]]
}

@test "directive names both MCP tools" {
    run_session_start
    assert_success
    local context
    context=$(extract_context)
    [[ "$context" == *"clipboard_copy("* ]]
    [[ "$context" == *"clipboard_copy_file("* ]]
}

@test "directive lists every blocked Bash command" {
    run_session_start
    assert_success
    local context
    context=$(extract_context)
    [[ "$context" == *"pbcopy"* ]]
    [[ "$context" == *"wl-copy"* ]]
    [[ "$context" == *"xclip"* ]]
    [[ "$context" == *"xsel"* ]]
    [[ "$context" == *"clip.exe"* ]]
    [[ "$context" == *"clip"* ]]
}

@test "directive bans reprinting copied content into the session" {
    run_session_start
    assert_success
    local context
    context=$(extract_context)
    [[ "$context" == *"NEVER print the copied content into the session"* ]]
    [[ "$context" == *"overrides an instruction to output that same content"* ]]
}

@test "directive notes paste-mode reads remain available via Bash" {
    run_session_start
    assert_success
    local context
    context=$(extract_context)
    [[ "$context" == *"pbpaste"* ]]
    [[ "$context" == *"xclip -o"* ]]
}

# ============================================================================
# Host selection — CLIPBOARD_COPY_HOST
# ============================================================================

# bats test_tags=host
@test "without CLIPBOARD_COPY_HOST the output carries the shared directive alone" {
    local expected
    expected=$(session_start_json "$(jq -Rs '.' < "${PROMPTS_DIR}/mcp-tool-directives.md")")

    run_session_start

    assert_success
    assert_output "${expected}"
}

# bats test_tags=host
@test "an empty CLIPBOARD_COPY_HOST counts as unset" {
    local expected
    expected=$(session_start_json "$(jq -Rs '.' < "${PROMPTS_DIR}/mcp-tool-directives.md")")

    run_session_start_on_host "" "$SESSION_SCRIPT"

    assert_success
    assert_output "${expected}"
}

# bats test_tags=host,pi
@test "on pi the shared directive is followed by a blank line and the pi addendum" {
    { cat "${PROMPTS_DIR}/mcp-tool-directives.md"; printf '\n'; cat "${PROMPTS_DIR}/host-pi.md"; } \
        > "${BATS_TEST_TMPDIR}/expected"

    run_session_start_on_host pi "$SESSION_SCRIPT"

    assert_success
    jq -j '.hookSpecificOutput.additionalContext' <<<"${output}" > "${BATS_TEST_TMPDIR}/actual"
    run diff "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/actual"
    assert_success
}

# bats test_tags=host,pi,content
@test "the pi addendum names both tools as pi exposes them and how to load them" {
    run_session_start_on_host pi "$SESSION_SCRIPT"

    assert_success
    local context
    context=$(extract_context)
    [[ "$context" == *"\`mcp__clipboard_copy__clipboard_copy\`"* ]] || fail "clipboard_copy is not named as pi exposes it"
    [[ "$context" == *"\`mcp__clipboard_copy__clipboard_copy_file\`"* ]] || fail "clipboard_copy_file is not named as pi exposes it"
    [[ "$context" == *"\`tool_search\`"*"\`limit: 1\`"* ]] || fail "the tool_search instruction is missing"
}

# bats test_tags=host,error
@test "an unsupported CLIPBOARD_COPY_HOST fails with a message naming it" {
    run_session_start_on_host claude "$SESSION_SCRIPT"

    assert_failure 1
    assert_output ""
    [[ "${stderr}" == 'clipboard-copy: unsupported CLIPBOARD_COPY_HOST "claude"; expected pi or unset' ]] \
        || fail "unexpected stderr: ${stderr}"
}

# bats test_tags=host,error
@test "session-start and the bash check reject an unsupported host with the same message" {
    local gate_status=0 gate_message session_status=0 session_message

    gate_message=$(make_hook_input "echo hi | pbcopy" | CLIPBOARD_COPY_HOST=codex bash "${SCRIPTS_DIR}/check-clipboard.sh" 2>&1 >/dev/null) || gate_status=$?
    session_message=$(echo "{}" | CLIPBOARD_COPY_HOST=codex bash "$SESSION_SCRIPT" 2>&1 >/dev/null) || session_status=$?

    assert_equal "$gate_status" 1
    assert_equal "$session_status" 1
    assert_equal "$gate_message" 'clipboard-copy: unsupported CLIPBOARD_COPY_HOST "codex"; expected pi or unset'
    assert_equal "$session_message" "$gate_message"
}

# bats test_tags=host,pi,error
@test "on pi a missing addendum fails instead of emitting the directive without it" {
    local hooks="${BATS_TEST_TMPDIR}/hooks"
    mkdir -p "${hooks}/scripts/lib" "${hooks}/prompts"
    cp "$SESSION_SCRIPT" "${hooks}/scripts/session-start.sh"
    cp "${SCRIPTS_DIR}/lib/common.sh" "${hooks}/scripts/lib/"
    cp "${PROMPTS_DIR}/mcp-tool-directives.md" "${hooks}/prompts/"

    run_session_start_on_host pi "${hooks}/scripts/session-start.sh"

    assert_failure 1
    assert_output ""
    [[ "${stderr}" == "clipboard-copy: the pi addendum is missing: ${hooks}/prompts/host-pi.md" ]] \
        || fail "unexpected stderr: ${stderr}"
}

# ============================================================================
# Failure when a required input is missing
# ============================================================================

# bats test_tags=fallback,error
@test "a missing directive template fails with a message naming its path" {
    # The real hooks/scripts layout without a sibling hooks/prompts directory,
    # so the template check is the first one to trip.
    local hooks="${BATS_TEST_TMPDIR}/hooks"
    mkdir -p "${hooks}/scripts/lib"
    cp "$SESSION_SCRIPT" "${hooks}/scripts/session-start.sh"
    cp "${SCRIPTS_DIR}/lib/common.sh" "${hooks}/scripts/lib/"

    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr bash -c 'echo "{}" | bash "$1"' _ "${hooks}/scripts/session-start.sh"

    assert_failure 1
    assert_output ""
    assert_equal "${stderr}" "clipboard-copy: the directive template is missing: ${hooks}/prompts/mcp-tool-directives.md"
}

# bats test_tags=fallback,error
@test "a missing jq fails with a message naming jq" {
    # A PATH holding bash, cat, and dirname but no jq: the script reaches its
    # jq check and nothing else trips first.
    local bin="${BATS_TEST_TMPDIR}/bin" tool
    mkdir -p "$bin"
    for tool in bash cat dirname; do
        ln -s "$(command -v "$tool")" "${bin}/${tool}"
    done

    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr bash -c 'echo "{}" | PATH="$1" bash "$2"' _ "$bin" "$SESSION_SCRIPT"

    assert_failure 1
    assert_output ""
    assert_equal "${stderr}" "clipboard-copy: jq is required to emit the directive"
}
