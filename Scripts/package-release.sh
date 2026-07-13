#!/bin/bash
# Builds a Release Kolon.app and packages the GitHub release assets:
#   Kolon-<version>-arm64.zip / -x86_64.zip  (what the cask installs)
#   Kolon-<version>.dmg                      (universal, drag-install for direct downloads)
# Usage: ./Scripts/package-release.sh <version>   (e.g. 0.3.0)
# Prints the sha256 of each zip to paste into Casks/kolon.rb in homebrew-tap.
#
# Signing: if a "Developer ID Application" identity is in the keychain, every
# asset is signed with it (hardened runtime + timestamp) and notarized via the
# $NOTARY_PROFILE keychain profile (default kolon-notary), then stapled.
# Without the identity it falls back to ad-hoc signing and skips notarization.
set -euo pipefail

VERSION="${1:?usage: package-release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-kolon-notary}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
if [[ -n "$IDENTITY" ]]; then
    echo "Signing with: $IDENTITY (notary profile: $NOTARY_PROFILE)"
else
    echo "WARNING: no Developer ID Application identity found — ad-hoc signing, no notarization" >&2
fi

"$ROOT/Scripts/build-duckdb.sh"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild -project "$ROOT/Kolon.xcodeproj" -scheme Kolon -configuration Release \
           -derivedDataPath "$ROOT/build" \
           MARKETING_VERSION="$VERSION" \
           CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
           build

APP="$ROOT/build/Build/Products/Release/Kolon.app"
mkdir -p "$DIST"

# Re-sign one binary/bundle, carrying its original entitlements (the appex
# needs its sandbox). With a Developer ID identity, notarization additionally
# requires the hardened runtime and a secure timestamp.
resign() { # <bundle-or-binary>
    local target="$1" ents flags=()
    if [[ -n "$IDENTITY" ]]; then
        flags=(--sign "$IDENTITY" --options runtime --timestamp)
    else
        flags=(--sign -)
    fi
    ents="$(mktemp -t ents).plist"
    if codesign -d --entitlements - --xml "$target" > "$ents" 2>/dev/null && [[ -s "$ents" ]]; then
        # Xcode injects this debug entitlement into ad-hoc builds; shipping it
        # is a notarization rejection
        /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$ents" 2>/dev/null || true
        codesign --force "${flags[@]}" --entitlements "$ents" "$target"
    else
        codesign --force "${flags[@]}" "$target"
    fi
    rm -f "$ents"
}

# Thinning (and Developer ID re-signing) invalidates signatures, so always
# re-sign inside-out: dylib, then appex, then app.
resign_app() { # <Kolon.app>
    resign "$1/Contents/PlugIns/KolonQL.appex/Contents/Frameworks/libduckdb.dylib"
    resign "$1/Contents/PlugIns/KolonQL.appex"
    resign "$1"
    codesign --verify --deep --strict "$1"
}

# Submit to Apple's notary service and fail loudly unless Accepted.
notarize() { # <zip-or-dmg>
    [[ -n "$IDENTITY" ]] || return 0
    echo "Notarizing $(basename "$1")…"
    local out
    out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    if ! grep -q '"status":"Accepted"' <<< "$out"; then
        echo "Notarization FAILED for $1:" >&2
        echo "$out" >&2
        local id
        id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<< "$out" | head -1)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        return 1
    fi
}

zip_app() { # <stage-dir> <zip>  — ditto preserves signatures/metadata
    rm -f "$2"
    (cd "$1" && ditto -c -k --keepParent "Kolon.app" "$2")
}

# --- Universal app (feeds the DMG): sign, notarize via a temp zip, staple ---
UNISTAGE="$DIST/stage-universal"
rm -rf "$UNISTAGE"
mkdir -p "$UNISTAGE"
ditto "$APP" "$UNISTAGE/Kolon.app"
resign_app "$UNISTAGE/Kolon.app"
if [[ -n "$IDENTITY" ]]; then
    zip_app "$UNISTAGE" "$DIST/Kolon-universal-notary.zip"
    notarize "$DIST/Kolon-universal-notary.zip"
    xcrun stapler staple "$UNISTAGE/Kolon.app"
    rm -f "$DIST/Kolon-universal-notary.zip"
fi

# --- Per-arch zips: thin, sign, notarize, staple, re-zip ---
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

    resign_app "$STAGE/Kolon.app"
    ZIP="$DIST/Kolon-$VERSION-$ARCH.zip"
    zip_app "$STAGE" "$ZIP"
    if [[ -n "$IDENTITY" ]]; then
        notarize "$ZIP"
        xcrun stapler staple "$STAGE/Kolon.app"
        zip_app "$STAGE" "$ZIP"   # re-zip so the download carries the ticket
    fi
done

# --- Universal DMG: temple background, app + Applications drop target ---
"$ROOT/Scripts/build-dmg.sh" "$VERSION" "$UNISTAGE/Kolon.app"
DMG="$DIST/Kolon-$VERSION.dmg"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

echo
for ASSET in "Kolon-$VERSION-arm64.zip" "Kolon-$VERSION-x86_64.zip" "Kolon-$VERSION.dmg"; do
    echo "Created: $DIST/$ASSET ($(du -h "$DIST/$ASSET" | cut -f1 | tr -d ' '))"
    echo "sha256:  $(shasum -a 256 "$DIST/$ASSET" | cut -d' ' -f1)"
done
if [[ -n "$IDENTITY" ]]; then
    spctl --assess --type execute --verbose "$UNISTAGE/Kolon.app" || true
fi
