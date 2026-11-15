#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${SEVENZIP_SOURCE_ROOT:-$ROOT_DIR}"
OUTPUT="${1:-$ROOT_DIR/dist/Arkvello.app/Contents/PlugIns/ArkvelloQuickLook.appex}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
source "$ROOT_DIR/Scripts/build-architectures.sh"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DYLIB="$SOURCE_ROOT/Vendor/lib/libsevenzip.dylib"
[[ -f "$DYLIB" ]] || { echo "Missing $DYLIB; build the engine first." >&2; exit 1; }
for REQUIRED_ARCH in "${BUILD_ARCHS[@]}"; do
  case " $(lipo -archs "$DYLIB") " in
    *" $REQUIRED_ARCH "*) ;;
    *) echo "Missing $REQUIRED_ARCH slice in ""$DYLIB" >&2; exit 1 ;;
  esac
done
mkdir -p "$ROOT_DIR/.tmp/quicklook-modcache" "$OUTPUT/Contents/MacOS"
cp "$ROOT_DIR/Extensions/ArkvelloQuickLook/Info.plist" "$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$OUTPUT/Contents/Info.plist"
SLICES=()
for ARCH in "${BUILD_ARCHS[@]}"; do
  SLICE="$ROOT_DIR/.tmp/ArkvelloQuickLook-$ARCH"
  xcrun --sdk macosx swiftc \
    -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -swift-version 5 \
    -O -application-extension -parse-as-library -module-name ArkvelloQuickLook \
    -module-cache-path "$ROOT_DIR/.tmp/quicklook-modcache" \
    -I "$SOURCE_ROOT/Sources/CSevenZip/include" \
    -L "$SOURCE_ROOT/Vendor/lib" -lsevenzip \
    -framework Foundation -framework QuickLookUI -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -Xlinker -rpath -Xlinker '@executable_path/../../../../Frameworks' \
    "$ROOT_DIR/Extensions/ArkvelloQuickLook/PreviewProvider.swift" \
    "$ROOT_DIR/Extensions/ArkvelloQuickLook/ArchiveListing.swift" -o "$SLICE"
  SLICES+=("$SLICE")
done
BINARY="$OUTPUT/Contents/MacOS/ArkvelloQuickLook"
if [[ ${#SLICES[@]} -eq 1 ]]; then
  cp "${SLICES[0]}" "$BINARY"
else
  lipo -create "${SLICES[@]}" -output "$BINARY"
fi
for REQUIRED_ARCH in "${BUILD_ARCHS[@]}"; do
  case " $(lipo -archs "$BINARY") " in
    *" $REQUIRED_ARCH "*) ;;
    *) echo "Missing $REQUIRED_ARCH slice in ""$BINARY" >&2; exit 1 ;;
  esac
done
plutil -lint "$OUTPUT/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ROOT_DIR/Extensions/ArkvelloQuickLook/ArkvelloQuickLook.entitlements" "$OUTPUT"
codesign --verify --strict "$OUTPUT"
echo "Built and signed: $OUTPUT"
echo 'Finder registration must be verified separately; ad-hoc signing does not guarantee activation.'
