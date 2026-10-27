#!/bin/bash
# Test fixtures for clipboard-copy plugin tests.
# Extends the shared test helper with clipboard-copy specific paths.

# Path: from test file (plugin-tests/clipboard-copy) up 1 level to plugin-tests/
load "${BATS_TEST_DIRNAME}/../test_helper/common_setup"

PLUGIN_DIR="${REPO_ROOT}/plugins/clipboard-copy"
SCRIPTS_DIR="${PLUGIN_DIR}/hooks/scripts"
SESSION_SCRIPT="${SCRIPTS_DIR}/session-start.sh"
export SESSION_SCRIPT
LIB_DIR="${PLUGIN_DIR}/mcp-server-clipboard/lib"
SHARED_DIR="${PLUGIN_DIR}/shared"
