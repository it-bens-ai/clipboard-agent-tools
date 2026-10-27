#!/usr/bin/env bats
# bats file_tags=clipboard-copy,send
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'

setup() {
    source "${LIB_DIR}/clipboard.sh"
    export MCP_CALL_TMPDIR="${BATS_TEST_TMPDIR}/call"
    mkdir -p "${MCP_CALL_TMPDIR}"
}

# bats test_tags=error,osc52
@test "osc52 without base64 or openssl fails with the encoder's message" {
    # A PATH holding only the commands the dispatcher itself needs, so the
    # OSC 52 encoder finds neither base64 nor openssl.
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    ln -s "$(command -v rm)" "${bin}/rm"

    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr bash -c 'PATH="$1"; source "$2"; printf "hello" | _clipboard_send_stdin osc52' \
        _ "${bin}" "${LIB_DIR}/clipboard.sh"

    assert_failure
    assert_output --partial "backend osc52 failed with status 1"
    assert_output --partial "neither base64 nor openssl available"
}

# bats test_tags=success,capture
@test "a send whose backend exits 0 succeeds even when its stderr capture cannot be read" {
    # The stub removes the capture file, which makes it unreadable for root too.
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    printf '#!/bin/sh\ncat >/dev/null\necho "backend-warning" >&2\nrm -f "%s"\nexit 0\n' \
        "${MCP_CALL_TMPDIR}/backend-stderr" > "${bin}/pbcopy"
    chmod +x "${bin}/pbcopy"

    PATH="${bin}:${PATH}" run --separate-stderr _clipboard_send_stdin pbcopy <<<"hello"

    assert_success
    assert_output ""
}

# bats test_tags=error,capture
@test "a send whose backend fails reports the failure when its stderr capture cannot be read" {
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    printf '#!/bin/sh\ncat >/dev/null\necho "backend-failure" >&2\nrm -f "%s"\nexit 3\n' \
        "${MCP_CALL_TMPDIR}/backend-stderr" > "${bin}/pbcopy"
    chmod +x "${bin}/pbcopy"

    PATH="${bin}:${PATH}" run --separate-stderr _clipboard_send_stdin pbcopy <<<"hello"

    assert_failure
    assert_output --partial "backend pbcopy failed with status 3"
    assert_output --partial "cannot be read"
}

# bats test_tags=error,setup
@test "a send without MCP_CALL_TMPDIR is refused before the backend runs" {
    unset MCP_CALL_TMPDIR
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\ntouch "%s"\n' "${BATS_TEST_TMPDIR}/backend-ran" > "${bin}/pbcopy"
    chmod +x "${bin}/pbcopy"

    PATH="${bin}:${PATH}" run --separate-stderr _clipboard_send_stdin pbcopy </dev/null

    assert_failure
    assert_output --partial "MCP_CALL_TMPDIR is not set"
    [[ ! -e "${BATS_TEST_TMPDIR}/backend-ran" ]] || fail "the backend ran"
}

# bats test_tags=error,osc52,encode
@test "the OSC 52 encoder fails when base64 fails without -w support" {
    # A base64 that rejects every call, so the encoder takes the BSD
    # `base64 | tr` path and base64 then fails inside the pipeline.
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    printf '#!/bin/sh\necho "base64-failure-text" >&2\nexit 1\n' > "${bin}/base64"
    chmod +x "${bin}/base64"
    ln -s "$(command -v tr)" "${bin}/tr"

    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr bash -c 'PATH="$1"; source "$2"; printf "hello" | _clipboard_b64' \
        _ "${bin}" "${LIB_DIR}/clipboard.sh"

    assert_failure
    [[ "${stderr}" == *"base64-failure-text"* ]] || fail "base64's stderr is missing: ${stderr}"
}

# bats test_tags=error,osc52,encode
@test "the OSC 52 encoder fails when openssl fails" {
    local bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    printf '#!/bin/sh\nexit 1\n' > "${bin}/openssl"
    chmod +x "${bin}/openssl"

    # shellcheck disable=SC2016  # Pass literal positional parameters to the child shell.
    run --separate-stderr bash -c 'PATH="$1"; source "$2"; printf "hello" | _clipboard_b64' \
        _ "${bin}" "${LIB_DIR}/clipboard.sh"

    assert_failure
}
