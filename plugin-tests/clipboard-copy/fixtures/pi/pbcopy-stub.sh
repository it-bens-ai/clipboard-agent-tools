#!/usr/bin/env bash
# Fixture stub for the native pbcopy backend. Each invocation appends its stdin to
# a numbered file beside $PBCOPY_STUB_LOG, so a test can assert both what reached
# the backend and how often it ran. Fails loudly when the suite has not pointed it
# at a log, so a copy that silently bypasses the assertions cannot pass.
set -eu

: "${PBCOPY_STUB_LOG:?pbcopy stub: PBCOPY_STUB_LOG must be set}"

count_file="${PBCOPY_STUB_LOG}.count"
count=0
if [ -e "${count_file}" ]; then
    count=$(cat "${count_file}")
fi
count=$((count + 1))
printf '%s' "${count}" >"${count_file}"
cat >"${PBCOPY_STUB_LOG}.${count}"
