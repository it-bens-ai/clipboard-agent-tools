import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { TestContext } from "node:test";

/**
Creates a new directory under the system temp directory and removes it, with its contents, after
the test.
*/
export function makeTemporaryDirectory(t: TestContext): string {
  const dir = mkdtempSync(path.join(tmpdir(), "clipboard-copy-pi-test-"));
  t.after(() => {
    rmSync(dir, { force: true, recursive: true });
  });
  return dir;
}
