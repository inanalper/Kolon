#!/bin/bash
# Builds a Release Kolon.app and packages per-architecture zips for a GitHub
# release (Kolon-<version>-arm64.zip / -x86_64.zip). Users download only their
# own architecture; the cask picks via on_arm/on_intel.
# Usage: ./Scripts/package-release.sh <version>   (e.g. 0.1.1)
# Prints the sha256 of each zip to paste into Casks/kolon.rb in homebrew-tap.
set -euo pipefail

VERSION="${1:?usage: package-release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$ROOT/Scripts/build-duckdb.sh"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild -project "$ROOT/Kolon.xcodeproj" -scheme Kolon -configuration Release \
           -derivedDataPath "$ROOT/build" \
           MARKETING_VERSION="$VERSION" \
           build

APP="$ROOT/build/Build/Products/Release/Kolon.app"
mkdir -p "$DIST"

# Thinning invalidates the ad-hoc signature, so re-sign inside-out afterwards,
# carrying each binary's original entitlements (the appex needs its sandbox).
resign() { # <bundle-or-binary>
    local target="$1" ents
    ents="$(mktemp -t ents).plist"
    if codesign -d --entitlements - --xml "$target" > "$ents" 2>/dev/null && [[ -s "$ents" ]]; then
        codesign --force --sign - --entitlements "$ents" "$target"
    else
        codesign --force --sign - "$target"
    fi
    rm -f "$ents"
}

for ARCH in arm64 x86_64; do
    STAGE="$DIST/stage-$ARCH"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/Kolon.app"

    while IFS= read -r -d '' macho; do
        if lipo "$macho" -verify_arch "$ARCH" 2>/dev/null && lipo -info "$macho" | grep -q "^Architectures"; then
            lipo "$macho" -thin "$ARCH" -output "$macho.thin"
            mv "$macho.thin" "$macho"
        fi
    done < <(find "$STAGE/Kolon.app" -type f \( -perm -u+x -o -name "*.dylib" \) -print0)

    resign "$STAGE/Kolon.app/Contents/PlugIns/KolonQL.appex/Contents/Frameworks/libduckdb.dylib"
    resign "$STAGE/Kolon.app/Contents/PlugIns/KolonQL.appex"
    resign "$STAGE/Kolon.app"
    codesign --verify --deep --strict "$STAGE/Kolon.app"

    ZIP="$DIST/Kolon-$VERSION-$ARCH.zip"
    rm -f "$ZIP"
    # ditto preserves signatures/metadata the way Archive Utility expects
    (cd "$STAGE" && ditto -c -k --keepParent "Kolon.app" "$ZIP")
done

echo
for ARCH in arm64 x86_64; do
    ZIP="$DIST/Kolon-$VERSION-$ARCH.zip"
    echo "Created: $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
    echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
done
