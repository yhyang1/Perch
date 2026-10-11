#!/bin/bash
# Build only on an Apple Silicon Mac; users of the resulting app need no Python.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'This release target requires native macOS arm64.' >&2; exit 2; }
source "$ROOT/packaging/runtime.env"
VERSION="${1:-v0.1.0-alpha.1}"
mkdir -p "$ROOT/build/cache"
ARCHIVE="$ROOT/build/cache/$PERCH_RUNTIME_FILENAME"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$PERCH_RUNTIME_URL" -o "$ARCHIVE.partial"
    mv "$ARCHIVE.partial" "$ARCHIVE"
fi
printf '%s  %s\n' "$PERCH_RUNTIME_SHA256" "$ARCHIVE" | shasum -a 256 -c -
WORK="$(mktemp -d "$ROOT/build/runtime.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Only this previously checksum-verified upstream archive is extracted.
tar -xzf "$ARCHIVE" -C "$WORK"
PYTHON="$WORK/python/bin/python3"
"$PYTHON" -I -S -B -c "import platform,sys; assert platform.machine() == 'arm64'; assert platform.python_version() == '$PERCH_PYTHON_VERSION'; print(sys.version)"
cd "$ROOT"
"$PYTHON" -B scripts/build_macos.py --runtime "$WORK/python" --version "$VERSION"
