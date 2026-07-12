#!/bin/bash
# Builds a slim libduckdb from source into Vendor/duckdb/ — parquet-only by
# default, universal (arm64 + x86_64). Replaces fetch-duckdb.sh's official
# dylib (~107 MB, full of unused extensions) with a much smaller one.
#
# Usage:
#   ./Scripts/build-duckdb.sh
#   DUCKDB_EXTENSIONS='parquet;json;icu' ./Scripts/build-duckdb.sh   # Pro build
#
# Bump DUCKDB_VERSION to upgrade; the source tree is cached under build/.
set -euo pipefail

DUCKDB_VERSION="v1.5.4"
EXTENSIONS="${DUCKDB_EXTENSIONS:-parquet}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/duckdb"
STAMP="$DEST/.version"
STAMP_VALUE="${DUCKDB_VERSION}-slim(${EXTENSIONS})"
SRC="${DUCKDB_BUILD_DIR:-$ROOT/build/duckdb-src}"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" && -f "$DEST/libduckdb.dylib" ]]; then
    echo "libduckdb $STAMP_VALUE already present, skipping."
    exit 0
fi

if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 --branch "$DUCKDB_VERSION" https://github.com/duckdb/duckdb.git "$SRC"
else
    CURRENT_TAG="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$CURRENT_TAG" != "$DUCKDB_VERSION" ]]; then
        git -C "$SRC" fetch --depth 1 origin tag "$DUCKDB_VERSION"
        git -C "$SRC" checkout -f "$DUCKDB_VERSION"
    fi
fi

BUILD="$SRC/build/kolon-release"
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DOSX_BUILD_UNIVERSAL=1 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCORE_EXTENSIONS="$EXTENSIONS" \
    -DENABLE_EXTENSION_AUTOLOADING=0 \
    -DDISABLE_EXTENSION_LOAD=1 \
    -DBUILD_SHELL=OFF \
    -DBUILD_UNITTESTS=OFF

cmake --build "$BUILD" --parallel "$(sysctl -n hw.ncpu)"

DYLIB="$BUILD/src/libduckdb.dylib"
[[ -f "$DYLIB" ]] || { echo "error: expected dylib not found at $DYLIB" >&2; exit 1; }

mkdir -p "$DEST"
cp "$DYLIB" "$DEST/libduckdb.dylib"
strip -x "$DEST/libduckdb.dylib"
install_name_tool -id "@rpath/libduckdb.dylib" "$DEST/libduckdb.dylib"
cp "$SRC/src/include/duckdb.h" "$DEST/duckdb.h"
echo "$STAMP_VALUE" > "$STAMP"

echo "Done: $STAMP_VALUE"
ls -lh "$DEST/libduckdb.dylib"
lipo -info "$DEST/libduckdb.dylib"
