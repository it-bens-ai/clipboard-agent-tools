#!/usr/bin/env bats
# bats file_tags=clipboard-copy,server
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'
load 'test_helper/server_request'

SERVER="${PLUGIN_DIR}/mcp-server-clipboard/server.sh"

setup() {
    # Stub every backend the detection cascade picks first on macOS (pbcopy),
    # Linux/WSL (clip.exe) and Cygwin/MSYS (clip), so a call that reaches the
    # tool writes into a capture file instead of the real clipboard.
    CAPTURE_FILE="${BATS_TEST_TMPDIR}/clipboard_capture"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB_DIR}"
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    write_backend_stub 'cat > "$1"'
    PATH="${STUB_DIR}:${PATH}"
}

# Replace every stubbed backend with a script running the given body.
# The body receives the capture file path as $1.
write_backend_stub() {
    local backend
    for backend in pbcopy clip.exe clip; do
        printf '#!/usr/bin/env bash\nset -- "%s"\n%s\n' "${CAPTURE_FILE}" "$1" > "${STUB_DIR}/${backend}"
        chmod +x "${STUB_DIR}/${backend}"
    done
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

# bats test_tags=success,result
@test "clipboard_copy returns only the copy summary as its result text" {
    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    jq -e '.result.content[0].text | test("^Copied 5 bytes to clipboard via [a-z-]+$")' <<<"${output}" >/dev/null
}

# bats test_tags=success,result
@test "clipboard_copy_file returns only the copy summary as its result text" {
    local f="${BATS_TEST_TMPDIR}/payload.txt"
    printf 'from disk\n' > "$f"

    call_tool clipboard_copy_file "{\"path\":\"${f}\"}"

    assert_success
    # The prefix is compared literally, since the path may hold regex metacharacters.
    jq -e --arg f "$f" '.result.content[0].text | ltrimstr("Copied 10 bytes from \($f) to clipboard via ") | test("^[a-z-]+$")' \
        <<<"${output}" >/dev/null
}

# bats test_tags=success,text
@test "clipboard_copy sends trailing newlines to the backend byte for byte" {
    printf 'a\n\n' > "${BATS_TEST_TMPDIR}/expected"

    call_tool clipboard_copy '{"text":"a\n\n"}'

    assert_success
    jq -e '.result.isError | not' <<<"${output}" >/dev/null
    run cmp "${CAPTURE_FILE}" "${BATS_TEST_TMPDIR}/expected"
    assert_success
}

# bats test_tags=success,text
@test "clipboard_copy copies text made only of newlines and counts each one" {
    printf '\n\n' > "${BATS_TEST_TMPDIR}/expected"

    call_tool clipboard_copy '{"text":"\n\n"}'

    assert_success
    jq -e '.result.isError | not' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("Copied 2 bytes to clipboard via ")' <<<"${output}" >/dev/null
    run cmp "${CAPTURE_FILE}" "${BATS_TEST_TMPDIR}/expected"
    assert_success
}

# bats test_tags=success,text
@test "clipboard_copy sends NUL bytes to the backend and counts them" {
    call_tool clipboard_copy '{"text":"a\u0000b"}'

    assert_success
    jq -e '.result.content[0].text | test("^Copied 3 bytes to clipboard via [a-z-]+$")' <<<"${output}" >/dev/null
    run od -An -tx1 "${CAPTURE_FILE}"
    assert_success
    [[ "${output//[[:space:]]/}" == "610062" ]] || fail "the backend received: ${output}"
}

# bats test_tags=success,text
@test "clipboard_copy copies text made only of a NUL byte" {
    call_tool clipboard_copy '{"text":"\u0000"}'

    assert_success
    jq -e '.result.content[0].text | test("^Copied 1 bytes to clipboard via [a-z-]+$")' <<<"${output}" >/dev/null
    run od -An -tx1 "${CAPTURE_FILE}"
    assert_success
    [[ "${output//[[:space:]]/}" == "00" ]] || fail "the backend received: ${output}"
}

# bats test_tags=success,bytes
@test "clipboard_copy reports UTF-8 bytes, not characters" {
    # "é€" is two characters and five bytes in UTF-8. The count comes from
    # the bytes sent, so it does not depend on the locale the server runs in.
    call_tool clipboard_copy '{"text":"é€"}'

    assert_success
    jq -e '.result.content[0].text | test("^Copied 5 bytes to clipboard via [a-z-]+$")' <<<"${output}" >/dev/null
}

# bats test_tags=success,bytes
@test "clipboard_copy_file reports UTF-8 bytes and keeps trailing newlines" {
    local f="${BATS_TEST_TMPDIR}/payload.txt"
    printf 'é€\n\n' > "$f"

    LC_ALL=en_US.UTF-8 call_tool clipboard_copy_file "{\"path\":\"${f}\"}"

    assert_success
    jq -e '.result.content[0].text | contains("Copied 7 bytes from ")' <<<"${output}" >/dev/null
    run cmp "${CAPTURE_FILE}" "$f"
    assert_success
}

# bats test_tags=success,stderr
@test "clipboard_copy leaves a succeeding backend's stderr out of the result" {
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    write_backend_stub 'cat > "$1"; echo "backend-warning-text" >&2'

    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    jq -e '.result.isError | not' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("backend-warning-text") | not' <<<"${output}" >/dev/null
}

# bats test_tags=error,stderr
@test "clipboard_copy returns an error with the backend's stderr and status when the backend fails" {
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    write_backend_stub 'cat > "$1"; echo "backend-failure-text" >&2; exit 3'

    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    jq -e '.result.isError == true' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("failed with status 3")' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("backend-failure-text")' <<<"${output}" >/dev/null
}

# bats test_tags=error,stderr
@test "clipboard_copy_file returns an error with the backend's stderr and status when the backend fails" {
    local f="${BATS_TEST_TMPDIR}/payload.txt"
    printf 'from disk\n' > "$f"
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    write_backend_stub 'cat > "$1"; echo "backend-failure-text" >&2; exit 3'

    call_tool clipboard_copy_file "{\"path\":\"${f}\"}"

    assert_success
    jq -e '.result.isError == true' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("failed with status 3")' <<<"${output}" >/dev/null
    jq -e '.result.content[0].text | contains("backend-failure-text")' <<<"${output}" >/dev/null
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
