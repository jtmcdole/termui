#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <web-build-dir> <output-tar-gz>" >&2
  exit 64
fi

SRC_DIR="$1"
OUT_ARCHIVE="$2"

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

if ! grep -q '"useLocalCanvasKit":true' "${SRC_DIR}/flutter_bootstrap.js"; then
  echo "Error: ${SRC_DIR}/flutter_bootstrap.js is missing \"useLocalCanvasKit\":true (rebuild with --no-web-resources-cdn)" >&2
  exit 1
fi

if ! command -v gzip >/dev/null 2>&1; then
  echo "Error: gzip executable not found on PATH" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

mkdir -p "${STAGE_DIR}/web"
cp -R "${SRC_DIR}/." "${STAGE_DIR}/web/"

# Remove any stale sidecars and debug symbol/source-map files not needed at runtime.
find "${STAGE_DIR}/web" -type f \( -name '*.br' -o -name '*.gz' -o -name '*.symbols' -o -name '*.map' \) -delete

# Replace every compressible static asset negotiated by StaticWebHandler
# (.wasm, .js, .mjs, .html, .json, .css, .svg, .ttf, .otf) with its .gz form
# so the archive carries no redundant uncompressed duplicates. StaticWebHandler
# streams .gz directly to gzip-capable browsers (HTTP and HTTPS) and gunzips
# on the fly for non-gzip clients or --base-path HTML rewrites.
while IFS= read -r -d '' asset; do
  gzip -9 -f "$asset"
done < <(
  find "${STAGE_DIR}/web" -type f \( \
    -name '*.wasm' -o \
    -name '*.js' -o \
    -name '*.mjs' -o \
    -name '*.html' -o \
    -name '*.json' -o \
    -name '*.css' -o \
    -name '*.svg' -o \
    -name '*.ttf' -o \
    -name '*.otf' \
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

mkdir -p "$(dirname "$OUT_ARCHIVE")"
COPYFILE_DISABLE=1 tar -C "$STAGE_DIR" -czf "$OUT_ARCHIVE" web

ARCHIVE_LIST_FILE="${STAGE_DIR}/archive.list"
tar -tzf "$OUT_ARCHIVE" > "$ARCHIVE_LIST_FILE"
for required in \
  web/index.html.gz \
  web/flutter_bootstrap.js.gz \
  web/main.dart.wasm.gz; do
  if ! grep -Fqx "$required" "$ARCHIVE_LIST_FILE"; then
    echo "Error: archive ${OUT_ARCHIVE} is missing ${required}" >&2
    exit 1
  fi
done
for forbidden in \
  web/index.html \
  web/main.dart.wasm \
  web/main.dart.wasm.br; do
  if grep -Fqx "$forbidden" "$ARCHIVE_LIST_FILE"; then
    echo "Error: archive ${OUT_ARCHIVE} unexpectedly contains ${forbidden}" >&2
    exit 1
  fi
done
if grep -Eq '\.(symbols|map)$' "$ARCHIVE_LIST_FILE"; then
  echo "Error: archive ${OUT_ARCHIVE} unexpectedly contains debug symbol or map files" >&2
  exit 1
fi
