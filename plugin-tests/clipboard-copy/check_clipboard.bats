#!/usr/bin/env bats
# bats file_tags=clipboard-copy,hook

load 'test_helper/common_setup'

SCRIPT="check-clipboard.sh"

# =============================================================================
# BLOCK — clipboard-write commands at start of a command segment
# =============================================================================

# bats test_tags=block,pbcopy
@test "blocks pbcopy with stdin redirect" {
    assert_hook_blocks "$SCRIPT" "pbcopy < file.txt" "clipboard_copy MCP tool"
}

# bats test_tags=block,pbcopy
@test "blocks pbcopy piped from another command" {
    assert_hook_blocks "$SCRIPT" "echo hi | pbcopy" "clipboard_copy"
}

# bats test_tags=block,pbcopy
@test "blocks pbcopy with a quoted argument" {
    assert_hook_blocks "$SCRIPT" 'pbcopy < "quoted file.txt"' "clipboard_copy"
}

# bats test_tags=block,pbcopy
@test "blocks pbcopy after && chain" {
    run_hook "$SCRIPT" "cd /tmp && pbcopy < f.txt"
    assert_failure 2
}

# bats test_tags=block,pbcopy
@test "blocks pbcopy after ; separator" {
    run_hook "$SCRIPT" "date ; pbcopy < f.txt"
    assert_failure 2
}

# bats test_tags=block,wl-copy
@test "blocks wl-copy piped" {
    assert_hook_blocks "$SCRIPT" "echo hi | wl-copy" "clipboard_copy"
}

# bats test_tags=block,clip
@test "blocks clip.exe piped" {
    run_hook "$SCRIPT" "ls | clip.exe"
    assert_failure 2
}

# bats test_tags=block,clip
@test "blocks bare clip command" {
    run_hook "$SCRIPT" "echo hi | clip"
    assert_failure 2
}

# bats test_tags=block,xclip
@test "blocks xclip with no flags (defaults to copy mode)" {
    run_hook "$SCRIPT" "echo hi | xclip"
    assert_failure 2
}

# bats test_tags=block,xclip
@test "blocks xclip -i" {
    run_hook "$SCRIPT" "echo hi | xclip -i"
    assert_failure 2
}

# bats test_tags=block,xclip
@test "blocks xclip -selection clipboard (no -o)" {
    run_hook "$SCRIPT" "echo hi | xclip -selection clipboard"
    assert_failure 2
}

# bats test_tags=block,xsel
@test "blocks xsel --clipboard --input" {
    run_hook "$SCRIPT" "echo hi | xsel --clipboard --input"
    assert_failure 2
}

# bats test_tags=block,xsel
@test "blocks xsel -bi" {
    run_hook "$SCRIPT" "echo hi | xsel -bi"
    assert_failure 2
}

# =============================================================================
# BLOCK MESSAGE — tool names as the host spells them
# =============================================================================

# Run the hook on a command with the given CLIPBOARD_COPY_HOST, "unset" for none.
# Arguments: host, command.
run_hook_on_host() {
    local -a host_env=(-u CLIPBOARD_COPY_HOST)
    [[ "$1" == "unset" ]] || host_env=("CLIPBOARD_COPY_HOST=$1")
    run_hook "$SCRIPT" "$2" "${host_env[@]}"
}

# bats test_tags=block,host
@test "without CLIPBOARD_COPY_HOST the block message names the tools unprefixed" {
    run_hook_on_host unset "echo hi | pbcopy"

    assert_failure 2
    assert_output "Use the clipboard_copy MCP tool instead.

Bad command detected: echo hi | pbcopy

Use clipboard_copy with the text directly, or clipboard_copy_file with an absolute path when the content is already on disk.

The clipboard-copy MCP tool:
  - Auto-detects the right backend per OS (pbcopy / wl-copy / xclip / xsel / clip.exe / clip)
  - Falls back to OSC 52 over SSH and in headless environments"
}

# bats test_tags=block,host
@test "on pi the block message names the tools as pi exposes them" {
    run_hook_on_host pi "echo hi | pbcopy"

    assert_failure 2
    assert_output "Use the mcp__clipboard_copy__clipboard_copy MCP tool instead.

Bad command detected: echo hi | pbcopy

Use mcp__clipboard_copy__clipboard_copy with the text directly, or mcp__clipboard_copy__clipboard_copy_file with an absolute path when the content is already on disk.

The clipboard-copy MCP tool:
  - Auto-detects the right backend per OS (pbcopy / wl-copy / xclip / xsel / clip.exe / clip)
  - Falls back to OSC 52 over SSH and in headless environments"
}

# bats test_tags=block,host
@test "an unsupported CLIPBOARD_COPY_HOST fails a clipboard write with a message naming the value" {
    run_hook_on_host codex "echo hi | pbcopy"

    assert_failure 1
    assert_output 'clipboard-copy: unsupported CLIPBOARD_COPY_HOST "codex"; expected pi or unset'
}

# bats test_tags=allow,host
@test "an unsupported CLIPBOARD_COPY_HOST fails a command that writes no clipboard" {
    run_hook_on_host codex "git status"

    assert_failure 1
    assert_output 'clipboard-copy: unsupported CLIPBOARD_COPY_HOST "codex"; expected pi or unset'
}

# bats test_tags=block,host
@test "on pi a hint keeps a tool name that is already qualified" {
    # shellcheck disable=SC2016  # Source the library and pass the hint in the child shell.
    run env CLIPBOARD_COPY_HOST=pi bash -c 'source "$1"; COMMAND="echo hi | pbcopy"; block_clipboard clipboard_copy "Use mcp__clipboard_copy__clipboard_copy_file when the content is on disk, or clipboard_copy for inline text."' _ "${SCRIPTS_DIR}/lib/common.sh"

    assert_failure 2
    assert_output --partial "Use mcp__clipboard_copy__clipboard_copy_file when the content is on disk"
    assert_output --partial "or mcp__clipboard_copy__clipboard_copy for inline text"
}

# bats test_tags=block,host,pi
@test "on pi an already-qualified tool argument is not prefixed twice" {
    # shellcheck disable=SC2016  # Source the library and pass the tool and hint in the child shell.
    run env CLIPBOARD_COPY_HOST=pi bash -c 'source "$1"; COMMAND="echo hi | pbcopy"; block_clipboard mcp__clipboard_copy__clipboard_copy_file "Use clipboard_copy_file with an absolute path."' _ "${SCRIPTS_DIR}/lib/common.sh"

    assert_failure 2
    assert_output --partial "Use the mcp__clipboard_copy__clipboard_copy_file MCP tool instead."
}

# bats test_tags=block,host,pi
@test "on pi a bare tool argument is prefixed once" {
    # shellcheck disable=SC2016  # Source the library and pass the tool and hint in the child shell.
    run env CLIPBOARD_COPY_HOST=pi bash -c 'source "$1"; COMMAND="echo hi | pbcopy"; block_clipboard clipboard_copy_file "Use clipboard_copy_file with an absolute path."' _ "${SCRIPTS_DIR}/lib/common.sh"

    assert_failure 2
    assert_output --partial "Use the mcp__clipboard_copy__clipboard_copy_file MCP tool instead."
}

# =============================================================================
# ALLOW — paste reads, unrelated commands, false-positive guards
# =============================================================================

# bats test_tags=allow,paste
@test "allows pbpaste" {
    run_hook "$SCRIPT" "pbpaste"
    assert_success
}

# bats test_tags=allow,paste
@test "allows wl-paste" {
    run_hook "$SCRIPT" "wl-paste"
    assert_success
}

# bats test_tags=allow,paste
@test "allows xclip -o (paste mode, first-arg flag)" {
    run_hook "$SCRIPT" "xclip -o > out.txt"
    assert_success
}

# bats test_tags=allow,paste
@test "allows xclip -selection clipboard -out" {
    run_hook "$SCRIPT" "xclip -selection clipboard -out"
    assert_success
}

# bats test_tags=allow,paste
@test "allows xsel -o" {
    run_hook "$SCRIPT" "xsel -o"
    assert_success
}

# bats test_tags=allow,paste
@test "allows xsel --clipboard --output" {
    run_hook "$SCRIPT" "xsel --clipboard --output"
    assert_success
}

# bats test_tags=allow,unrelated
@test "allows unrelated git command" {
    run_hook "$SCRIPT" "git status"
    assert_success
}

# bats test_tags=allow,unrelated
@test "allows unrelated command with a quoted argument" {
    run_hook "$SCRIPT" 'printf "%s" "quoted value"'
    assert_success
}

# bats test_tags=allow,unrelated
@test "allows unrelated ls command" {
    run_hook "$SCRIPT" "ls -la /tmp"
    assert_success
}

# bats test_tags=allow,false-positive
@test "does not trigger on 'clipper' (substring of clip)" {
    run_hook "$SCRIPT" "clipper --help"
    assert_success
}

# bats test_tags=allow,false-positive
@test "does not trigger on 'echo clipboard-test'" {
    run_hook "$SCRIPT" "echo clipboard-test"
    assert_success
}

# bats test_tags=allow,false-positive
@test "does not trigger on 'grep clip file.txt' (clip is the search term)" {
    run_hook "$SCRIPT" "grep clip file.txt"
    assert_success
}

# =============================================================================
# Robustness
# =============================================================================

# bats test_tags=robust
@test "empty command passes through (allow)" {
    run bash -c 'printf "%s" "{\"tool_input\":{\"command\":\"\"}}" | bash "$1"' \
        _ "${SCRIPTS_DIR}/${SCRIPT}"
    assert_success
}
