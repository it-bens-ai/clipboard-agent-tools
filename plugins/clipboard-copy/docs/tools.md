# Tools

The clipboard-copy MCP server exposes two tools. Both write to the system clipboard through the backend chosen for the current machine; [Backends](backends.md) lists the detection order. The tool schemas live in `mcp-server-clipboard/tools.json`.

## `clipboard_copy`

Writes inline text to the system clipboard.

| Argument | Type | Required | Description |
|---|---|---|---|
| `text` | string | yes | The text to copy. Sent verbatim — no trailing newline appended. |

The text must be a non-empty string. Text made only of newlines or NUL bytes is copied as it is.

On success the result is `Copied N bytes to clipboard via <backend>`.

## `clipboard_copy_file`

Writes the contents of a file to the system clipboard. Use it when the content is already on disk, for example a temp file the model just wrote, instead of sending it back through the MCP channel as inline text.

| Argument | Type | Required | Description |
|---|---|---|---|
| `path` | string | yes | Absolute filesystem path to the file whose contents should be copied. |

The path must be absolute, point to an existing regular file, and be readable. On success the result is `Copied N bytes from <path> to clipboard via <backend>`.

## Results

`N` is the number of bytes sent to the backend. `<backend>` is one of `pbcopy`, `wl-copy`, `xclip`, `xsel`, `clip-exe` (WSL's `clip.exe`), `clip`, or `osc52`.

When the backend exits non-zero, the call returns an error result: `Error: backend <backend> failed with status <N>: <stderr>`. A backend's stderr output after a successful copy is dropped and does not reach the result.

On Pi, a copy through OSC 52 carries one more line for the extension, which removes it before the model sees the result; see [Pi](pi.md#osc-52-on-pi).

## Argument validation

The server checks each call's arguments against the tool's `inputSchema` in `tools.json` before the tool runs. A path that does not start with `/`, a value of the wrong type, or an argument the tables above do not list returns an error result, and nothing is copied.

The server exits non-zero before reading requests if `tools.json` is missing, invalid JSON, or not exactly one JSON object containing a `tools` array. The error appears on the MCP host's stderr.

## No-echo rule

Both tool descriptions carry the no-reprint rule from the [SessionStart directive](hooks.md#sessionstart-directive), including on hosts without the plugin's hooks.
