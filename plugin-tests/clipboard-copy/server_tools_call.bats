#!/usr/bin/env bats
# bats file_tags=clipboard-copy,server
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

SERVER="${PLUGIN_DIR}/mcp-server-clipboard/server.sh"

setup() {
    # Stub every backend the detection cascade picks first on macOS (pbcopy),
    # Linux/WSL (clip.exe) and Cygwin/MSYS (clip), so a call that reaches the
    # tool writes into a capture file instead of the real clipboard.
    CAPTURE_FILE="${BATS_TEST_TMPDIR}/clipboard_capture"
    local stub_dir="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${stub_dir}"
    local backend
    for backend in pbcopy clip.exe clip; do
        printf '#!/usr/bin/env bash\ncat > "%s"\n' "${CAPTURE_FILE}" > "${stub_dir}/${backend}"
        chmod +x "${stub_dir}/${backend}"
    done
    PATH="${stub_dir}:${PATH}"
}

# Send one tools/call request to the server and keep its JSON-RPC response.
# Arguments: tool name, arguments JSON object.
call_tool() {
    local request
    request=$(jq -cn --arg name "$1" --argjson args "$2" \
        '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$name,arguments:$args}}')
    run --separate-stderr bash -c 'printf "%s\n" "$1" | bash "$2"' _ "${request}" "${SERVER}"
}

# bats test_tags=success
@test "clipboard_copy_file with an absolute path copies the file's bytes" {
    local f="${BATS_TEST_TMPDIR}/payload.txt"
    printf 'from disk\n' > "$f"

    call_tool clipboard_copy_file "{\"path\":\"${f}\"}"

    assert_success
    jq -e '.id == 1 and (.result.isError | not)' <<<"${output}" >/dev/null
    run cmp "${CAPTURE_FILE}" "$f"
    assert_success
}

# bats test_tags=validate,relative
@test "clipboard_copy_file with a relative path is refused before the tool runs" {
    call_tool clipboard_copy_file '{"path":"relative.txt"}'

    assert_success
    jq -e '.result.isError == true' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("path=\"relative.txt\" does not match pattern ^/")' \
        <<<"${output}" >/dev/null
    [[ ! -e "${CAPTURE_FILE}" ]] || fail "the tool ran and wrote to the clipboard"
}

# bats test_tags=validate,unknown
@test "clipboard_copy with an undeclared argument is refused before the tool runs" {
    call_tool clipboard_copy '{"text":"hello","extra":1}'

    assert_success
    jq -e '.result.isError == true' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("Unknown parameter(s): extra")' <<<"${output}" >/dev/null
    [[ ! -e "${CAPTURE_FILE}" ]] || fail "the tool ran and wrote to the clipboard"
}

# bats test_tags=validate,unknown
@test "clipboard_copy_file with an undeclared argument is refused before the tool runs" {
    local f="${BATS_TEST_TMPDIR}/payload.txt"
    printf 'from disk\n' > "$f"

    call_tool clipboard_copy_file "{\"path\":\"${f}\",\"extra\":1}"

    assert_success
    jq -e '.result.isError == true' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("Unknown parameter(s): extra")' <<<"${output}" >/dev/null
    [[ ! -e "${CAPTURE_FILE}" ]] || fail "the tool ran and wrote to the clipboard"
}

# bats test_tags=validate,type
@test "clipboard_copy with a non-string text is refused before the tool runs" {
    call_tool clipboard_copy '{"text":5}'

    assert_success
    jq -e '.result.isError == true' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("text expected string, got number")' <<<"${output}" >/dev/null
    [[ ! -e "${CAPTURE_FILE}" ]] || fail "the tool ran and wrote to the clipboard"
}
