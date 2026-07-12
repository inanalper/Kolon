#!/bin/bash
# Builds a Release Kolon.app and packages it as a zip for a GitHub release.
# Usage: ./Scripts/package-release.sh <version>   (e.g. 0.1.0)
# Prints the sha256 to paste into the Homebrew cask (Casks/kolon.rb in homebrew-tap).
set -euo pipefail

VERSION="${1:?usage: package-release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$ROOT/Scripts/fetch-duckdb.sh"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild -project "$ROOT/Kolon.xcodeproj" -scheme Kolon -configuration Release \
           -derivedDataPath "$ROOT/build" \
           MARKETING_VERSION="$VERSION" \
           build

mkdir -p "$DIST"
ZIP="$DIST/Kolon-$VERSION.zip"
rm -f "$ZIP"
# ditto preserves signatures/metadata the way Archive Utility expects
ditto -c -k --keepParent "$ROOT/build/Build/Products/Release/Kolon.app" "$ZIP"

echo
echo "Created: $ZIP"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
