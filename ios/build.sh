#!/usr/bin/env bash
# Builds Persona 4 Golden for iPhone / iPad from your own game files and packs an IPA to sideload (ESign, AltStore,
# SideStore, Sideloadly...), which signs it with its own certificate.
#
#   GAME   folder with your extracted exefs/ and romfs/ (tools/nsz_extract.py makes it from your NSZ / NSP)
#   OUT    work folder for the generated code, objects, the app and the IPA (default ~/P4G-iOS)
#   DEPS   SDL3 + FFmpeg built for iOS (include/, lib/; default $OUT/deps-ios)
#   BUILD  the IPA's build number (default: the date and time)
#   SKIP_GEN=1  reuse the generated code already in $OUT/gen-ios (GAME not needed)
#
# The IPA holds the game's code, recompiled from YOUR files: it is for your own device. Don't share it.
# Game data (romfs) is not in it: copy exefs/ and romfs/ into the app's game folder with the Files app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SKIP_GEN="${SKIP_GEN:-}"
GAME="${GAME:-}"
[ -n "$SKIP_GEN" ] || [ -n "$GAME" ] || { echo "set GAME to the folder with exefs/ and romfs/" >&2; exit 1; }
OUT="${OUT:-$HOME/P4G-iOS}"
DEPS="${DEPS:-$OUT/deps-ios}"
GEN="$OUT/gen-ios"
B="$OUT/build-ios"
PY="${PY:-python3}"
VERSION="$(sed -n 's/^#define P4G_VERSION "\(.*\)"/\1/p' "$REPO/runtime/rt.h")"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"

[ -n "$SKIP_GEN" ] || [ -f "$GAME/exefs/main" ] || { echo "No exefs/main in $GAME" >&2; exit 1; }
[ -f "$DEPS/lib/libSDL3.a" ] && [ -f "$DEPS/lib/libavcodec.a" ] || { echo "SDL3 / FFmpeg for iOS missing in $DEPS" >&2; exit 1; }

cd "$REPO"
# 1. the game code, lifted to C at the iOS guest base (runtime/rt.h GUEST_LO); only redone when the inputs change
[ -n "$SKIP_GEN" ] || make gen GAME="$GAME" GEN="$GEN" BASE=0x7000000000 PY="$PY"
# 2. compile and link (2 jobs: the Mac stays usable)
nice -n 19 make -f ios/ios.mk -j2 GEN="$GEN" DEPS="$DEPS" B="$B"

# 3. the app bundle
APP="$B/Persona 4 Golden.app"
rm -rf "$APP"
mkdir -p "$APP"
cp "$B/P4G" "$APP/P4G"
strip -x "$APP/P4G" 2>/dev/null || true
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" ios/Info.plist > "$APP/Info.plist"
plutil -lint "$APP/Info.plist" >/dev/null
$PY ios/make_icon.py "$B/icons" || ls "$B"/icons/AppIcon*.png >/dev/null  # (no Pillow: the icons from the last build)
cp "$B"/icons/AppIcon*.png "$APP/"
printf 'APPL????' > "$APP/PkgInfo"

# 4. checks: no game data, no signing material, no build machine paths in the binary
found="$(find "$APP" -type f \( -iname '*.cpk' -o -iname '*.nso' -o -iname '*.nsp' -o -iname '*.nsz' -o -iname '*.xci' \
           -o -iname '*.keys' -o -iname '*.mobileprovision' -o -iname '*.p12' -o -iname '*.cer' \) | head -5)"
[ -z "$found" ] || { echo "Refusing to package: $found" >&2; exit 1; }
if strings -a "$APP/P4G" | grep -qE '/Users/|/Volumes/'; then
  echo "Warning: build paths in the binary:" >&2
  strings -a "$APP/P4G" | grep -E '/Users/|/Volumes/' | sort -u | head -5 >&2
fi

# 5. an ad hoc signature (no certificate, no team): the sideloading app signs it again with the entitlements
codesign -f -s - --entitlements ios/P4G.entitlements "$APP"

# 6. the IPA
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
IPA="$OUT/Persona4Golden-iOS-$VERSION-$BUILD.ipa"
rm -f "$IPA"
(cd "$STAGE" && zip -qry "$IPA" Payload)
echo "Wrote $IPA ($(du -h "$IPA" | cut -f1))"
