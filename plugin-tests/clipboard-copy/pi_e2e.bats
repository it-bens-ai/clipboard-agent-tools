#!/usr/bin/env bats
# bats file_tags=clipboard-copy,pi-e2e
# Drives the real pi binary against the installed package with a scripted model
# (fixtures/pi/driver.ts) and a stubbed pbcopy backend, offline. setup_file
# installs each package variant, runs pi once per scenario, and keeps the
# outputs; every test asserts over those outputs.
bats_require_minimum_version 1.11.0

load 'test_helper/common_setup'
load 'test_helper/backend_setup'

PI_BIN="${REPO_ROOT}/node_modules/.bin/pi"
FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/pi"

# Resolves the GNU `timeout` binary this suite bounds each pi run with.
# Stock macOS ships neither name under PATH's `timeout`; Homebrew's coreutils
# provides it as `gtimeout`.
resolve_timeout_bin() {
    if command -v timeout >/dev/null 2>&1; then
        command -v timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        command -v gtimeout
    else
        printf 'pi_e2e.bats: no "timeout" or "gtimeout" on PATH. Install GNU coreutils (e.g. "brew install coreutils").\n' >&2
        return 1
    fi
}

# Reproduces offline what `pi install git:…` runs: a clone, then npm install in
# it. The clone is a one-commit snapshot of the working tree (tracked and
# non-ignored untracked files that exist on disk, modes and symlinks kept), so
# the layout ships uncommitted changes exactly as the next commit would.
install_git_layout() {
    local source="${BATS_FILE_TMPDIR}/git-source" layout="${BATS_FILE_TMPDIR}/git-layout"
    local listed="${BATS_FILE_TMPDIR}/git-source-listed" present="${BATS_FILE_TMPDIR}/git-source-present"
    local path
    git -C "${REPO_ROOT}" ls-files -z --cached --others --exclude-standard >"${listed}"
    while IFS= read -r -d '' path; do
        if [[ -e "${REPO_ROOT}/${path}" || -L "${REPO_ROOT}/${path}" ]]; then
            printf '%s\0' "${path}"
        fi
    done <"${listed}" >"${present}"
    mkdir -p "${source}"
    tar -C "${REPO_ROOT}" --null -T "${present}" -cf "${BATS_FILE_TMPDIR}/git-source.tar"
    tar -C "${source}" -xf "${BATS_FILE_TMPDIR}/git-source.tar"
    git -C "${source}" init --quiet
    git -C "${source}" add --all --force
    git -C "${source}" -c user.name=pi-e2e -c user.email=pi-e2e@localhost -c commit.gpgsign=false \
        commit --quiet --no-verify -m "working tree snapshot"
    git clone --quiet "${source}" "${layout}"
    (cd "${layout}" && npm install --omit=dev --legacy-peer-deps --offline --no-audit --no-fund)
    git -C "${layout}" status --porcelain >"${BATS_FILE_TMPDIR}/git-layout-status"
}

# Reproduces offline what `pi install npm:…` runs: npm install of the tarball
# under a prefix.
install_npm_layout() {
    local pack_dir="${BATS_FILE_TMPDIR}/npm-pack" prefix="${BATS_FILE_TMPDIR}/npm-prefix" tarball
    mkdir -p "${pack_dir}" "${prefix}"
    tarball=$(cd "${REPO_ROOT}" && npm pack --json --pack-destination "${pack_dir}" | jq -er '.[0].filename')
    npm install "${pack_dir}/${tarball}" --prefix "${prefix}" --legacy-peer-deps --offline --no-audit --no-fund
}

# Builds a PATH directory holding every executable on the current PATH except the
# native clipboard writers. Fails loudly when one of them is still reachable, so
# the OSC 52 scenario cannot silently exercise a native backend.
# Args: $1=directory to create
build_backendless_path() {
    local shim="$1" dir exe base name
    local -a dirs targets
    mkdir -p "${shim}"
    IFS=: read -r -a dirs <<<"${PATH}"
    for dir in "${dirs[@]}"; do
        [[ -d "${dir}" ]] || continue
        targets=()
        for exe in "${dir}"/*; do
            [[ -f "${exe}" && -x "${exe}" ]] || continue
            base="${exe##*/}"
            case "${base}" in
                pbcopy | wl-copy | xclip | xsel | clip.exe | clip) continue ;;
            esac
            if [[ -e "${shim}/${base}" ]]; then
                continue
            fi
            targets+=("${exe}")
        done
        [[ ${#targets[@]} -gt 0 ]] || continue
        ln -s "${targets[@]}" "${shim}"
    done
    for name in pbcopy wl-copy xclip xsel clip.exe clip; do
        if (PATH="${shim}" command -v "${name}" >/dev/null 2>&1); then
            printf 'pi_e2e.bats: %s is still reachable on the backendless PATH\n' "${name}" >&2
            return 1
        fi
    done
}

# Runs pi once for a scenario against a package variant; outputs land in
# ${BATS_FILE_TMPDIR}/<variant>-<scenario>/.
# Args: $1=variant (git|npm), $2=scenario (a driver.ts SCENARIO)
run_pi_scenario() {
    local variant="$1" scenario="$2"
    local run_dir="${BATS_FILE_TMPDIR}/${variant}-${scenario}" package_dir run_path
    case "${variant}" in
        git) package_dir="${BATS_FILE_TMPDIR}/git-layout" ;;
        npm) package_dir="${BATS_FILE_TMPDIR}/npm-prefix/node_modules/@it-bens-ai/clipboard-agent-tools" ;;
    esac

    mkdir -p "${run_dir}/project" "${run_dir}/bin" "${run_dir}/agent" "${run_dir}/tmp"
    git -C "${run_dir}/project" init --quiet
    printf '%s' 'hello pi from a file' >"${run_dir}/payload.txt"
    : >"${run_dir}/trace.jsonl"
    printf '0' >"${run_dir}/pbcopy.log.count"
    ln -s "${FIXTURES_DIR}/pbcopy-stub.sh" "${run_dir}/bin/pbcopy"
    backend_write_uname_stub "${run_dir}/bin" Darwin

    PI_CODING_AGENT_DIR="${run_dir}/agent" "${PI_BIN}" install "${package_dir}" </dev/null

    local -a scenario_env=()
    case "${scenario}" in
        osc52)
            build_backendless_path "${run_dir}/backendless-path"
            run_path="${run_dir}/backendless-path"
            scenario_env=("TMPDIR=${run_dir}/tmp")
            ;;
        *)
            run_path="${run_dir}/bin:${PATH}"
            ;;
    esac

    local status=0
    (
        cd "${run_dir}/project"
        env -u CLIPBOARD_COPY_HOST -u CLIPBOARD_COPY_OSC52_DIR -u TMUX -u DISPLAY -u WAYLAND_DISPLAY \
            "${scenario_env[@]}" \
            PATH="${run_path}" \
            PI_CODING_AGENT_DIR="${run_dir}/agent" \
            SCENARIO="${scenario}" \
            TRACE="${run_dir}/trace.jsonl" \
            CLIPBOARD_COPY_FILE="${run_dir}/payload.txt" \
            PBCOPY_STUB_LOG="${run_dir}/pbcopy.log" \
            "${TIMEOUT_BIN}" 60 "${PI_BIN}" --offline --no-session -e "${FIXTURES_DIR}/driver.ts" \
            --model faux/faux-1 --mode json -p go \
            </dev/null >"${run_dir}/stdout.jsonl" 2>"${run_dir}/stderr.log"
    ) || status=$?
    printf '%s\n' "${status}" >"${run_dir}/exit-code"
}

# Runs its arguments under a pseudo-terminal and returns the child's exit
# status. BSD `script` (macOS) takes the command as trailing arguments;
# util-linux (CI) needs the command as one `-c` string and `-e` for the child's
# status.
run_under_pseudo_terminal() {
    if script --version 2>/dev/null | grep -q 'util-linux'; then
        script -q -e -c "$(printf '%q ' "$@")" /dev/null
    else
        script -q /dev/null "$@"
    fi
}

# Prints every OSC 52 handoff directory and handoff file left under a run's
# TMPDIR; prints nothing when the extension removed the directory and its
# handler removed the file.
# Args: $1=run directory
leftover_handoff_entries() {
    local entry
    for entry in "${1}"/tmp/clipboard-copy-pi-* "${1}"/tmp/osc52.* "${1}"/tmp/clipboard-copy-pi-*/osc52.*; do
        if [[ -e "${entry}" ]]; then
            printf '%s\n' "${entry}"
        fi
    done
}

# Holds the pseudo-terminal's input open until the driver reports settlement.
# The driver calls ctx.shutdown() in the same handler, so pi is already shutting
# down when the pipe closes. Gives up after 60 s so the caller's pipe still
# closes and the run ends instead of hanging.
# Args: $1=run directory
wait_for_settlement() {
    local run_dir="$1" waited=0
    while [[ ${waited} -lt 600 ]]; do
        if [[ -e "${run_dir}/settled" ]]; then
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# Runs the `tui` scenario: pi in interactive mode under a pseudo-terminal, with
# no native clipboard writer on PATH. Output lands in
# ${BATS_FILE_TMPDIR}/git-tui/stdout.raw.
run_pi_tui_scenario() {
    local run_dir="${BATS_FILE_TMPDIR}/git-tui"
    local package_dir="${BATS_FILE_TMPDIR}/git-layout"
    local status=0
    local -a command

    mkdir -p "${run_dir}/project" "${run_dir}/agent" "${run_dir}/tmp"
    git -C "${run_dir}/project" init --quiet
    printf '%s' 'hello pi from a file' >"${run_dir}/payload.txt"
    : >"${run_dir}/trace.jsonl"

    PI_CODING_AGENT_DIR="${run_dir}/agent" "${PI_BIN}" install "${package_dir}" </dev/null

    build_backendless_path "${run_dir}/backendless-path"

    command=(
        env -u CLIPBOARD_COPY_HOST -u CLIPBOARD_COPY_OSC52_DIR -u TMUX -u DISPLAY -u WAYLAND_DISPLAY
        TMPDIR="${run_dir}/tmp"
        PATH="${run_dir}/backendless-path"
        PI_CODING_AGENT_DIR="${run_dir}/agent"
        TERM=xterm-256color
        SCENARIO=tui
        TRACE="${run_dir}/trace.jsonl"
        SETTLE_FILE="${run_dir}/settled"
        CLIPBOARD_COPY_FILE="${run_dir}/payload.txt"
        "${TIMEOUT_BIN}" 60 "${PI_BIN}"
        --offline --no-session -e "${FIXTURES_DIR}/driver.ts"
        --model faux/faux-1 go
    )

    (
        cd "${run_dir}/project"
        wait_for_settlement "${run_dir}" |
            run_under_pseudo_terminal "${command[@]}" \
                >"${run_dir}/stdout.raw" 2>"${run_dir}/stderr.log"
    ) || status=$?
    printf '%s\n' "${status}" >"${run_dir}/exit-code"
}

setup_file() {
    if [[ ! -x "${PI_BIN}" ]]; then
        skip "pi_e2e.bats: ${PI_BIN} not found; run \"npm ci\" in ${REPO_ROOT} first."
    fi
    TIMEOUT_BIN=$(resolve_timeout_bin) || return 1
    # Fixture git runs isolated from the developer's configuration.
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=pi-e2e GIT_AUTHOR_EMAIL=pi-e2e@localhost
    export GIT_COMMITTER_NAME=pi-e2e GIT_COMMITTER_EMAIL=pi-e2e@localhost
    # Only the OSC 52 scenario sets a handoff directory; no run may inherit one.
    unset CLIPBOARD_COPY_HOST CLIPBOARD_COPY_OSC52_DIR TMUX DISPLAY WAYLAND_DISPLAY

    install_git_layout
    install_npm_layout
    # The scenarios only read the layouts, so they run concurrently. Each failure is collected so
    # setup_file still fails with every job's streamed output.
    local -a scenario_pids=()
    run_pi_scenario git deferred &
    scenario_pids+=("$!")
    run_pi_scenario npm deferred &
    scenario_pids+=("$!")
    run_pi_scenario git osc52 &
    scenario_pids+=("$!")
    run_pi_tui_scenario &
    scenario_pids+=("$!")
    local pid failed=0
    for pid in "${scenario_pids[@]}"; do
        if ! wait "${pid}"; then
            failed=1
        fi
    done
    return "${failed}"
}

# Prints {"isError": …, "text": …} for one finished tool call, text being the
# concatenated text parts of its result.
# Args: $1=run (<variant>-<scenario>), $2=toolCallId
tool_result() {
    jq -c --arg id "$2" '
        select(.type == "tool_execution_end" and .toolCallId == $id)
        | {isError, text: ([.result.content[] | select(.type == "text") | .text] | join(""))}
    ' "${BATS_FILE_TMPDIR}/$1/stdout.jsonl"
}

# Fails unless the tool call ended as an error whose text contains the fragment.
# Args: $1=run, $2=toolCallId, $3=fragment
assert_tool_error_contains() {
    local result
    result=$(tool_result "$1" "$2")
    run jq -r '.isError' <<<"${result}"
    assert_output "true"
    run jq -r '.text' <<<"${result}"
    assert_output --partial "$3"
}

# Fails unless the tool call ended as an error whose text is exactly the expected text.
# Args: $1=run, $2=toolCallId, $3=expected text
assert_tool_error_is() {
    local result
    result=$(tool_result "$1" "$2")
    run jq -r '.isError' <<<"${result}"
    assert_output "true"
    run jq -r '.text' <<<"${result}"
    assert_output "$3"
}

# Fails unless the tool call succeeded with exactly the expected text.
# Args: $1=run, $2=toolCallId, $3=expected text
assert_tool_result_is() {
    local result
    result=$(tool_result "$1" "$2")
    run jq -r '.isError' <<<"${result}"
    assert_output "false"
    run jq -r '.text' <<<"${result}"
    assert_output "$3"
}

# Prints {"isError": …, "text": …} for one tool result as the model saw it, from
# the request trace. Interactive mode writes no JSON event stream, so the trace
# is the record of the tool's result there.
# Args: $1=run (<variant>-<scenario>), $2=toolCallId
traced_tool_result() {
    jq -c --arg id "$2" '
        .[] | select(.role == "toolResult" and .toolCallId == $id)
        | {isError, text: ([.content[] | select(.type == "text") | .text] | join(""))}
    ' "${BATS_FILE_TMPDIR}/$1/trace.jsonl" | tail -n 1
}

# Fails unless the traced tool result succeeded with exactly the expected text.
# Args: $1=run, $2=toolCallId, $3=expected text
assert_traced_tool_result_is() {
    local result
    result=$(traced_tool_result "$1" "$2")
    run jq -r '.isError' <<<"${result}"
    assert_output "false"
    run jq -r '.text' <<<"${result}"
    assert_output "$3"
}

# Fails unless tool_search answered with exactly one bullet, the named tool.
# Args: $1=run, $2=toolCallId, $3=tool name
assert_tool_search_loads_one_tool() {
    local result text
    result=$(tool_result "$1" "$2")
    run jq -r '.isError' <<<"${result}"
    assert_output "false"
    text=$(jq -r '.text' <<<"${result}")
    run grep -c -E '^- [^[:space:]]+: ' <<<"${text}"
    assert_output "1"
    run grep -c -- "^- $3: " <<<"${text}"
    assert_output "1"
}

# Fails unless the first model request carries the clipboard_copy section with
# the shared directive and the pi addendum.
# Args: $1=run
assert_first_request_carries_section() {
    local host_pi_text first_system
    host_pi_text=$(<"${PLUGIN_DIR}/hooks/prompts/host-pi.md")
    first_system=$(jq -nc 'first(inputs) | .[0]' "${BATS_FILE_TMPDIR}/$1/trace.jsonl")

    run jq -r '.role' <<<"${first_system}"
    assert_output "system"
    run jq -r '.sections.clipboard_copy' <<<"${first_system}"
    assert_output --partial "ALWAYS use the clipboard-copy MCP tools to write to the system clipboard."
    run jq -r '.sections.clipboard_copy' <<<"${first_system}"
    assert_output --partial "${host_pi_text}"
}

# Fails unless pi exited 0. A failed run leaves no tool results to assert over.
# Args: $1=run
assert_pi_exits_cleanly() {
    run cat "${BATS_FILE_TMPDIR}/$1/exit-code"
    assert_output "0"
}

# Fails unless the pbcopy stub ran exactly the given number of times.
# Args: $1=run, $2=expected invocation count
assert_pbcopy_invocations() {
    run cat "${BATS_FILE_TMPDIR}/$1/pbcopy.log.count"
    assert_output "$2"
}

# ============================================================================
# Scenario `deferred` — a stubbed pbcopy is the detected backend
# ============================================================================

@test "git layout: npm install in the clone leaves the working tree clean" {
    run cat "${BATS_FILE_TMPDIR}/git-layout-status"
    assert_output ""
}

@test "git layout: tool_search for clipboard_copy loads only mcp__clipboard_copy__clipboard_copy" {
    # Fails when the query ranks clipboard_copy_file first, or loads both.
    assert_tool_search_loads_one_tool git-deferred search-copy mcp__clipboard_copy__clipboard_copy
}

@test "git layout: clipboard_copy sends hello pi to the pbcopy backend" {
    # Fails when the MCP call does not reach the stub, or changes the bytes.
    assert_tool_result_is git-deferred copy-text "Copied 8 bytes to clipboard via pbcopy"
    run cat "${BATS_FILE_TMPDIR}/git-deferred/pbcopy.log.1"
    assert_output "hello pi"
}

@test "git layout: tool_search for clipboard_copy_file loads only mcp__clipboard_copy__clipboard_copy_file" {
    # Fails when the second search loads nothing or the wrong tool.
    assert_tool_search_loads_one_tool git-deferred search-copy-file mcp__clipboard_copy__clipboard_copy_file
}

@test "git layout: clipboard_copy_file sends the file's bytes to the pbcopy backend" {
    # Fails when the path argument never reaches the server, or bytes change.
    assert_tool_result_is git-deferred copy-file \
        "Copied 20 bytes from ${BATS_FILE_TMPDIR}/git-deferred/payload.txt to clipboard via pbcopy"
    run cat "${BATS_FILE_TMPDIR}/git-deferred/pbcopy.log.2"
    assert_output "hello pi from a file"
}

@test "git layout: bash printf | pbcopy is blocked before the pbcopy stub runs" {
    # Fails when the hook allows the command: the stub records a third invocation.
    assert_tool_error_contains git-deferred bash-pbcopy \
        "Use the mcp__clipboard_copy__clipboard_copy MCP tool instead."
    assert_pbcopy_invocations git-deferred 2
}

@test "git layout: the first request carries the clipboard_copy section and the pi addendum" {
    # Fails when session-start.sh fails or the section name changes.
    assert_first_request_carries_section git-deferred
}

@test "git layout: pi exits 0" {
    # Fails when the extension or the MCP server crashes the run.
    assert_pi_exits_cleanly git-deferred
}

@test "npm layout: tool_search for clipboard_copy loads only mcp__clipboard_copy__clipboard_copy" {
    assert_tool_search_loads_one_tool npm-deferred search-copy mcp__clipboard_copy__clipboard_copy
}

@test "npm layout: clipboard_copy sends hello pi to the pbcopy backend" {
    assert_tool_result_is npm-deferred copy-text "Copied 8 bytes to clipboard via pbcopy"
    run cat "${BATS_FILE_TMPDIR}/npm-deferred/pbcopy.log.1"
    assert_output "hello pi"
}

@test "npm layout: clipboard_copy_file sends the file's bytes to the pbcopy backend" {
    assert_tool_result_is npm-deferred copy-file \
        "Copied 20 bytes from ${BATS_FILE_TMPDIR}/npm-deferred/payload.txt to clipboard via pbcopy"
    run cat "${BATS_FILE_TMPDIR}/npm-deferred/pbcopy.log.2"
    assert_output "hello pi from a file"
}

@test "npm layout: bash printf | pbcopy is blocked before the pbcopy stub runs" {
    assert_tool_error_contains npm-deferred bash-pbcopy \
        "Use the mcp__clipboard_copy__clipboard_copy MCP tool instead."
    assert_pbcopy_invocations npm-deferred 2
}

@test "npm layout: the first request carries the clipboard_copy section and the pi addendum" {
    assert_first_request_carries_section npm-deferred
}

@test "npm layout: pi exits 0" {
    assert_pi_exits_cleanly npm-deferred
}

# ============================================================================
# Scenario `osc52` — no native backend on PATH, non-interactive mode
# ============================================================================

@test "osc52: clipboard_copy reports that the fallback needs pi's interactive terminal" {
    # Fails when a native backend is reachable, or the handoff error text changes.
    assert_tool_error_is git-osc52 copy-text-osc52 \
        "clipboard-copy: nothing was copied. The server fell back to OSC 52, which needs pi's interactive terminal, and pi runs in json mode."
}

@test "osc52: the extension deletes the OSC 52 handoff file before session shutdown" {
    # Fails when the tool_result handler leaves the handoff file for session_shutdown to remove.
    # The driver records the $TMPDIR entries once per model request; the third request follows the
    # osc52 tool call, and its snapshot is taken before shutdown.
    local entries
    entries=$(sed -n '3p' "${BATS_FILE_TMPDIR}/git-osc52/trace.jsonl.tmpdir")
    run jq -r '[.[] | select(test("(^|/)osc52\\.[A-Za-z0-9]{8}$"))] | length' <<<"${entries}"
    assert_output "0"
    run jq -r '[.[] | select(test("(^|/)clipboard-copy-pi-"))] | length > 0' <<<"${entries}"
    assert_output "true"
}

@test "osc52: pi exits 0" {
    assert_pi_exits_cleanly git-osc52
}

# ============================================================================
# Scenario `tui` — no native backend on PATH, interactive mode under a PTY
# ============================================================================

@test "tui: clipboard_copy writes the OSC 52 sequence for the text to the terminal" {
    # Fails when the tool result handler does not reach pi's stdout, or the sequence's bytes change.
    # The base64 of "osc52 pi" is b3NjNTIgcGk=; the sequence is ESC ] 52 ; c ; <base64> BEL.
    run grep -F $'\x1b]52;c;b3NjNTIgcGk=\a' "${BATS_FILE_TMPDIR}/git-tui/stdout.raw"
    assert_success
}

@test "tui: clipboard_copy reports the fallback copy to the model" {
    # Fails when the handler fails and leaves an error result instead of the server's summary.
    assert_traced_tool_result_is git-tui copy-text-tui "Copied 8 bytes to clipboard via osc52"
}

@test "tui: the tool result handler deletes the OSC 52 handoff file" {
    # Fails when the handler writes the sequence but leaves the file for session_shutdown to remove.
    # The driver records the $TMPDIR entries once per model request; the third request follows the
    # tui tool call, and its snapshot is taken before shutdown.
    local entries
    entries=$(sed -n '3p' "${BATS_FILE_TMPDIR}/git-tui/trace.jsonl.tmpdir")
    run jq -r '[.[] | select(test("(^|/)osc52\\.[A-Za-z0-9]{8}$"))] | length' <<<"${entries}"
    assert_output "0"
}

@test "tui: no OSC 52 handoff file or directory remains after the session" {
    # Fails when session_shutdown leaves the directory the session_start handler created, and when
    # the scenario never ran at all.
    run test -d "${BATS_FILE_TMPDIR}/git-tui/tmp"
    assert_success
    run leftover_handoff_entries "${BATS_FILE_TMPDIR}/git-tui"
    assert_output ""
}

@test "tui: pi exits 0" {
    assert_pi_exits_cleanly git-tui
}
