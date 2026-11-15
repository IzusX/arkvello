#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source root can differ from the staged script root during isolated verification.
SOURCE_ROOT="${SEVENZIP_SOURCE_ROOT:-$ROOT_DIR}"
OUTPUT="${1:-$ROOT_DIR/dist/7-Zip.app/Contents/PlugIns/SevenZipQuickLook.appex}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="${ARCH:-$(uname -m)}"
DYLIB="$SOURCE_ROOT/Vendor/lib/libsevenzip.dylib"
[[ -f "$DYLIB" ]] || { echo "Missing $DYLIB; run Scripts/build-7zip.sh first." >&2; exit 1; }
mkdir -p "$ROOT_DIR/.tmp/quicklook-modcache" "$OUTPUT/Contents/MacOS"
cp "$ROOT_DIR/Extensions/SevenZipQuickLook/Info.plist" "$OUTPUT/Contents/Info.plist"
# The extension executable resides at Contents/PlugIns/*.appex/Contents/MacOS.
# Four parent traversals reach the host's Contents; never link to a build-machine path.
xcrun --sdk macosx swiftc \
    -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -swift-version 5 \
    -O -application-extension -parse-as-library -module-name SevenZipQuickLook \
    -module-cache-path "$ROOT_DIR/.tmp/quicklook-modcache" \
    -I "$SOURCE_ROOT/Sources/CSevenZip/include" \
    -L "$SOURCE_ROOT/Vendor/lib" -lsevenzip \
    -framework Foundation -framework QuickLookUI -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -rpath -Xlinker '@executable_path/../../../../Frameworks' \
    "$ROOT_DIR/Extensions/SevenZipQuickLook/PreviewProvider.swift" \
    -o "$OUTPUT/Contents/MacOS/SevenZipQuickLook"
plutil -lint "$OUTPUT/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT_DIR/Extensions/SevenZipQuickLook/SevenZipQuickLook.entitlements" \
    "$OUTPUT"
codesign --verify --strict "$OUTPUT"
echo "Built and signed: $OUTPUT"
echo "Finder registration/activation must be verified separately; an ad-hoc signature alone does not establish availability."
