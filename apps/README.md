# Apps

Unpublished applications and relay tools in the `termui` workspace live here.

| Path | Purpose | Docs |
| :--- | :--- | :--- |
| `apps/fterm` | Native desktop terminal multiplexer and Flutter WebAssembly viewer | [fterm/README.md](fterm/README.md) |
| `apps/termui_cast` | Binary WebSocket PTY relay server, caster CLI, protocol, and client core | [termui_cast/README.md](termui_cast/README.md) |

## Local Web Testing Quickstart

Follow these steps to serve the `fterm` WebAssembly viewer from the local relay and attach a live shell.

### 1. Build the Web Viewer

From `apps/fterm`:

```powershell
flutter build web --wasm --no-web-resources-cdn
```

Always include `--no-web-resources-cdn`. The relay serves strict `Content-Security-Policy` and `Cross-Origin-Embedder-Policy` headers that block cross-origin CanvasKit and Skwasm downloads from `gstatic.com`.

Rebuild this bundle after pulling protocol changes so the browser client matches the relay wire format.

### 2. Start the Relay Server

From `apps/termui_cast/server`:

```powershell
# With a shared dev token (Windows PowerShell)
dart run .\bin\termui_cast_server.dart `
  --caster-token "dev-token" `
  --client-token "dev-token"
```

```bash
# With a shared dev token (macOS / Linux)
dart run bin/termui_cast_server.dart \
  --caster-token "dev-token" \
  --client-token "dev-token"
```

The server listens on `127.0.0.1:8420`, allows loopback browser origins (`127.0.0.1`, `localhost`, `[::1]`) automatically, and auto-discovers `apps/fterm/build/web` to serve at `/`. Pass `--allowed-origin "https://example.com"` only when connecting from a non-loopback origin.

To disable token checks on loopback instead, omit both token flags (and unset `TERMUI_CAST_CASTER_TOKEN` / `TERMUI_CAST_CLIENT_TOKEN`) and pass `--insecure-no-auth` by itself:

```powershell
dart run .\bin\termui_cast_server.dart --insecure-no-auth
```

> [!NOTE]
> `--insecure-no-auth` only disables auto-minting random loopback tokens. Explicit `--caster-token`, `--client-token`, or `TERMUI_CAST_*_TOKEN` values still enforce authentication even when `--insecure-no-auth` is present.

### 3. Cast a Local Shell

From `apps/termui_cast/caster_cli` in a second terminal:

```powershell
# Windows (PowerShell)
dart run .\bin\termui_cast.dart --token "dev-token" '--' pwsh.exe
```

```bash
# macOS / Linux
dart run bin/termui_cast.dart --token "dev-token" -- zsh
```

Omit `--token "dev-token"` when running the relay with `--insecure-no-auth` alone. In PowerShell, quote `'--'` when passing flags to the spawned command so PowerShell does not strip the separator before `dart run` sees it.

### 4. Open the Viewer

Open one of these URLs in your browser:

- `http://127.0.0.1:8420/#token=dev-token` (connects immediately and scrubs `#token=` from the address bar)
- `http://127.0.0.1:8420/` (opens the Connect dialog where you can enter `dev-token`, or leave the token blank when using `--insecure-no-auth`)

## Local Troubleshooting

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| Repeated `101 Switching Protocols` on `ws://` and no tabs | `apps/fterm/build/web` was built against an older wire protocol | Rebuild in `apps/fterm` with `flutter build web --wasm --no-web-resources-cdn` |
| Blocked request to `gstatic.com/.../skwasm.js` | Built without `--no-web-resources-cdn`; strict CSP and COEP block CDN loads | Rebuild with `flutter build web --wasm --no-web-resources-cdn` |
| `Invalid bearer token` while passing `--insecure-no-auth` | `--caster-token`, `--client-token`, or `TERMUI_CAST_*_TOKEN` is also set | Remove explicit token flags and env vars, or pass the matching token |
| Single `101 Switching Protocols` and empty workspace | Viewer is connected, but no caster has registered a session yet | Start `termui_cast` or press `Ctrl+\ b` on a local desktop `fterm` pane |
