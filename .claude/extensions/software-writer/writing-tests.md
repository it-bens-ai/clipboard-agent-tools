## Named-value assignments

- `project.stacks` =
  - `bash` — `plugins/**/*.sh`, `.github/scripts/*.sh`, `plugin-tests/**/*.{bats,bash,sh}`
  - `typescript` — `plugins/clipboard-copy/pi/*.ts`, `plugin-tests/clipboard-copy/pi/*.ts`, `plugin-tests/clipboard-copy/fixtures/pi/*.ts`
- `tests.frameworks` =
  - BATS (bats-core 1.14.0 + bats-support 0.3.0 + bats-assert 2.2.4, installed into `.bats/` by `.github/scripts/setup-bats.sh`) for every `plugin-tests/**/*.bats`. Run with `.bats/bats-core/bin/bats -r plugin-tests/`. No BATS framework reference ships with the skill: apply the universal rules. Every suite opens with `# bats file_tags=clipboard-copy,<area>`. A suite that uses `run --separate-stderr` or another feature newer than BATS 1.10 declares `bats_require_minimum_version 1.11.0`. Keep both on new suites that need them.
  - `node:test` with `node:assert/strict` for the Pi extension, in `plugin-tests/clipboard-copy/pi/*.test.ts`. Run with `npm test` (`node --test "plugin-tests/clipboard-copy/pi/*.test.ts"`) after `npm ci`; the directory form fails on Node 22 and 24. `npm run typecheck` and `npm run lint` cover the test files too. `plugin-tests/clipboard-copy/pi_e2e.bats` runs the real Pi binary from `node_modules/.bin/pi`. It skips when that binary is absent, and needs GNU `timeout` or `gtimeout`.
- `tests.fixture_sources` =
  - `plugin-tests/test_helper/common_setup.bash` — resolves `REPO_ROOT` by walking up to `.bats/`, loads bats-support and bats-assert, and provides `make_hook_input`, `run_hook`, and `assert_hook_blocks` (the latter needs `SCRIPTS_DIR` set first).
  - `plugin-tests/clipboard-copy/test_helper/common_setup.bash` — path constants `PLUGIN_DIR`, `SCRIPTS_DIR`, `SESSION_SCRIPT`, `LIB_DIR`, `SHARED_DIR`; load it with `load 'test_helper/common_setup'` instead of hardcoding `plugins/clipboard-copy/` paths.
  - `plugin-tests/clipboard-copy/test_helper/backend_setup.bash` — `backend_set os=… pbcopy=1 xclip=0 …` writes stub executables and a `uname` shim into a directory that then replaces `PATH` entirely, so `command -v` in the library sees exactly what the test stubbed. Call `backend_setup_init` in `setup()` and `backend_setup_cleanup` in `teardown()`. It allocates its directory under `${BATS_TMPDIR:-/tmp}`, not `BATS_TEST_TMPDIR`.
  - Stubbing the clipboard write in tool-function suites: define `_clipboard_send_stdin()` in `setup()` to redirect stdin into a file under `${BATS_TEST_TMPDIR}`, as `plugin-tests/clipboard-copy/tool_clipboard_copy_file.bats` does.
  - `plugin-tests/clipboard-copy/pi/fake-pi.ts` — `registerOnFakePi(extension)` loads the extension against a fake Pi and returns its registered `handlers` and `servers`. `plugin-tests/clipboard-copy/pi/pi-internals.ts` loads Pi's own functions from its `dist` directory (`piMcpToolName`, `piResolveEnvironmentValue`, `piValidateMcpServerConfig`, `loadPiInternal`), so a test checks against Pi's behavior instead of a copy of it. `plugin-tests/clipboard-copy/pi/temporary-directory.ts` provides `makeTemporaryDirectory(t)`, which creates a directory under the system temp directory and removes it after the test.
  - `plugin-tests/clipboard-copy/test_helper/server_request.bash` — `call_tool <tool> <args-json>` sends one `tools/call` request to the `SERVER` path a suite sets. It uses `run --separate-stderr`, so its suites declare `bats_require_minimum_version 1.11.0`.
  - `plugin-tests/clipboard-copy/fixtures/pi/` — `driver.ts` (scripted model for `pi_e2e.bats`) and `pbcopy-stub.sh`. The `uname` shim comes from `backend_write_uname_stub` in `backend_setup.bash`.
  - Synthetic PreToolUse input: pipe `make_hook_input '<command>'` into the hook script, or call `run_hook '<script-name>' '<command>'`.
- `tests.parallelism` = The documented command runs BATS serially; no invocation sets `--jobs`. Write every test to stay correct under `bats --jobs`: per-test state lives in `BATS_TEST_TMPDIR`, and nothing under `PLUGIN_DIR`, `SCRIPTS_DIR`, `LIB_DIR`, or `SHARED_DIR` is mutated in place — copy a script into the temp directory first, as the missing-prompt case in `plugin-tests/clipboard-copy/session_start.bats` does.

## Pre-Step-2

Read `plugins/clipboard-copy/docs/testing.md` §Suites and place the test in the suite that list assigns to the behavior's area. When creating a new suite, add its bullet there and its area tag to §Running the suites.

## Post-Step-6

Run `shellcheck --shell=bash` on every edited `.bats` or `.bash` file when ShellCheck is installed, then run `.bats/bats-core/bin/bats -r plugin-tests/`. After editing a `.ts` test, run `npm run typecheck`, `npm run lint`, and `npm test`. CI runs the type-check, lint, and Node tests, then ShellCheck over `plugins`, `plugin-tests`, and `.github/scripts`, then the SDK pin check and BATS on pushes to `main` or pull requests when paths in `.github/workflows/ci.yml` match.
