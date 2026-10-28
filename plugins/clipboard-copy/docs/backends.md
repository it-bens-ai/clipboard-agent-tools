# Backends

The server picks a clipboard backend on every tool call. It uses a native clipboard utility when one is on `PATH` and falls back to OSC 52 escape sequences otherwise. The result text names the backend it used.

## Detection order

The server takes the first available backend in this order, scoped to the OS that `uname -s` reports:

| OS | Detection order |
|---|---|
| macOS (`Darwin`) | `pbcopy` → `osc52` |
| Linux | `clip.exe` (WSL) → `wl-copy` when `WAYLAND_DISPLAY` is set → `xclip`, then `xsel`, when `DISPLAY` is set → `wl-copy`, `xclip`, `xsel` regardless of the display variables → `osc52` |
| Cygwin / MinGW / MSYS (Windows) | `clip` → `osc52` |
| Other | `osc52` |

On Linux the last native pass covers headless sessions where `WAYLAND_DISPLAY` and `DISPLAY` are unset but a utility is installed and configured for the session.

## Native clipboard utilities

Install a clipboard utility for your platform to skip OSC 52:

- macOS: `pbcopy` (preinstalled)
- Linux Wayland: `wl-clipboard` (`wl-copy`)
- Linux X11: `xclip` or `xsel`
- WSL: `clip.exe` (preinstalled on Windows)
- Cygwin/MSYS: `clip`

Other requirements are in the repository README's [Requirements](../../../README.md#requirements).

## OSC 52 fallback

When no native utility is available — over SSH, in containers, in restricted environments — the server writes an [OSC 52](https://www.xfree86.org/current/ctlseqs.html) terminal escape sequence to `/dev/tty`. The sequence never goes to stdout, which carries the MCP JSON-RPC stream. When `/dev/tty` is not writable, the call returns an error.

The payload is base64-encoded with `base64`, or with `openssl` when `base64` is missing. With neither installed, the OSC 52 fallback fails.

When `$TMUX` is set, the server wraps the sequence in a tmux DCS pass-through.

On Pi the server does not write to `/dev/tty`; see [Pi](pi.md#osc-52-on-pi).

### Supported terminals

OSC 52 is supported by most modern terminal emulators, including:

- iTerm2
- kitty
- Alacritty
- WezTerm
- Windows Terminal
- foot
- tmux (with the wrapping the server applies automatically)

If your terminal does not honor OSC 52, the copy silently does nothing, and the server cannot detect that.
