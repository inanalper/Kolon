#!/bin/bash
# Downloads the pinned libduckdb release into Vendor/duckdb/.
# Run once before building; bump DUCKDB_VERSION to upgrade.
set -euo pipefail

DUCKDB_VERSION="v1.5.4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/duckdb"
STAMP="$DEST/.version"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$DUCKDB_VERSION" && -f "$DEST/libduckdb.dylib" ]]; then
    echo "libduckdb $DUCKDB_VERSION already present, skipping."
    exit 0
fi

mkdir -p "$DEST"
TMP_ZIP="$(mktemp -t libduckdb).zip"
trap 'rm -f "$TMP_ZIP"' EXIT

URL="https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/libduckdb-osx-universal.zip"
echo "Downloading: $URL"
curl -fL --retry 3 -o "$TMP_ZIP" "$URL"

unzip -o "$TMP_ZIP" -d "$DEST" > /dev/null
echo "$DUCKDB_VERSION" > "$STAMP"

# Ensure the install name is @rpath so the dylib can be embedded
install_name_tool -id "@rpath/libduckdb.dylib" "$DEST/libduckdb.dylib"

echo "Done: $(ls "$DEST")"
otool -L "$DEST/libduckdb.dylib" | head -3
