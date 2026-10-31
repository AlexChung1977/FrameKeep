#!/bin/sh
# Build a Release app and wrap it in an installable .pkg.
# The package installs Framekeep.app into /Applications.
# The app is signed with the local "Framekeep Local Codesign" identity.
# This is not an Apple Developer ID or notarized package, so other Macs
# will refuse it until it is re-signed with a Developer ID.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
ARCHIVE="$DIST/Framekeep.xcarchive"
APP="$ARCHIVE/Products/Applications/Framekeep.app"

mkdir -p "$DIST"
rm -rf "$ARCHIVE"

xcodebuild \
  -scheme Framekeep \
  -configuration Release \
  -destination "platform=macOS" \
  -archivePath "$ARCHIVE" \
  archive

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PKG="$DIST/Framekeep-$VERSION.pkg"
STAGE="$DIST/stage"
rm -rf "$STAGE" "$PKG"
mkdir -p "$STAGE"

# Copy without resource forks or AppleDouble sidecars, then confirm the
# local signature still verifies.
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/Framekeep.app"
if ! codesign --verify --verbose=2 "$STAGE/Framekeep.app"; then
  echo "error: copied app failed signature verification" >&2
  exit 1
fi

# provenance xattrs otherwise become AppleDouble files inside the package.
export COPYFILE_DISABLE=1

pkgbuild \
  --component "$STAGE/Framekeep.app" \
  --install-location /Applications \
  --identifier app.framekeep.Framekeep \
  --version "$VERSION" \
  "$PKG"

# pkgbuild records AppleDouble names for provenance xattrs, then fails to
# write those files. Drop them from the bill of materials so Installer does
# not look for missing payload entries.
EXPAND="$DIST/expanded-pkg"
BOM_LIST="$DIST/bom.txt"
rm -rf "$EXPAND"
pkgutil --expand "$PKG" "$EXPAND"
lsbom "$EXPAND/Bom" | awk -F'\t' 'index($1, "/._") == 0' > "$BOM_LIST"
mkbom -i "$BOM_LIST" "$EXPAND/Bom"
python3 - "$EXPAND/PackageInfo" "$BOM_LIST" <<'PY'
import re
import sys
info = open(sys.argv[1], encoding="utf-8")
text = info.read()
info.close()
count = sum(1 for line in open(sys.argv[2], encoding="utf-8") if line.strip())
updated, replacements = re.subn(r'numberOfFiles="\d+"', f'numberOfFiles="{count}"', text, count=1)
if replacements != 1:
    raise SystemExit("PackageInfo is missing numberOfFiles")
open(sys.argv[1], "w", encoding="utf-8").write(updated)
PY
rm -f "$PKG"
pkgutil --flatten "$EXPAND" "$PKG"
rm -rf "$EXPAND" "$BOM_LIST"

SIGNED="$DIST/Framekeep-$VERSION-signed.pkg"
if productsign --sign "Framekeep Local Codesign" "$PKG" "$SIGNED"; then
  mv "$SIGNED" "$PKG"
else
  rm -f "$SIGNED"
  echo "note: installer package is unsigned. The app inside keeps the local signature."
fi

echo "package: $PKG"
