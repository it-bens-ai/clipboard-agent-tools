#!/usr/bin/env bash
# Cross-platform clipboard tools for the clipboard-copy MCP server.
# Tools: clipboard_copy, clipboard_copy_file

# Detect the best available clipboard backend for the current environment.
# Echoes one of: pbcopy, wl-copy, xclip, xsel, clip-exe, clip, osc52
_clipboard_detect_backend() {
    case "$(uname -s)" in
        Darwin)
            command -v pbcopy >/dev/null 2>&1 && { echo "pbcopy"; return 0; }
            ;;
        Linux)
            # WSL exposes Windows clip.exe on PATH
            if command -v clip.exe >/dev/null 2>&1; then
                echo "clip-exe"; return 0
            fi
            if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then
                echo "wl-copy"; return 0
            fi
            if [[ -n "${DISPLAY:-}" ]]; then
                command -v xclip >/dev/null 2>&1 && { echo "xclip"; return 0; }
                command -v xsel  >/dev/null 2>&1 && { echo "xsel";  return 0; }
            fi
            # Headless Linux without DISPLAY/WAYLAND_DISPLAY: still try wl-copy/xclip/xsel
            # in case one is installed and configured for the current session.
            command -v wl-copy >/dev/null 2>&1 && { echo "wl-copy"; return 0; }
            command -v xclip   >/dev/null 2>&1 && { echo "xclip";   return 0; }
            command -v xsel    >/dev/null 2>&1 && { echo "xsel";    return 0; }
            ;;
        CYGWIN*|MINGW*|MSYS*)
            command -v clip >/dev/null 2>&1 && { echo "clip"; return 0; }
            ;;
    esac

    echo "osc52"
}

# Base64-encode stdin without line wrapping. Handles GNU base64 (-w 0),
# BSD/macOS base64 (no -w but emits a single line for small input — strip newlines),
# and falls back to openssl when base64 is missing.
_clipboard_b64() {
    # The server already runs with pipefail. Setting it here, scoped to this
    # function by `local -`, keeps a failing base64 from yielding tr's status
    # when this file is sourced on its own.
    local -
    set -o pipefail
    if command -v base64 >/dev/null 2>&1; then
        if base64 -w 0 </dev/null >/dev/null 2>&1; then
            base64 -w 0
        else
            base64 | tr -d '\r\n'
        fi
    elif command -v openssl >/dev/null 2>&1; then
        openssl base64 -A
    else
        echo "Error: neither base64 nor openssl available for OSC 52 encoding" >&2
        return 1
    fi
}

#######################################
# Report whether a directory is owned by the user running the server.
# Arguments:
#   Directory path.
# Returns:
#   0 when it is, 1 otherwise.
#######################################
_clipboard_owned_by_current_user() {
    [[ -O "$1" ]]
}

#######################################
# Check that a directory is safe to hand OSC 52 sequences off through: an
# existing absolute path that is its own physical path, a directory, owned by
# the current user, and not writable by group or others. The physical-path
# rule refuses a symlink, a trailing slash, a "." component and a "//", so the
# file always lands in the directory the caller named.
# Arguments:
#   Directory path.
# Outputs:
#   The failed check on stderr.
# Returns:
#   0 when every check passes, 1 otherwise.
#######################################
_clipboard_check_handoff_dir() {
    local dir="$1"
    if [[ "${dir}" != /* ]]; then
        echo "Error: CLIPBOARD_COPY_OSC52_DIR is not a canonical path: ${dir}" >&2
        return 1
    fi
    if [[ ! -e "${dir}" ]]; then
        echo "Error: CLIPBOARD_COPY_OSC52_DIR does not exist: ${dir}" >&2
        return 1
    fi
    if [[ ! -d "${dir}" ]]; then
        echo "Error: CLIPBOARD_COPY_OSC52_DIR is not a directory: ${dir}" >&2
        return 1
    fi
    local physical
    if ! physical=$(cd -- "${dir}" 2>/dev/null && pwd -P) || [[ "${physical}" != "${dir}" ]]; then
        echo "Error: CLIPBOARD_COPY_OSC52_DIR is not a canonical path: ${dir}" >&2
        return 1
    fi
    if ! _clipboard_owned_by_current_user "${dir}"; then
        echo "Error: CLIPBOARD_COPY_OSC52_DIR is not owned by the current user: ${dir}" >&2
        return 1
    fi
    # find prints the directory when its group or other write bit is set;
    # GNU and BSD stat disagree on how to print a mode.
    local writable
    if ! writable=$(find "${dir}" -maxdepth 0 \( -perm -020 -o -perm -002 \)); then
        echo "Error: cannot read the permissions of CLIPBOARD_COPY_OSC52_DIR: ${dir}" >&2
        return 1
    fi
    if [[ -n "${writable}" ]]; then
        echo "Error: CLIPBOARD_COPY_OSC52_DIR is writable by group or others: ${dir}" >&2
        return 1
    fi
}

#######################################
# Hand an OSC 52 sequence off to the host instead of writing it to /dev/tty:
# write it to a new file in CLIPBOARD_COPY_OSC52_DIR and leave the file's path
# in _CLIPBOARD_HANDOFF_FILE for _clipboard_handoff_note. A host that starts
# the server without a terminal, such as pi, writes the file to its own
# terminal. A failure after the file exists removes it again, so no handoff
# file outlives a failed call.
# Globals:
#   CLIPBOARD_COPY_OSC52_DIR (read)
#   _CLIPBOARD_HANDOFF_FILE (set to the created file)
# Arguments:
#   The OSC 52 sequence.
# Outputs:
#   The failure on stderr.
# Returns:
#   0 when the sequence is written, 1 otherwise.
#######################################
_clipboard_osc52_handoff() {
    local seq="$1"
    local dir="${CLIPBOARD_COPY_OSC52_DIR}"

    _clipboard_check_handoff_dir "${dir}" || return 1

    local file
    if ! file=$(umask 077 && mktemp "${dir}/osc52.XXXXXXXX"); then
        echo "Error: cannot create an OSC 52 handoff file in ${dir}" >&2
        return 1
    fi
    _CLIPBOARD_HANDOFF_FILE="${file}"
    if ! printf '%s' "${seq}" >"${file}"; then
        rm -f -- "${file}"
        echo "Error: cannot write the OSC 52 sequence to ${file}" >&2
        return 1
    fi
}

# Read stdin and forward it to the given backend.
# For OSC 52, buffers stdin, base64-encodes, and writes the escape sequence
# to /dev/tty (not stdout) so it stays out of the MCP JSON-RPC channel, or
# hands it off through CLIPBOARD_COPY_OSC52_DIR when that is set, which only
# the pi host reads. Wraps the sequence in a tmux DCS pass-through when $TMUX
# is set.
# Arguments:
#   Backend name.
#   Number of bytes on stdin.
_clipboard_write_backend() {
    local backend="$1" bytes="${2:-}"
    case "${backend}" in
        pbcopy)   pbcopy ;;
        wl-copy)  wl-copy ;;
        xclip)    xclip -selection clipboard ;;
        xsel)     xsel --clipboard --input ;;
        clip-exe) clip.exe ;;
        clip)     clip ;;
        osc52)
            if [[ -n "${CLIPBOARD_COPY_OSC52_DIR:-}" ]]; then
                if [[ "${CLIPBOARD_COPY_HOST:-}" != "pi" ]]; then
                    echo "Error: CLIPBOARD_COPY_OSC52_DIR is set but CLIPBOARD_COPY_HOST is not pi" >&2
                    return 1
                fi
                if [[ -z "${bytes}" ]]; then
                    echo "Error: the byte count is required to hand the OSC 52 sequence off" >&2
                    return 1
                fi
                # Refused before the encoder runs: base64 turns every 3 input
                # bytes into 4 characters, padding the last group. The handoff
                # path caps the encoded payload at 100000 characters, the same
                # limit Pi applies to its own OSC 52 copies, to keep a single
                # terminal write bounded.
                local b64_length=$(( 4 * ((bytes + 2) / 3) ))
                if (( b64_length > 100000 )); then
                    echo "Error: the OSC 52 payload is ${b64_length} base64 characters, over the limit of 100000" >&2
                    return 1
                fi
            fi
            local b64
            b64=$(_clipboard_b64) || return 1
            local seq
            if [[ -n "${TMUX:-}" ]]; then
                seq=$'\ePtmux;\e\e]52;c;'"${b64}"$'\a\e\\'
            else
                seq=$'\e]52;c;'"${b64}"$'\a'
            fi
            if [[ -n "${CLIPBOARD_COPY_OSC52_DIR:-}" ]]; then
                _clipboard_osc52_handoff "${seq}"
                return
            fi
            if [[ ! -w /dev/tty ]]; then
                echo "Error: /dev/tty is not writable; OSC 52 fallback cannot reach the terminal" >&2
                return 1
            fi
            printf '%s' "${seq}" >/dev/tty
            ;;
        *)
            echo "Error: unknown clipboard backend: ${backend}" >&2
            return 1
            ;;
    esac
}

# Send stdin to the given backend with the backend's stderr kept out of the
# tool result. On success the stderr is dropped unread; on failure it is
# echoed with the exit status and the function returns 1.
# Needs MCP_CALL_TMPDIR, the per-call directory the MCP core exports.
# Arguments:
#   Backend name.
#   Number of bytes on stdin, for the backend's size caps.
_clipboard_send_stdin() {
    local backend="$1" bytes="${2:-}"

    if [[ -z "${MCP_CALL_TMPDIR:-}" ]]; then
        echo "Error: MCP_CALL_TMPDIR is not set; cannot capture the ${backend} backend's stderr"
        return 1
    fi

    # A file, not a command substitution: xclip and wl-copy fork a child that
    # keeps stderr open, so reading stderr through a pipe would block until
    # that child exits.
    local stderr_file="${MCP_CALL_TMPDIR}/backend-stderr"
    local status=0
    _clipboard_write_backend "${backend}" "${bytes}" 2>"${stderr_file}" || status=$?

    # No cleanup: the core removes MCP_CALL_TMPDIR when the call ends.
    if [[ ${status} -eq 0 ]]; then
        return 0
    fi

    local stderr_text
    if ! stderr_text=$(<"${stderr_file}"); then
        echo "Error: backend ${backend} failed with status ${status}, and its stderr cannot be read from ${stderr_file}"
        return 1
    fi
    echo "Error: backend ${backend} failed with status ${status}${stderr_text:+: ${stderr_text}}"
    return 1
}

#######################################
# Print the line that names this call's OSC 52 handoff file, when
# _clipboard_osc52_handoff wrote one. The host reads it from the last line of
# the tool result. The tool function calls this in the same shell that ran the
# writer, so the path is still in the global.
# Globals:
#   _CLIPBOARD_HANDOFF_FILE (read)
# Outputs:
#   "OSC 52 handoff: <file name>" on stdout when the call handed a file off,
#   nothing otherwise.
# Returns:
#   0.
#######################################
_clipboard_handoff_note() {
    [[ -n "${_CLIPBOARD_HANDOFF_FILE:-}" ]] || return 0
    echo "OSC 52 handoff: ${_CLIPBOARD_HANDOFF_FILE##*/}"
}

# Copy text to the system clipboard using the auto-detected backend.
# Args: $1 = JSON arguments object with required '.text'
tool_clipboard_copy() {
    local args="$1"

    # jq -e exits 1 when the test is false and above 1 when jq itself fails.
    local check_status=0
    jq -e '(.text | type) == "string" and (.text | length) > 0' <<<"${args}" >/dev/null || check_status=$?
    if [[ ${check_status} -eq 1 ]]; then
        echo "Error: text is required and must be a non-empty string"
        return 1
    fi
    if [[ ${check_status} -ne 0 ]]; then
        echo "Error: cannot read text from the arguments: jq exited with status ${check_status}"
        return 1
    fi

    if [[ -z "${MCP_CALL_TMPDIR:-}" ]]; then
        echo "Error: MCP_CALL_TMPDIR is not set; cannot stage the text for the backend"
        return 1
    fi

    # jq -j writes the string's bytes unchanged, NUL bytes and trailing
    # newlines included, which a bash variable cannot hold. Staging them in a
    # file rather than piping them stops a failed jq before the backend runs.
    local text_file="${MCP_CALL_TMPDIR}/text"
    if ! jq -j '.text' <<<"${args}" >"${text_file}"; then
        echo "Error: cannot extract the text into ${text_file}"
        return 1
    fi

    local backend bytes
    backend=$(_clipboard_detect_backend)
    if ! bytes=$(wc -c <"${text_file}"); then
        echo "Error: cannot count the bytes in ${text_file}"
        return 1
    fi
    # wc pads the count differently across platforms.
    bytes="${bytes//[[:space:]]/}"

    _clipboard_send_stdin "${backend}" "${bytes}" <"${text_file}" || return 1
    echo "Copied ${bytes} bytes to clipboard via ${backend}"
    _clipboard_handoff_note
}

# Copy the contents of a file at an absolute path to the system clipboard.
# Args: $1 = JSON arguments object with required '.path' (absolute filesystem path)
tool_clipboard_copy_file() {
    local args="$1"

    local path
    path=$(echo "${args}" | jq -r '.path // empty')

    if [[ -z "${path}" ]]; then
        echo "Error: path is required"
        return 1
    fi
    if [[ ! -e "${path}" ]]; then
        echo "Error: file not found: ${path}"
        return 1
    fi
    if [[ ! -f "${path}" ]]; then
        echo "Error: not a regular file: ${path}"
        return 1
    fi
    if [[ ! -r "${path}" ]]; then
        echo "Error: file not readable: ${path}"
        return 1
    fi

    local backend size
    backend=$(_clipboard_detect_backend)
    size=$(wc -c < "${path}" | tr -d ' ')

    _clipboard_send_stdin "${backend}" "${size}" < "${path}" || return 1
    echo "Copied ${size} bytes from ${path} to clipboard via ${backend}"
    _clipboard_handoff_note
}
