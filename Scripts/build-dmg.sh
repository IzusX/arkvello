#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VERSION="${APP_VERSION:-}"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Set APP_VERSION to stable MAJOR.MINOR.PATCH (without v)." >&2
  exit 1
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "DMG packaging requires macOS." >&2
  exit 1
fi
APP="$ROOT_DIR/dist/Arkvello.app"
DIST="$ROOT_DIR/dist"
DMG="$DIST/Arkvello-$VERSION-universal.dmg"
if [[ ! -d "$APP" ]]; then
  echo "Build dist/Arkvello.app with ARCHS='arm64 x86_64' first." >&2
  exit 1
fi
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
  echo "App version $BUNDLE_VERSION does not match APP_VERSION=$VERSION." >&2
  exit 1
fi
for BINARY in "$APP/Contents/MacOS/Arkvello" \
  "$APP/Contents/Frameworks/libsevenzip.dylib" \
  "$APP/Contents/PlugIns/ArkvelloQuickLook.appex/Contents/MacOS/ArkvelloQuickLook"; do
  for REQUIRED_ARCH in arm64 x86_64; do
    case " $(lipo -archs "$BINARY") " in
      *" $REQUIRED_ARCH "*) ;;
      *) echo "Missing $REQUIRED_ARCH slice in $BINARY" >&2; exit 1 ;;
    esac
  done
done
codesign --verify --deep --strict "$APP"

# Local packaging permits a dirty tree. Public releases must also run the
# source-archive verification in .github/workflows/release.yml.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/arkvello-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$DIST" "$STAGE/volume/Licenses"
ditto "$APP" "$STAGE/volume/Arkvello.app"
ln -s /Applications "$STAGE/volume/Applications"
cp THIRD_PARTY_LICENSES.md "$STAGE/volume/Licenses/"
cp LICENSE "$STAGE/volume/Licenses/Arkvello-MIT.txt"
cp Vendor/7zip/DOC/License.txt Vendor/7zip/DOC/copying.txt \
  Vendor/7zip/DOC/unRarLicense.txt "$STAGE/volume/Licenses/"
cp docs/DISTRIBUTION.md "$STAGE/volume/DISTRIBUTION.md"
cat > "$STAGE/volume/SOURCE-AVAILABILITY.txt" <<EOF
Arkvello $VERSION

The same release includes Arkvello-$VERSION-source.tar.gz: the entire versioned
project source, including Vendor/7zip, Bridge, build scripts, and license texts.
Download it beside this DMG on the release page, and consult DISTRIBUTION.md
for rebuilding/replacing the dynamically linked LGPL library.

This app is ad-hoc signed, not Developer ID signed or Apple notarized.
EOF
hdiutil create -volname "Arkvello $VERSION" -srcfolder "$STAGE/volume" \
  -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS)
printf 'Created:\n%s\n%s\n' "$DMG" "$DIST/SHA256SUMS"
echo 'Public distribution also requires the matching source archive; see docs/DISTRIBUTION.md.'
