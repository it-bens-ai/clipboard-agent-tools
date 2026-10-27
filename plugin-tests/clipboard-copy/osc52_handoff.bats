#!/usr/bin/env bats
# bats file_tags=clipboard-copy,osc52
# Drives server.sh with CLIPBOARD_COPY_OSC52_DIR set, as the pi extension runs
# it: the OSC 52 sequence goes into a new file in that directory, and the
# result's last line names the file, instead of the sequence going to /dev/tty.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'
load 'test_helper/backend_setup'
load 'test_helper/server_request'

SERVER="${PLUGIN_DIR}/mcp-server-clipboard/server.sh"

setup() {
    # uname reports an OS the detection cascade has no native backend for, so
    # every call picks osc52 whatever clipboard utilities the host has.
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    backend_write_uname_stub "${bin}" UnknownOS
    PATH="${bin}:${PATH}"
    unset TMUX

    # pwd -P: the handoff path must be canonical, and $BATS_TEST_TMPDIR can sit
    # under a /var -> /private/var symlink on macOS.
    ROOT=$(cd "${BATS_TEST_TMPDIR}" && pwd -P)
    HANDOFF_DIR="${ROOT}/handoff"
    mkdir -m 700 "${HANDOFF_DIR}"
    export CLIPBOARD_COPY_OSC52_DIR="${HANDOFF_DIR}"
    export CLIPBOARD_COPY_HOST=pi
}

# Print the paths of the entries in a directory, one per line.
# Arguments: directory.
list_entries() {
    find "$1" -mindepth 1 -maxdepth 1
}

# Print the path of the only entry in HANDOFF_DIR; fail unless there is exactly one.
only_handoff_file() {
    local entries
    entries=$(list_entries "${HANDOFF_DIR}")
    [[ -n "${entries}" && "${entries}" != *$'\n'* ]] || fail "expected one handoff file, found: ${entries}"
    printf '%s\n' "${entries}"
}

# Fail unless the response is exactly the given tool result.
# Arguments: response JSON, isError flag (true|false), result text.
assert_tool_result() {
    local expected
    expected=$(jq -cn --argjson is_error "$2" --arg text "$3" \
        '{content: [{type: "text", text: $text}], isError: $is_error}')
    run jq -c '.result' <<<"$1"
    assert_output "${expected}"
}

# bats test_tags=success,result
@test "clipboard_copy returns the copy summary and names the handoff file on its last line" {
    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    local response="${output}" name
    name=$(basename "$(only_handoff_file)")
    [[ "${name}" =~ ^osc52\.[A-Za-z0-9]{8}$ ]] || fail "unexpected handoff file name: ${name}"
    assert_tool_result "${response}" false $'Copied 5 bytes to clipboard via osc52\nOSC 52 handoff: '"${name}"
}

# bats test_tags=success,result
@test "clipboard_copy_file returns the copy summary and names the handoff file on its last line" {
    local f="${BATS_TEST_TMPDIR}/payload.txt"
    printf 'from disk\n' > "$f"

    call_tool clipboard_copy_file "{\"path\":\"${f}\"}"

    assert_success
    local response="${output}" name
    name=$(basename "$(only_handoff_file)")
    assert_tool_result "${response}" false "Copied 10 bytes from ${f} to clipboard via osc52"$'\nOSC 52 handoff: '"${name}"
}

# bats test_tags=success,sequence
@test "the handoff file holds the OSC 52 sequence for the copied text" {
    printf '\e]52;c;aGVsbG8=\a' > "${BATS_TEST_TMPDIR}/expected"

    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    run cmp "$(only_handoff_file)" "${BATS_TEST_TMPDIR}/expected"
    assert_success
}

# bats test_tags=success,sequence,tmux
@test "inside tmux the handoff file holds the sequence wrapped in a tmux pass-through" {
    printf '%s' $'\ePtmux;\e\e]52;c;aGVsbG8=\a\e\\' > "${BATS_TEST_TMPDIR}/expected"

    TMUX="/tmp/tmux-test/default,1,0" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    run cmp "$(only_handoff_file)" "${BATS_TEST_TMPDIR}/expected"
    assert_success
}

# bats test_tags=success,mode
@test "only the owner can read or write the handoff file" {
    # A permissive caller umask must not widen the handoff file's mode.
    umask 000

    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    local file
    file=$(only_handoff_file)
    # -perm with a bare octal mode matches that exact mode.
    run find "${file}" -perm 600
    assert_output "${file}"
}

# bats test_tags=success,size
@test "a payload of exactly 100000 base64 characters is handed off" {
    local f="${BATS_TEST_TMPDIR}/payload.txt"
    # 75000 bytes encode to 100000 base64 characters.
    head -c 75000 /dev/zero | tr '\0' 'a' > "$f"

    call_tool clipboard_copy_file "{\"path\":\"${f}\"}"

    assert_success
    local response="${output}" name
    name=$(basename "$(only_handoff_file)")
    assert_tool_result "${response}" false "Copied 75000 bytes from ${f} to clipboard via osc52"$'\nOSC 52 handoff: '"${name}"
}

# bats test_tags=error,size
@test "a payload over 100000 base64 characters is refused without a handoff file" {
    local f="${BATS_TEST_TMPDIR}/payload.txt"
    # 75001 bytes encode to 100004 base64 characters.
    head -c 75001 /dev/zero | tr '\0' 'a' > "$f"

    call_tool clipboard_copy_file "{\"path\":\"${f}\"}"

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy_file: Error: backend osc52 failed with status 1: Error: the OSC 52 payload is 100004 base64 characters, over the limit of 100000"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,size
@test "clipboard_copy refuses text over 100000 base64 characters without a handoff file" {
    local text
    text=$(head -c 75001 /dev/zero | tr '\0' 'a')

    call_tool clipboard_copy "$(jq -cn --arg text "${text}" '{text: $text}')"

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: the OSC 52 payload is 100004 base64 characters, over the limit of 100000"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,size,encode
@test "the size cap refuses before the encoder runs" {
    # Two encoders that fail loudly and record that they ran. The refusal must
    # come from the byte count, not from an encoder error.
    local bin="${BATS_TEST_TMPDIR}/bin"
    printf '#!/bin/sh\ntouch "%s/base64-ran"\nexit 1\n' "${BATS_TEST_TMPDIR}" > "${bin}/base64"
    printf '#!/bin/sh\ntouch "%s/openssl-ran"\nexit 1\n' "${BATS_TEST_TMPDIR}" > "${bin}/openssl"
    chmod +x "${bin}/base64" "${bin}/openssl"

    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr env PATH="${bin}:${PATH}" bash -c \
        'source "$1"; printf x | _clipboard_write_backend osc52 75001' _ "${LIB_DIR}/clipboard.sh"

    assert_failure 1
    assert_equal "${stderr}" "Error: the OSC 52 payload is 100004 base64 characters, over the limit of 100000"
    [[ ! -e "${BATS_TEST_TMPDIR}/base64-ran" ]] || fail "base64 ran"
    [[ ! -e "${BATS_TEST_TMPDIR}/openssl-ran" ]] || fail "openssl ran"
}

# bats test_tags=error,validate
@test "a missing handoff directory is refused" {
    CLIPBOARD_COPY_OSC52_DIR="${ROOT}/missing" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR does not exist: ${ROOT}/missing"
    [[ ! -e "${ROOT}/missing" ]] || fail "the missing directory was created"
}

# bats test_tags=error,validate
@test "a handoff directory that is a symlink is refused without writing through it" {
    ln -s "${HANDOFF_DIR}" "${ROOT}/link"

    CLIPBOARD_COPY_OSC52_DIR="${ROOT}/link" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is not a canonical path: ${ROOT}/link"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a symlinked handoff directory with a trailing slash is refused without writing through it" {
    ln -s "${HANDOFF_DIR}" "${ROOT}/link"

    CLIPBOARD_COPY_OSC52_DIR="${ROOT}/link/" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is not a canonical path: ${ROOT}/link/"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a symlinked handoff directory with a dot component is refused without writing through it" {
    ln -s "${HANDOFF_DIR}" "${ROOT}/link"

    CLIPBOARD_COPY_OSC52_DIR="${ROOT}/link/." call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is not a canonical path: ${ROOT}/link/."
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a handoff directory with a dot component is refused" {
    CLIPBOARD_COPY_OSC52_DIR="${HANDOFF_DIR}/." call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is not a canonical path: ${HANDOFF_DIR}/."
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a handoff directory with a doubled slash is refused" {
    CLIPBOARD_COPY_OSC52_DIR="${HANDOFF_DIR}//" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is not a canonical path: ${HANDOFF_DIR}//"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a relative handoff directory is refused" {
    CLIPBOARD_COPY_OSC52_DIR="handoff" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is not a canonical path: handoff"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a handoff path that is a regular file is refused" {
    : > "${ROOT}/plain-file"

    CLIPBOARD_COPY_OSC52_DIR="${ROOT}/plain-file" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is not a directory: ${ROOT}/plain-file"
}

# bats test_tags=error,validate
@test "a group-writable handoff directory is refused without a handoff file" {
    chmod 770 "${HANDOFF_DIR}"

    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is writable by group or others: ${HANDOFF_DIR}"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "an other-writable handoff directory is refused without a handoff file" {
    chmod 707 "${HANDOFF_DIR}"

    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is writable by group or others: ${HANDOFF_DIR}"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,size,args
@test "a handoff without a byte count is refused before the encoder runs" {
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr env CLIPBOARD_COPY_HOST=pi bash -c \
        'source "$1"; export CLIPBOARD_COPY_OSC52_DIR="$2"; printf x | _clipboard_write_backend osc52' \
        _ "${LIB_DIR}/clipboard.sh" "${HANDOFF_DIR}"

    assert_failure 1
    assert_equal "${stderr}" "Error: the byte count is required to hand the OSC 52 sequence off"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a handoff directory not owned by the current user is refused without a handoff file" {
    # Creating a directory owned by another user needs root; the check itself is
    # the shell's -O, which cannot be stubbed. The library is sourced in a child
    # shell and the ownership helper overridden to report a foreign owner.
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr bash -c '
        source "$1"
        _clipboard_owned_by_current_user() { return 1; }
        export CLIPBOARD_COPY_OSC52_DIR="$2"
        printf %s hello | _clipboard_write_backend osc52 5
    ' _ "${LIB_DIR}/clipboard.sh" "${HANDOFF_DIR}"

    assert_failure 1
    assert_equal "${stderr}" "Error: CLIPBOARD_COPY_OSC52_DIR is not owned by the current user: ${HANDOFF_DIR}"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a handoff directory whose permissions cannot be read is refused" {
    local stub="${BATS_TEST_TMPDIR}/find-stub"
    mkdir -p "${stub}"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub}/find"
    chmod +x "${stub}/find"

    PATH="${stub}:${PATH}" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: cannot read the permissions of CLIPBOARD_COPY_OSC52_DIR: ${HANDOFF_DIR}"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,validate
@test "a handoff directory the current user cannot write to is refused" {
    if [[ "$(id -u)" == "0" ]]; then
        skip "root bypasses POSIX permissions"
    fi
    local dir="${ROOT}/not-writable"
    mkdir -m 500 "${dir}"

    CLIPBOARD_COPY_OSC52_DIR="${dir}" call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    # mktemp prints its own failure first; the stable part is the handoff error.
    local response="${output}"
    run jq -r '.result.isError' <<<"${response}"
    assert_output "true"
    run jq -r '.result.content[0].text' <<<"${response}"
    assert_output --partial "Error: cannot create an OSC 52 handoff file in ${dir}"
    run list_entries "${dir}"
    assert_output ""
}

# bats test_tags=error,host
@test "CLIPBOARD_COPY_OSC52_DIR set without CLIPBOARD_COPY_HOST=pi is refused" {
    CLIPBOARD_COPY_HOST=codex call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is set but CLIPBOARD_COPY_HOST is not pi"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,host
@test "CLIPBOARD_COPY_OSC52_DIR set with no CLIPBOARD_COPY_HOST is refused" {
    unset CLIPBOARD_COPY_HOST
    call_tool clipboard_copy '{"text":"hello"}'

    assert_success
    assert_tool_result "${output}" true \
        "Error executing clipboard_copy: Error: backend osc52 failed with status 1: Error: CLIPBOARD_COPY_OSC52_DIR is set but CLIPBOARD_COPY_HOST is not pi"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=tty
@test "without CLIPBOARD_COPY_OSC52_DIR the sequence goes to /dev/tty, not to a handoff file" {
    # The server runs in a new session with no controlling terminal, so the
    # /dev/tty write fails instead of reaching the terminal running the tests.
    # The expected reason is the error that open fails with in such a session.
    local detached='POSIX::setsid() >= 0 or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"'
    local reason
    reason=$(perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!\n"; open(my $fh, ">", "/dev/tty") and die "opened /dev/tty\n"; print "$!"')
    local request
    request=$(jq -cn '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"clipboard_copy",arguments:{text:"hello"}}}')

    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr env -u CLIPBOARD_COPY_OSC52_DIR CLIPBOARD_COPY_HOST=pi perl -MPOSIX -e "${detached}" bash -c 'printf "%s\n" "$1" | bash "$2"' _ "${request}" "${SERVER}"

    assert_success
    local response="${output}"
    run jq -r '.result.isError' <<<"${response}"
    assert_output "true"
    run jq -r '.result.content[0].text' <<<"${response}"
    assert_output --regexp "^Error executing clipboard_copy: Error: backend osc52 failed with status 1: .*: /dev/tty: ${reason}\$"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=tty
@test "an empty CLIPBOARD_COPY_OSC52_DIR sends the sequence to /dev/tty, not to a handoff file" {
    # An exported empty value must behave like an unset one instead of trying
    # to hand the sequence off to an empty directory path.
    local detached='POSIX::setsid() >= 0 or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"'
    local reason
    reason=$(perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!\n"; open(my $fh, ">", "/dev/tty") and die "opened /dev/tty\n"; print "$!"')
    local request
    request=$(jq -cn '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"clipboard_copy",arguments:{text:"hello"}}}')

    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr env CLIPBOARD_COPY_HOST=pi CLIPBOARD_COPY_OSC52_DIR= perl -MPOSIX -e "${detached}" bash -c 'printf "%s\n" "$1" | bash "$2"' _ "${request}" "${SERVER}"

    assert_success
    local response="${output}"
    run jq -r '.result.isError' <<<"${response}"
    assert_output "true"
    run jq -r '.result.content[0].text' <<<"${response}"
    assert_output --regexp "^Error executing clipboard_copy: Error: backend osc52 failed with status 1: .*: /dev/tty: ${reason}\$"
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# =============================================================================
# LIBRARY — the handoff and its note in one shell
# =============================================================================

# Run a body in a child shell that has the library sourced and a call
# directory, so a failure can be forced with function overrides. The child gets
# deterministic wrappers: `handoff` calls _clipboard_osc52_handoff with the
# given sequence and `note` calls _clipboard_handoff_note.
# Arguments: body to eval, OSC 52 sequence.
run_handoff() {
    local call="${BATS_TEST_TMPDIR}/call"
    mkdir -p "${call}"

    # shellcheck disable=SC2016  # Pass literal positional parameters and the body to the child shell.
    run --separate-stderr bash -c '
        source "$1"
        export MCP_CALL_TMPDIR="$2" CLIPBOARD_COPY_OSC52_DIR="$3"
        sequence="$4"
        mktemp() { builtin printf "%s\n" "${1%/*}/osc52.abcdefgh"; }
        handoff() { _clipboard_osc52_handoff "${sequence}"; }
        note() { _clipboard_handoff_note; }
        eval "$5"
    ' _ "${LIB_DIR}/clipboard.sh" "${call}" "${HANDOFF_DIR}" "$2" "$1"
}

# bats test_tags=success,cleanup
@test "the note names the handoff file the same shell created" {
    printf '%s' $'\e]52;c;aGVsbG8=\a' > "${BATS_TEST_TMPDIR}/expected"

    # shellcheck disable=SC2016  # The body is passed to the child shell unevaluated.
    run_handoff 'handoff || exit 1; note' $'\e]52;c;aGVsbG8=\a'

    assert_success
    assert_equal "${output}" "OSC 52 handoff: osc52.abcdefgh"
    # The note reads the global; no note file is written in the call directory.
    [[ ! -e "${BATS_TEST_TMPDIR}/call/osc52-handoff" ]] || fail "a note file was written"
    run cmp "${HANDOFF_DIR}/osc52.abcdefgh" "${BATS_TEST_TMPDIR}/expected"
    assert_success
}

# bats test_tags=error,cleanup
@test "a sequence that cannot be written leaves no handoff file" {
    # shellcheck disable=SC2016  # The body is passed to the child shell unevaluated.
    run_handoff 'printf() { if [[ "$1" == "%s" ]]; then builtin printf "%s" "$2" > "${MCP_CALL_TMPDIR}/attempted"; return 1; fi; builtin printf "$@"; }; handoff' $'\e]52;c;aGVsbG8=\a'

    assert_failure
    assert_equal "${stderr}" "Error: cannot write the OSC 52 sequence to ${HANDOFF_DIR}/osc52.abcdefgh"
    # The write was asked for the caller's sequence, not an empty one.
    run cat "${BATS_TEST_TMPDIR}/call/attempted"
    assert_output $'\e]52;c;aGVsbG8=\a'
    run list_entries "${HANDOFF_DIR}"
    assert_output ""
}

# bats test_tags=error,dispatch
@test "an unknown backend is refused with an error naming it" {
    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr bash -c 'source "$1"; printf "hello" | _clipboard_write_backend unknown-backend' \
        _ "${LIB_DIR}/clipboard.sh"

    assert_failure 1
    assert_equal "${stderr}" "Error: unknown clipboard backend: unknown-backend"
}
