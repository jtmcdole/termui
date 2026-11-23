# Setup Guide: Cloud Run (IAP) and Self-Hosted Reverse Proxies

> [!WARNING]
> `termui_caster` relays live interactive shells (`zsh`, `bash`, `pwsh`) over WebSockets. Always protect internet-facing deployments with strong perimeter authentication (such as Identity-Aware Proxy, Tailscale Serve, or `oauth2-proxy`) and store shared tokens outside shell history. Exposing a relay publicly without perimeter auth lets any leaked bearer token grant immediate Remote Code Execution (RCE) on every connected casting host.

Follow the steps below to deploy on Google Cloud Run with Identity-Aware Proxy (`--iap`). For Linux, macOS, Tailscale, `oauth2-proxy`, or Caddy, jump to [Self-Hosted Reverse Proxy Setup](#self-hosted-reverse-proxy-setup).

The `buildpack:` block in the root [pubspec.yaml](../../../pubspec.yaml) compiles `apps/termui_cast/server/bin/server.dart` as the server binary and builds `apps/fterm` to WebAssembly (`build/web`). Run `gcloud run deploy --source .` from the `termui` repository root so `.gcloudignore` uploads only the workspace manifests, `packages/`, and `apps/` required by Cloud Build. On startup, `termui_cast_server` binds `0.0.0.0:$PORT` and serves both the static `fterm` WASM client at `/` and the WebSocket endpoints at `/v1/caster` and `/v1/client`.

## 1. Enable APIs and Grant Cloud Build Permissions

New Google Cloud projects run source builds under the default Compute Engine service account without automatic storage, registry, or Secret Manager roles. Enable the required APIs and grant `roles/run.builder` once per project:

**Linux / macOS (`bash` / `zsh`)**
```bash
PROJECT_ID="your-gcp-project-id"
REGION="us-west2"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iap.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  --project="$PROJECT_ID"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/run.builder"
```

**Windows (`PowerShell`)**
```powershell
$env:PROJECT_ID = "your-gcp-project-id"
$env:REGION = "us-west2"
$env:PROJECT_NUMBER = (gcloud projects describe $env:PROJECT_ID --format="value(projectNumber)").Trim()
$env:RUNTIME_SA = "$($env:PROJECT_NUMBER)-compute@developer.gserviceaccount.com"

gcloud services enable `
  run.googleapis.com `
  cloudbuild.googleapis.com `
  artifactregistry.googleapis.com `
  secretmanager.googleapis.com `
  cloudresourcemanager.googleapis.com `
  iap.googleapis.com `
  iam.googleapis.com `
  iamcredentials.googleapis.com `
  --project="$env:PROJECT_ID"

gcloud projects add-iam-policy-binding $env:PROJECT_ID `
  --member="serviceAccount:$env:RUNTIME_SA" `
  --role="roles/run.builder"
```

## 2. Store Caster and Client Tokens in Secret Manager

Generate two independent 256-bit random tokens and store them in Secret Manager. This keeps secrets out of plaintext Cloud Run revision specs and audit logs:

**Linux / macOS (`bash` / `zsh`)**
```bash
CASTER_TOKEN="$(openssl rand -hex 32)"
CLIENT_TOKEN="$(openssl rand -hex 32)"

printf '%s' "$CASTER_TOKEN" | gcloud secrets create termui-cast-caster-token \
  --project="$PROJECT_ID" \
  --replication-policy="automatic" \
  --data-file=-

printf '%s' "$CLIENT_TOKEN" | gcloud secrets create termui-cast-client-token \
  --project="$PROJECT_ID" \
  --replication-policy="automatic" \
  --data-file=-

for SECRET in termui-cast-caster-token termui-cast-client-token; do
  gcloud secrets add-iam-policy-binding "$SECRET" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA}" \
    --role="roles/secretmanager.secretAccessor"
done
```

**Windows (`PowerShell`)**
```powershell
$b1 = New-Object byte[] 32; $b2 = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($b1); $rng.GetBytes($b2)
$env:CASTER_TOKEN = ($b1 | ForEach-Object ToString x2) -join ''
$env:CLIENT_TOKEN = ($b2 | ForEach-Object ToString x2) -join ''

$env:CASTER_TOKEN | gcloud secrets create termui-cast-caster-token `
  --project="$env:PROJECT_ID" `
  --replication-policy="automatic" `
  --data-file=-

$env:CLIENT_TOKEN | gcloud secrets create termui-cast-client-token `
  --project="$env:PROJECT_ID" `
  --replication-policy="automatic" `
  --data-file=-

foreach ($secret in @("termui-cast-caster-token", "termui-cast-client-token")) {
  gcloud secrets add-iam-policy-binding $secret `
    --project="$env:PROJECT_ID" `
    --member="serviceAccount:$env:RUNTIME_SA" `
    --role="roles/secretmanager.secretAccessor"
}
```

> [!NOTE]
> PowerShell pipeline input (`$env:CASTER_TOKEN | gcloud secrets create ... --data-file=-`) appends a trailing newline (`\r\n` or `\n`). `termui_cast_server` trims leading/trailing whitespace from `TERMUI_CAST_CASTER_TOKEN` and `TERMUI_CAST_CLIENT_TOKEN` on startup, so piped Secret Manager values match trimmed CLI tokens.

## 3. Deploy the Service from Source with Secret Manager and IAP

Run this from the `termui` repository root (`--source .`). Set `--max-instances=1` because `SessionRegistry` holds active stream pairs in process memory, and set `--concurrency=256` to match `termui_cast_server`'s 256-peer cap (Cloud Run defaults to `80`). Set `--timeout=3600` for one-hour WebSocket sessions, and pass `--no-allow-unauthenticated` and `--iap` so Identity-Aware Proxy protects the service from the first revision:

**Linux / macOS (`bash` / `zsh`)**
```bash
gcloud run deploy termui-cast \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --source . \
  --no-allow-unauthenticated \
  --iap \
  --max-instances=1 \
  --concurrency=256 \
  --timeout=3600 \
  --set-secrets="TERMUI_CAST_CASTER_TOKEN=termui-cast-caster-token:latest,TERMUI_CAST_CLIENT_TOKEN=termui-cast-client-token:latest"
```

**Windows (`PowerShell`)**
```powershell
gcloud run deploy termui-cast `
  --project="$env:PROJECT_ID" `
  --region="$env:REGION" `
  --source . `
  --no-allow-unauthenticated `
  --iap `
  --max-instances=1 `
  --concurrency=256 `
  --timeout=3600 `
  --set-secrets="TERMUI_CAST_CASTER_TOKEN=termui-cast-caster-token:latest,TERMUI_CAST_CLIENT_TOKEN=termui-cast-client-token:latest"
```

> [!NOTE]
> **Revision Rollouts & WebSocket Drain:** Even with `--max-instances=1`, Cloud Run briefly runs the old and new container revisions side by side while existing WebSocket connections drain on the retiring revision and new requests route to the new revision. During that window, a caster still attached to the retiring revision will not appear to a viewer routed to the new revision. After deploying a new revision, allow the rollout to finish and reconnect any active casters (for example via `SIGHUP` on macOS/Linux when started with `--keep-alive-on-hup`, or otherwise by restarting `termui_cast`) and reload viewer tabs so all peers land on the active revision.

## 4. Authorize Your User Account for IAP and Cloud Run Invoker

Grant your Google account `roles/run.invoker` on the Cloud Run service and `roles/iap.httpsResourceAccessor` on the IAP web resource. Update the Google Cloud SDK (`gcloud components update`) if your local CLI rejects `--iap` or `--resource-type=cloud-run`:

**Linux / macOS (`bash` / `zsh`)**
```bash
USER_EMAIL="$(gcloud config get-value account)"

gcloud run services add-iam-policy-binding termui-cast \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --member="user:${USER_EMAIL}" \
  --role="roles/run.invoker"

gcloud iap web add-iam-policy-binding \
  --project="$PROJECT_ID" \
  --resource-type=cloud-run \
  --region="$REGION" \
  --service=termui-cast \
  --member="user:${USER_EMAIL}" \
  --role="roles/iap.httpsResourceAccessor"
```

**Windows (`PowerShell`)**
```powershell
$env:USER_EMAIL = (gcloud config get-value account).Trim()

gcloud run services add-iam-policy-binding termui-cast `
  --project="$env:PROJECT_ID" `
  --region="$env:REGION" `
  --member="user:$env:USER_EMAIL" `
  --role="roles/run.invoker"

gcloud iap web add-iam-policy-binding `
  --project="$env:PROJECT_ID" `
  --resource-type=cloud-run `
  --region="$env:REGION" `
  --service=termui-cast `
  --member="user:$env:USER_EMAIL" `
  --role="roles/iap.httpsResourceAccessor"
```

> [!TIP]
> IAP caches negative access checks for 2 to 5 minutes if you visit the service URL before adding the `roles/iap.httpsResourceAccessor` binding. Visit `https://<service-url>/?gcp-iap-mode=CLEAR_LOGIN_COOKIE` to clear the cached IAP session cookie and force a fresh login check.

## 5. Provision a Service Account per Caster Host and Save Local Config

Create a dedicated service account for each machine that casts sessions. This lets you revoke a single host from IAP without rotating `TERMUI_CAST_CASTER_TOKEN`.

### Create and Authorize the Host Service Account

Service account IDs must be 6 to 30 lowercase letters, digits, or hyphens. If `gcloud iap web add-iam-policy-binding` reports `Invalid choice: 'cloud-run'`, run `gcloud components update` first or run step 3 with `gcloud beta iap web add-iam-policy-binding`:

**Linux / macOS (`bash` / `zsh`)**
```bash
USER_EMAIL="$(gcloud config get-value account)"
HOST_SLUG="$(hostname -s | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
HOST_SA_NAME="caster-${HOST_SLUG}"
HOST_SA_EMAIL="${HOST_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$HOST_SA_NAME" \
  --project="$PROJECT_ID" \
  --display-name="TermUI Caster (${HOST_SA_NAME})"

gcloud iam service-accounts add-iam-policy-binding "$HOST_SA_EMAIL" \
  --project="$PROJECT_ID" \
  --member="user:${USER_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator"

gcloud iam service-accounts add-iam-policy-binding "$HOST_SA_EMAIL" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${HOST_SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator"

gcloud run services add-iam-policy-binding termui-cast \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --member="serviceAccount:${HOST_SA_EMAIL}" \
  --role="roles/run.invoker"

gcloud iap web add-iam-policy-binding \
  --project="$PROJECT_ID" \
  --resource-type=cloud-run \
  --region="$REGION" \
  --service=termui-cast \
  --member="serviceAccount:${HOST_SA_EMAIL}" \
  --role="roles/iap.httpsResourceAccessor"
```

**Windows (`PowerShell`)**
```powershell
$env:USER_EMAIL = (gcloud config get-value account).Trim()
$env:HOST_SLUG = ($env:COMPUTERNAME.ToLower() -replace '[^a-z0-9-]', '')
$env:HOST_SA_NAME = "caster-$($env:HOST_SLUG)"
$env:HOST_SA_EMAIL = "$($env:HOST_SA_NAME)@$($env:PROJECT_ID).iam.gserviceaccount.com"

gcloud iam service-accounts create "$env:HOST_SA_NAME" `
  --project="$env:PROJECT_ID" `
  --display-name="TermUI Caster ($env:HOST_SA_NAME)"

gcloud iam service-accounts add-iam-policy-binding "$env:HOST_SA_EMAIL" `
  --project="$env:PROJECT_ID" `
  --member="user:$env:USER_EMAIL" `
  --role="roles/iam.serviceAccountTokenCreator"

gcloud iam service-accounts add-iam-policy-binding "$env:HOST_SA_EMAIL" `
  --project="$env:PROJECT_ID" `
  --member="serviceAccount:$env:HOST_SA_EMAIL" `
  --role="roles/iam.serviceAccountTokenCreator"

gcloud run services add-iam-policy-binding termui-cast `
  --project="$env:PROJECT_ID" `
  --region="$env:REGION" `
  --member="serviceAccount:$env:HOST_SA_EMAIL" `
  --role="roles/run.invoker"

gcloud iap web add-iam-policy-binding `
  --project="$env:PROJECT_ID" `
  --resource-type=cloud-run `
  --region="$env:REGION" `
  --service=termui-cast `
  --member="serviceAccount:$env:HOST_SA_EMAIL" `
  --role="roles/iap.httpsResourceAccessor"
```

If your organization enforces `constraints/iam.disableServiceAccountKeyCreation`, keep the machine logged into `gcloud` (`gcloud auth login`). `termui_cast` uses `--iap-service-account` (`$TERMUI_CAST_IAP_SERVICE_ACCOUNT`) to sign short-lived JWTs remotely via `gcloud iam service-accounts sign-jwt` without a private key file on disk.

If your project permits service-account keys and the target host does not have `gcloud` installed, export a key to `sa-key.json`. Pass `--iap-key-file` (`$TERMUI_CAST_IAP_KEY_FILE`) so `termui_cast` signs the `RS256` IAP JWT locally in pure Dart:

**Linux / macOS (`bash` / `zsh`)**
```bash
mkdir -p ~/.config/termui_cast && chmod 700 ~/.config/termui_cast
gcloud iam service-accounts keys create ~/.config/termui_cast/sa-key.json \
  --project="$PROJECT_ID" \
  --iam-account="$HOST_SA_EMAIL"
chmod 600 ~/.config/termui_cast/sa-key.json
```

**Windows (`PowerShell`)**
```powershell
$cfgDir = "$HOME\.config\termui_cast"
$keyPath = "$cfgDir\sa-key.json"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
icacls $cfgDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
gcloud iam service-accounts keys create $keyPath `
  --project="$env:PROJECT_ID" `
  --iam-account="$env:HOST_SA_EMAIL"
icacls $keyPath /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
```

### Save the Caster Environment Config on the Host

Store the relay URL, IAP credential setting, and caster token in a restricted local file. This keeps secrets out of shell history and process flags (`ps`):

**Linux / macOS (`bash` / `zsh`: `~/.config/termui_cast/env`)**
```bash
mkdir -p ~/.config/termui_cast && chmod 700 ~/.config/termui_cast
cat > ~/.config/termui_cast/env <<EOF
export TERMUI_CAST_SERVER_URL="wss://<service-url>/v1/caster"
export TERMUI_CAST_CASTER_TOKEN="${CASTER_TOKEN}"
export TERMUI_CAST_IAP_SERVICE_ACCOUNT="${HOST_SA_EMAIL}"
# Or pure-Dart local RS256 signing without gcloud:
# export TERMUI_CAST_IAP_KEY_FILE="\$HOME/.config/termui_cast/sa-key.json"
EOF
chmod 600 ~/.config/termui_cast/env
```

**Windows (`PowerShell`: `$HOME\.config\termui_cast\env.ps1`)**
```powershell
$cfgDir = "$HOME\.config\termui_cast"
$envPs1 = "$cfgDir\env.ps1"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
icacls $cfgDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
@"
`$env:TERMUI_CAST_SERVER_URL = "wss://<service-url>/v1/caster"
`$env:TERMUI_CAST_CASTER_TOKEN = "$env:CASTER_TOKEN"
`$env:TERMUI_CAST_IAP_SERVICE_ACCOUNT = "$env:HOST_SA_EMAIL"
# Or pure-Dart local RS256 signing without gcloud:
# `$env:TERMUI_CAST_IAP_KEY_FILE = "`$HOME\.config\termui_cast\sa-key.json"
"@ | Set-Content -Path $envPs1 -Encoding UTF8
icacls $envPs1 /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
```

## 6. Connect the Viewer and Cast a Session

Open `https://<service-url>/` (or `https://<service-url>/#token=<client-token>`) in Chrome. The web viewer immediately scrubs `#token=...` from the browser address bar using `history.replaceState` and connects to `wss://<service-url>/v1/client`.

On the casting machine, load the environment config and run `termui_cast` from a prebuilt release archive (`termui_cast-<os>-<arch>`, keeping `bin/` and `lib/` together) or via `dart run`:

**Linux / macOS (`bash` / `zsh`)**
```bash
source ~/.config/termui_cast/env
# Using a prebuilt release bundle (or `dart run apps/termui_cast/caster_cli/bin/termui_cast.dart`):
./bin/termui_cast --title "$(hostname -s)-zsh" -- zsh
```

**Windows (`PowerShell`)**
```powershell
. "$HOME\.config\termui_cast\env.ps1"
# Using a prebuilt release bundle (or `dart run apps/termui_cast/caster_cli/bin/termui_cast.dart`):
& "./bin/termui_cast.exe" --title "$($env:COMPUTERNAME.ToLower())-pwsh" '--' powershell
```

`termui_cast` pre-warms and caches the signed IAP JWT in memory and refreshes it before the 1-hour Cloud Run timeout. It also strips `TERMUI_CAST_*` variables from the spawned child shell environment.

> [!TIP]
> On macOS and Linux, `SIGHUP` shuts down `termui_cast` cleanly by default. Start `termui_cast` with `--keep-alive-on-hup` if you want `SIGHUP` to trigger an immediate reconnect/check-in while keeping the local shell alive (for example after sleep or a network change); otherwise restart `termui_cast`. Use `pkill -HUP -x termui_cast` for prebuilt binaries. From source, inspect PIDs with `pgrep -fl termui_cast.dart` and run `kill -HUP <pid>` to avoid signaling editors or `termui_cast_server`.

## Unauthenticated Proxy Ingress (Not Recommended)

> [!CAUTION]
> **High Risk (Single-Factor Bearer Token Only):** Bypassing Identity-Aware Proxy (`allUsers` or `--no-invoker-iam-check`) exposes the Cloud Run WebSocket endpoints directly to the public internet. Although `termui_cast_server` enforces `TERMUI_CAST_CASTER_TOKEN` and `TERMUI_CAST_CLIENT_TOKEN` on every WebSocket upgrade, there is no second authentication factor, identity audit trail, or per-host IAM revocation. Use these commands only in throwaway sandbox environments where IAP is unavailable.

If your organization permits public Cloud Run services and you choose not to use IAP:

```bash
gcloud run services add-iam-policy-binding termui-cast \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --member="allUsers" \
  --role="roles/run.invoker"
```

Or, if an organization policy (`iam.allowedPolicyMemberDomains`) blocks `allUsers` on IAM bindings and IAP is not available:

```bash
gcloud run services update termui-cast \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --no-invoker-iam-check
```

## Self-Hosted Reverse Proxy Setup

You can run `termui_cast_server` on a Linux workstation, home server, or VM behind a TLS-terminating reverse proxy. Bind the relay to loopback (`127.0.0.1:8420`) so port `8420` stays closed to your LAN (including on Fedora and other hosts with strict firewalls).

### Core Relay Flags

1. Bind to loopback with `--host 127.0.0.1 --port 8420` and pass `--allowed-origin https://<public-host>`. On loopback WebSocket upgrades, `--allowed-origin` permits matching proxied `Host` headers (defaulting omitted ports to `443` or `80`, or matching an explicit port in `--allowed-origin`) while still blocking DNS rebinding from unknown hosts.
2. Keep `/v1/caster` token-gated with `--caster-token-file` (or `$TERMUI_CAST_CASTER_TOKEN`). Create a restricted token file first:

```bash
mkdir -p ~/.config/termui_cast && chmod 700 ~/.config/termui_cast
openssl rand -hex 32 > ~/.config/termui_cast/caster.token
chmod 600 ~/.config/termui_cast/caster.token
```

3. Trust your proxy for viewer auth by passing `--trust-proxy-client-auth` and `--require-client-auth-header <header>`. When enabled, `termui_cast_server` allows tokenless `/v1/client` upgrades only when that HTTP header is non-empty. `fterm` Web attempts one silent same-origin connection on startup and skips the token dialog.
4. Serve the compiled web bundle from `--web-dir apps/fterm/build/web`. `termui_cast_server` serves `.br` and `.gz` sidecars when present. Otherwise it caches on-the-fly `gzip` responses up to 32 MiB for compressible assets (`.wasm`, `.js`, `.mjs`, `.html`, `.json`, `.css`, `.svg`, `.ttf`, `.otf`).

> [!CAUTION]
> Never combine `--trust-proxy-client-auth` with direct network access to port `8420`. Make sure your reverse proxy strips any client-supplied copy of the header named in `--require-client-auth-header` before forwarding traffic. `termui_cast_server` rejects `--trust-proxy-client-auth` if you also set `--client-token*` or `--insecure-no-auth`.

### Optional Non-Root Subpath Hosting (`--base-path`)

To mount the relay under a subpath such as `https://<public-host>/term/`, pass `--base-path /term` (or `TERMUI_CAST_BASE_PATH=/term`). The server mounts `/term/`, `/term/healthz`, `/term/v1/caster`, and `/term/v1/client`, and redirects `GET /term` to `/term/` (`308`).

`termui_cast_server` rewrites `<base href="/">` to `<base href="/term/">` in `index.html` in memory. One prebuilt `apps/fterm/build/web` bundle works at any subpath without rebuilding Flutter. On casting hosts, set `TERMUI_CAST_SERVER_URL="wss://<public-host>/term/v1/caster"` (or `https://<public-host>/term`, which normalizes to `/term/v1/caster`).

### Option A: Tailscale Serve

Tailscale Serve terminates HTTPS for your tailnet and injects the `Tailscale-User-Login` identity header on every request. Start `termui_cast_server` on loopback:

```bash
./build/termui_cast_server \
  --host 127.0.0.1 \
  --port 8420 \
  --web-dir apps/fterm/build/web \
  --caster-token-file ~/.config/termui_cast/caster.token \
  --allowed-origin "https://<node>.<tailnet>.ts.net" \
  --trust-proxy-client-auth \
  --require-client-auth-header Tailscale-User-Login
```

Expose the loopback listener to your tailnet:

```bash
tailscale serve --bg http://127.0.0.1:8420
```

If you also pass `--base-path /term` to `termui_cast_server`, match the upstream path in Tailscale Serve (`tailscale serve --bg --set-path /term http://127.0.0.1:8420/term`). Do not use `tailscale funnel` with `--trust-proxy-client-auth`, because Funnel admits unauthenticated public internet requests.

### Option B: `oauth2-proxy`

`oauth2-proxy` authenticates browser users against an OIDC or GitHub provider and forwards `X-Forwarded-Email`. Because loopback `--allowed-origin` validates proxied `Host` headers natively, keep `--pass-host-header=true` enabled.

Start `termui_cast_server` on loopback:

```bash
./build/termui_cast_server \
  --host 127.0.0.1 \
  --port 8420 \
  --web-dir apps/fterm/build/web \
  --caster-token-file ~/.config/termui_cast/caster.token \
  --allowed-origin "https://term.example.com" \
  --trust-proxy-client-auth \
  --require-client-auth-header X-Forwarded-Email
```

Run `oauth2-proxy` in front of `127.0.0.1:8420` (behind TLS termination on `https://term.example.com`):

```bash
oauth2-proxy \
  --http-address="127.0.0.1:4180" \
  --upstream="http://127.0.0.1:8420" \
  --reverse-proxy=true \
  --pass-host-header=true \
  --pass-user-headers=true \
  --skip-auth-route="^/v1/caster$" \
  --email-domain="example.com"
```

The `--skip-auth-route="^/v1/caster$"` rule lets remote `termui_cast` hosts reach `/v1/caster` using `TERMUI_CAST_CASTER_TOKEN` while browsers still require OAuth login for `/` and `/v1/client`. If you use `--base-path /term`, update the skip regex to `^/term/v1/caster$` (and optionally set `--proxy-prefix="/term/oauth2"` if you want OAuth callbacks inside `/term/`).

### Option C: Caddy (Native Host or Podman / Docker)

Caddy handles automatic HTTPS and WebSocket upgrades with zero extra WebSocket directives. When running `termui_cast_server` in Podman or Docker, bind `--host 0.0.0.0 --port 8420` inside the container, mount the compiled web bundle (`--web-dir /srv/web`), and publish only to host loopback with `-p 127.0.0.1:8420:8420`:

```bash
podman run -d --name termui-cast \
  -p 127.0.0.1:8420:8420 \
  -v ~/.config/termui_cast/caster.token:/run/secrets/caster.token:ro,Z \
  -v ./apps/fterm/build/web:/srv/web:ro,Z \
  termui-cast-server \
  --host 0.0.0.0 \
  --port 8420 \
  --web-dir /srv/web \
  --caster-token-file /run/secrets/caster.token \
  --allowed-origin "https://term.example.com" \
  --base-path /term \
  --trust-proxy-client-auth \
  --require-client-auth-header X-Forwarded-Email
```

Then proxy `/term`, `/term/*`, and `oauth2-proxy`'s `/oauth2/*` callback routes through Caddy (forwarding to `oauth2-proxy` on `127.0.0.1:4180` for browser auth, or directly to `127.0.0.1:8420` when Caddy enforces `forward_auth` itself):

```caddyfile
term.example.com {
  @term path /term /term/* /oauth2/*
  handle @term {
    reverse_proxy 127.0.0.1:4180
  }
}
```

If Caddy handles auth directly (such as `forward_auth`), strip incoming `X-Forwarded-Email` first. Then copy the verified user header when proxying to `127.0.0.1:8420`.

### Connecting a Caster Host

On each casting machine, point `TERMUI_CAST_SERVER_URL` at your proxy URL and start an interactive shell:

```bash
export TERMUI_CAST_SERVER_URL="wss://term.example.com/term/v1/caster"
export TERMUI_CAST_CASTER_TOKEN="$(cat ~/.config/termui_cast/caster.token)"
termui_cast --keep-alive-on-hup --title "$(hostname -s)-zsh" -- zsh
```

Interactive shells enable remote shell spawning (`--allow-spawn`) automatically so browser tabs can open new shells from the same `termui_cast` process. Pass `--no-allow-spawn` if you want viewers restricted to the single initial shell.
