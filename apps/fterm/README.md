# fterm

Flutter native desktop terminal multiplexer (`macos`, `linux`, `windows`) and WebAssembly client (`web`) for `termui_caster`, built on `package:termui_flutter`, `package:termui_pty`, `package:termui_audio_flutter`, and `package:termui_cast_client_core`.

See [SPEC.md](../SPEC.md) for the custom terminal escape sequences (audio, shaders, cell transforms, queries) and chunked file transfer protocol.

## Features & Controls

- **Desktop local startup**: Spawns your interactive shell (`$SHELL`, `pwsh.exe`, or `%COMSPEC%`) immediately on startup via `PtyRouter` and connects configured relays in the background.
- **Per-pane relay sharing (`Ctrl+\ b`)**: Toggle relay broadcast on any local desktop pane (`killPty: false` on stop) while filtering self-cast `SessionId`s out of the Session Picker.
- **Binary split trees & single shared atlas**: Horizontal (`Ctrl+\ |`, `Ctrl+\ %`, `Cmd+D`) and vertical (`Ctrl+\ -`, `Ctrl+\ "`, `Cmd+Shift+D`) splits with `1px` draggable dividers, `hjkl`/arrow navigation, `Ctrl+\ z` zoom, and `TerminalSurface` leaves sharing one `GlyphAtlas`.
- **Smallest-viewport sizing**: Intersects viewport dimensions across active local and remote subscribers before resizing PTYs, dimming excess canvas margins cleanly.
- **Audio & Web CSP**: Lazy first-gesture `FlutterAudioEngine` setup with stereo-panned `BEL` chimes, `ESC _ A` (`APC A`) tones/clips, and external `web/audio_unlock.js` (zero inline scripts).
- **28px tab bar & 0px bottom bar**: Supports `top` (with `72px` macOS traffic-light inset and empty-strip window drag), `left`, `hidden`, and `autoHideSingle` modes, unread bell badges, and live vs user-pinned titles (`clearPin`).
- **In-app GLSL shader editor (`Ctrl+\ e`)**: Opens a live Shadertoy GLSL editor tab with syntax highlighting, SGR 58 diagnostic squiggles, live BG/FG preview (`Solo` or `Blend`), multi-line selection, Save (`Alt+S`), and Save As (`Alt+Shift+S` / `Ctrl+Shift+S` or tab context menu).
- **GPU shader Emergency Stop (`Ctrl+Shift+F6` or `Ctrl+\ 0`)**: Immediately bypasses all custom and preset shaders across desktop and web, paired with a per-shader `GpuFrameWatchdog` warmup grace window and an out-of-band recovery pill.

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

### Relay Server & Caster Bundles (`termui_cast_server-<os>-<arch>`, `termui_cast-<os>-<arch>`, `fterm-web.tar.gz`)

- `termui_cast_server-<os>-<arch>.tar.gz` / `.zip` bundles `bin/termui_cast_server` with the prebuilt `fterm` WASM web viewer under `web/` (compressible assets stored as `.gz` without uncompressed duplicates). Running `./bin/termui_cast_server` auto-discovers `../web` on startup.
- `termui_cast-<os>-<arch>.tar.gz` / `.zip` contains only the lightweight caster CLI (`bin/termui_cast` + native PTY libraries).
- `fterm-web.tar.gz` contains the same gzip-only `web/` tree for `termui_cast_server --web-dir` or reverse proxies configured for gzip-only static files (such as Nginx `gzip_static always; gunzip on;`).

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

### Updating Flutter Golden Tests (Linux-only)

Flutter UI screenshot goldens (`apps/fterm/test/goldens/` and `packages/termui_flutter/test/goldens/`) run strictly on **Linux** (`Platform.isLinux`) for deterministic FreeType font rasterization across CI runners.

On a Linux host:

```bash
flutter test --update-goldens
```

On macOS or Windows with Docker and [`gh act`](https://github.com/nektos/gh-act), run the Linux workflow locally to inspect failures or accept golden updates:

```shell
# Verify goldens locally in a Linux container (writes diffs into test/failures/)
gh act \
  -b \
  --container-architecture linux/amd64 \
  --container-options="--tty" \
  --workflows ".github/workflows/apps.yml" \
  -j test-apps \
  --matrix os:ubuntu-latest \
  --matrix suite:fterm

# Update fterm goldens locally in a Linux container
gh act \
  -b \
  --env UPDATE_GOLDENS=true \
  --container-architecture linux/amd64 \
  --container-options="--tty" \
  --workflows ".github/workflows/apps.yml" \
  -j test-apps \
  --matrix os:ubuntu-latest \
  --matrix suite:fterm
```

On GitHub Actions, failed Linux golden runs automatically upload `test/failures/*.png` as a `fterm-golden-failures` (or `flutter-golden-failures`) workflow artifact so you can review or download the rendered `*_testImage.png` without running Docker locally.

### Desktop Versioning & Testing Auto-Updates

`fterm` reads its compiled semantic version from `appBuildName` (`package:flutter/services.dart`), which Flutter (`>=3.41.0`) populates automatically via `FLUTTER_BUILD_NAME`:

- `flutter test`, `flutter run`, and `flutter build` read `version:` from `apps/fterm/pubspec.yaml` automatically. Never hardcode a version string in Dart.
- Pass `--build-name=<x.y.z>` to `flutter build` when testing updates locally (for example, `flutter build windows --release --build-name=0.2.0`). `flutter run` does not accept `--build-name`, and Flutter reserves `FLUTTER_BUILD_NAME` so `--dart-define=FLUTTER_BUILD_NAME=...` is rejected.
- Copy the release bundle (`build/windows/x64/runner/Release`, `build/linux/x64/release/bundle`, or `build/macos/Build/Products/Release/fterm.app`) into a standalone writable folder (such as `C:\temp\fterm-test` or `~/fterm-test`) before testing self-updates. `resolvePortableInstallLayout` disables in-place updates inside `build/`, in debug/profile builds (`!kReleaseMode`), and under `FLUTTER_TEST`.

## Releasing on GitHub

Releases use a two-step GitHub Actions pipeline powered by Melos and **GitHub Immutable Releases**:

1. If workspace libraries under `packages/` have unreleased changes that `fterm` depends on, run **[Prepare release](../../.github/workflows/release-prepare.yml)** first so Melos versions and tags those packages.
2. Run **[Prepare fterm release](../../.github/workflows/release-fterm-prepare.yml)** (`Actions -> Prepare fterm release -> Run workflow`):
   - For a pre-release, set `prerelease: true` (automatic `-dev.N` bump) or pass `manual_version: X.Y.Z-rc.N` with `prerelease: false` (`manual_version` and `prerelease` cannot be combined).
   - To graduate a pre-release to stable, set `graduate: true` (`prerelease: false`, `manual_version: ''`) to promote `-dev.N` / `-rc.N` to `X.Y.Z`.
   - For a standard release, leave all inputs at defaults so Melos bumps from Conventional Commits and opens (or updates) a `chore(fterm-release): release fterm vX.Y.Z` pull request against `main`.
3. Review and merge that pull request into `main`. **[Release fterm](../../.github/workflows/release-fterm.yml)** builds the `macos-arm64`, `linux-x64`, and `windows-x64` archives with `--build-name`, uploads them to a draft release, and promotes `--draft=false` so GitHub locks the `fterm-vX.Y.Z` tag and `sha256:` asset digests as immutable. Note that `fterm`'s auto-updater requires `immutable: true` and rejects releases published before repository immutability was enabled (`<= v0.2.2`).

You can also trigger **[Release fterm](../../.github/workflows/release-fterm.yml)** manually via `workflow_dispatch` to cut a draft release or override the version string.
