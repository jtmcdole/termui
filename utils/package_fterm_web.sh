#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: package_fterm_web.sh <web-build-dir> <output-tar-gz>

Packages a Flutter WASM web build (compiled with --no-web-resources-cdn) into a
web/-rooted tar.gz archive where compressible assets are stored as deterministic
.gz files without uncompressed duplicates, and SDK debug symbol/map files are
stripped.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 64
fi

SRC_DIR="$1"
OUT_ARCHIVE="$2"

if [ -z "$OUT_ARCHIVE" ] || [ -d "$OUT_ARCHIVE" ]; then
  echo "Error: invalid output archive path: '${OUT_ARCHIVE}'" >&2
  exit 64
fi

if [ ! -d "$SRC_DIR" ]; then
  echo "Error: web build directory not found: $SRC_DIR" >&2
  exit 1
fi

for required in index.html flutter_bootstrap.js main.dart.wasm; do
  if [ ! -f "${SRC_DIR}/${required}" ]; then
    echo "Error: missing required Flutter web build output: ${SRC_DIR}/${required}" >&2
    exit 1
  fi
done

if [ ! -d "${SRC_DIR}/canvaskit" ]; then
  echo "Error: missing local canvaskit directory: ${SRC_DIR}/canvaskit (rebuild with --no-web-resources-cdn)" >&2
  exit 1
fi

if ! grep -Eq '"useLocalCanvasKit"[[:space:]]*:[[:space:]]*true' "${SRC_DIR}/flutter_bootstrap.js"; then
  echo "Error: ${SRC_DIR}/flutter_bootstrap.js is missing \"useLocalCanvasKit\":true (rebuild with --no-web-resources-cdn)" >&2
  exit 1
fi

for tool in gzip tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: ${tool} executable not found on PATH" >&2
    exit 1
  fi
done

STAGE_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

mkdir -p "${STAGE_DIR}/web"
cp -RL "${SRC_DIR}/." "${STAGE_DIR}/web/"

# Remove any stale sidecars and debug symbol/source-map files not needed at runtime.
find "${STAGE_DIR}/web" -type f \( -iname '*.br' -o -iname '*.gz' -o -iname '*.symbols' -o -iname '*.map' \) -delete

# Replace every compressible static asset negotiated by StaticWebHandler
# (.wasm, .js, .mjs, .html, .json, .css, .svg, .ttf, .otf) with its deterministic
# .gz form so the archive carries no redundant uncompressed duplicates.
while IFS= read -r -d '' asset; do
  gzip -9 -n -f "$asset"
done < <(
  find "${STAGE_DIR}/web" -type f \( \
    -iname '*.wasm' -o \
    -iname '*.js' -o \
    -iname '*.mjs' -o \
    -iname '*.html' -o \
    -iname '*.json' -o \
    -iname '*.css' -o \
    -iname '*.svg' -o \
    -iname '*.ttf' -o \
    -iname '*.otf' \
  \) -print0
)

for required in \
  web/index.html.gz \
  web/flutter_bootstrap.js.gz \
  web/main.dart.wasm.gz; do
  if [ ! -s "${STAGE_DIR}/${required}" ]; then
    echo "Error: expected non-empty staged asset missing: ${required}" >&2
    exit 1
  fi
done

TMP_ARCHIVE="${STAGE_DIR}/out.tar.gz"
COPYFILE_DISABLE=1 tar -C "$STAGE_DIR" -czf "$TMP_ARCHIVE" web

ARCHIVE_LIST_FILE="${STAGE_DIR}/archive.list"
tar -tzf "$TMP_ARCHIVE" > "$ARCHIVE_LIST_FILE"
for required in \
  web/index.html.gz \
  web/flutter_bootstrap.js.gz \
  web/main.dart.wasm.gz; do
  if ! grep -Fqx "$required" "$ARCHIVE_LIST_FILE"; then
    echo "Error: archive ${OUT_ARCHIVE} is missing ${required}" >&2
    exit 1
  fi
done
if grep -Eiq '\.(wasm|js|mjs|html|json|css|svg|ttf|otf|br|symbols|map)$' "$ARCHIVE_LIST_FILE"; then
  echo "Error: archive ${OUT_ARCHIVE} unexpectedly contains uncompressed, brotli, or debug files" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_ARCHIVE")"
mv -f "$TMP_ARCHIVE" "$OUT_ARCHIVE"
