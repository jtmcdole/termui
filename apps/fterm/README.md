# fterm

Flutter native desktop terminal multiplexer (`macos`, `linux`, `windows`) and WebAssembly client (`web`) for `termui_caster`, built on `package:termui_flutter`, `package:termui_pty`, `package:termui_audio_flutter`, and `package:termui_cast_client_core`.

## Features & Controls

- **Desktop local startup**: Spawns your interactive shell (`$SHELL`, `pwsh.exe`, or `%COMSPEC%`) immediately on startup via `PtyRouter` and connects configured relays in the background.
- **Per-pane relay sharing (`Ctrl+\ b`)**: Toggle relay broadcast on any local desktop pane (`killPty: false` on stop) while filtering self-cast `SessionId`s out of the Session Picker.
- **Binary split trees & single shared atlas**: Horizontal (`Ctrl+\ |`, `Ctrl+\ %`, `Cmd+D`) and vertical (`Ctrl+\ -`, `Ctrl+\ "`, `Cmd+Shift+D`) splits with `1px` draggable dividers, `hjkl`/arrow navigation, `Ctrl+\ z` zoom, and `TerminalSurface` leaves sharing one `GlyphAtlas`.
- **Smallest-viewport sizing**: Intersects viewport dimensions across active local and remote subscribers before resizing PTYs, dimming excess canvas margins cleanly.
- **Audio & Web CSP**: Lazy first-gesture `FlutterAudioEngine` setup with stereo-panned `BEL` chimes, `ESC _ A` (`APC A`) tones/clips, and external `web/audio_unlock.js` (zero inline scripts).
- **28px tab bar & 0px bottom bar**: Supports `top` (with `72px` macOS traffic-light inset and empty-strip window drag), `left`, `hidden`, and `autoHideSingle` modes, unread bell badges, and live vs user-pinned titles (`clearPin`).

## Install from GitHub Releases

Prebuilt desktop archives are published on [GitHub Releases](https://github.com/jtmcdole/termui/releases) without paid Apple Developer ID or Windows Authenticode code-signing certificates. Follow the platform steps below on first launch.

### macOS (`fterm-macos-arm64.tar.gz`)

macOS Gatekeeper quarantines unsigned archives downloaded in a browser and may report `fterm.app` as damaged. Clear the quarantine extended attribute after extracting, then open the app:

```bash
tar -xzf fterm-macos-arm64.tar.gz
xattr -dr com.apple.quarantine fterm.app
open fterm.app
```

You can move `fterm.app` into `/Applications` after clearing quarantine.

### Windows (`fterm-windows-x64.zip`)

Extract the full `.zip` archive to a folder so `conpty.dll`, `OpenConsole.exe`, `THIRD-PARTY-NOTICES.txt`, and `data/` stay next to `fterm.exe`:

```powershell
Expand-Archive -Path fterm-windows-x64.zip -DestinationPath .\fterm
.\fterm\fterm.exe
```

If Windows Defender SmartScreen shows **"Windows protected your PC"** on first launch, select **More info** and then **Run anyway**. Downloading via `gh release download` or `curl.exe` avoids adding the browser Mark-of-the-Web stream.

### Linux (`fterm-linux-x64.tar.gz`)

Extract the bundle into its own directory so `lib/` and `data/` remain adjacent to the `fterm` binary:

```bash
mkdir -p fterm
tar -xzf fterm-linux-x64.tar.gz -C fterm
./fterm/fterm
```

## Run in Chrome

```bash
flutter run -d chrome \
  --dart-define=TERMUI_CAST_SERVER_URL=ws://127.0.0.1:8420/v1/client \
  --dart-define=TERMUI_CAST_TOKEN=dev-client
```

Pass tokens on Web via `#token=...` URL fragments or `--dart-define=TERMUI_CAST_TOKEN=...` to keep credentials out of `Referer` headers and server access logs. On startup, the web app immediately scrubs `#token=...` from the browser address bar and history.

## Run on Native Desktop (macOS, Linux, Windows)

Launch on `macos`, `linux`, or `windows` using `--dart-define`, runtime environment variables, or CLI flags (`--server` / `--url`, `--token`, `--caster-token`):

```bash
# Runtime environment variables (replace -d macos with -d linux or -d windows)
TERMUI_CAST_SERVER_URL=ws://127.0.0.1:8420/v1/client \
TERMUI_CAST_TOKEN=dev-client \
TERMUI_CAST_CASTER_TOKEN=dev-caster \
flutter run -d macos

# CLI flags via Flutter desktop entrypoint args
flutter run -d macos \
  -a --server=ws://127.0.0.1:8420/v1/client \
  -a --token=dev-client \
  -a --caster-token=dev-caster

# Or directly against a built desktop binary
./build/macos/Build/Products/Debug/fterm.app/Contents/MacOS/fterm \
  --server ws://127.0.0.1:8420/v1/client \
  --token dev-client \
  --caster-token dev-caster
```

### Connecting Through Google Cloud Run IAP

Desktop clients can connect to relays gated behind Google Cloud Run Identity-Aware Proxy (IAP) over `wss://`. Authenticate the WebSocket upgrade with a service-account JSON key file (`--iap-key-file` / `TERMUI_CAST_IAP_KEY_FILE`) or `gcloud iam service-accounts sign-jwt` (`--iap-service-account` / `TERMUI_CAST_IAP_SERVICE_ACCOUNT`):

```bash
# Local pure-Dart RS256 signing from a service-account JSON key file
TERMUI_CAST_SERVER_URL=wss://relay.example.run.app/v1/client \
TERMUI_CAST_TOKEN=viewer-secret \
TERMUI_CAST_IAP_KEY_FILE=/path/to/service-account.json \
flutter run -d macos

# Or via gcloud IAM service-account impersonation on the CLI
./build/macos/Build/Products/Debug/fterm.app/Contents/MacOS/fterm \
  --server wss://relay.example.run.app/v1/client \
  --token viewer-secret \
  --iap-service-account viewer@my-project.iam.gserviceaccount.com
```

When running on Web without a server/token, `fterm` opens a Flutter **Connect to Relay** modal dialog (dismissible with `Escape`). Desktop settings and saved relay credentials persist to `~/.config/fterm/settings.json` (`0700` dir, `0600` atomic file on POSIX; migrating legacy `~/.config/termui_cast/settings.json` cleanly) and `%APPDATA%\fterm\settings.json` on Windows.

## Build and Test

```bash
flutter analyze
flutter test
flutter build web --wasm --no-web-resources-cdn
flutter build macos
```

## Releasing on GitHub

Releases use a two-step GitHub Actions pipeline powered by Melos:

1. If workspace libraries under `packages/` have unreleased changes that `fterm` depends on, run **[Prepare release](../../.github/workflows/release-prepare.yml)** first so Melos versions and tags those packages.
2. Run **[Prepare fterm release](../../.github/workflows/release-fterm-prepare.yml)** (`Actions -> Prepare fterm release -> Run workflow`). Melos bumps `apps/fterm` and any modified `apps/termui_cast/*` packages from Conventional Commits, writes `CHANGELOG.md` entries, and opens (or updates) a `chore(fterm-release): release fterm vX.Y.Z` pull request against `main`.
3. Review and merge that pull request into `main`. **[Release fterm](../../.github/workflows/release-fterm.yml)** starts automatically and builds the `macos-arm64`, `linux-x64`, `linux-arm64`, and `windows-x64` archives. It then tags `fterm-vX.Y.Z` (plus companion `termui_cast*-v*` baseline tags) and publishes the GitHub Release.

You can also trigger **[Release fterm](../../.github/workflows/release-fterm.yml)** manually via `workflow_dispatch` to cut a draft release or override the version string.
