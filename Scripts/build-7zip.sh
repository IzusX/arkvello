#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEVENZIP_DIR="$ROOT_DIR/Vendor/7zip"
BRIDGE_SRC="$ROOT_DIR/Bridge/sevenzip_bridge.cpp"
OUT_LIB_DIR="$ROOT_DIR/Vendor/lib"
OUT_DYLIB="$OUT_LIB_DIR/libsevenzip.dylib"

if [[ ! -d "$SEVENZIP_DIR/CPP/7zip/Bundles/Alone2" ]]; then
  echo "Error: Vendor/7zip sources not found at $SEVENZIP_DIR" >&2
  exit 1
fi

source "$ROOT_DIR/Scripts/build-architectures.sh"
mkdir -p "$OUT_LIB_DIR"
LIB_SLICES=()
for ARCH in "${BUILD_ARCHS[@]}"; do
OUT_DYLIB="$OUT_LIB_DIR/libsevenzip_$ARCH.dylib"
if [[ "$ARCH" == "arm64" ]]; then
  MAK_FILE="cmpl_mac_arm64.mak"
  OBJ_SUBDIR="m_arm64"
  ARCH_FLAG="-arch arm64"
else
  MAK_FILE="cmpl_mac_x64.mak"
  OBJ_SUBDIR="m_x64"
  ARCH_FLAG="-arch x86_64"
fi

BUNDLE_DIR="$SEVENZIP_DIR/CPP/7zip/Bundles/Alone2"
OBJ_DIR="$BUNDLE_DIR/b/$OBJ_SUBDIR"

# Ensure LF line endings on 7-Zip makefiles (macOS BSD make requirement)
find "$SEVENZIP_DIR" -name "*.mak" -exec sed -i '' $'s/\r$//' {} +

NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "[1/3] Compiling 7-Zip 26.06 core & codecs ($ARCH)..."
(
  cd "$BUNDLE_DIR"
  make -j"$NCPU" -f "../../$MAK_FILE" \
    CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" \
    MY_ARCH="-arch $ARCH -mmacosx-version-min=14.0 -isysroot $(xcrun --sdk macosx --show-sdk-path)" >/dev/null
)

mkdir -p "$OUT_LIB_DIR"
BRIDGE_OBJ="$OUT_LIB_DIR/sevenzip_bridge_$ARCH.o"

echo "[2/3] Compiling C/C++ in-process bridge..."
clang++ $ARCH_FLAG -mmacosx-version-min=14.0 \
  -O2 -std=c++17 -fPIC \
  -Wall -Wextra -Werror \
  -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
  -I"$SEVENZIP_DIR" \
  -I"$SEVENZIP_DIR/CPP" \
  -c "$BRIDGE_SRC" \
  -o "$BRIDGE_OBJ"

# Exclude CLI-only console translation units (Main.o, List.o, BenchCon.o, etc.)
CONSOLE_EXCLUDES=(
  "BenchCon.o"
  "ConsoleClose.o"
  "ExtractCallbackConsole.o"
  "HashCon.o"
  "List.o"
  "Main.o"
  "MainAr.o"
  "OpenCallbackConsole.o"
  "PercentPrinter.o"
  "UpdateCallbackConsole.o"
  "UserInputUtils.o"
)

CORE_OBJS=()
for obj in "$OBJ_DIR"/*.o; do
  base="$(basename "$obj")"
  skip=0
  for ex in "${CONSOLE_EXCLUDES[@]}"; do
    if [[ "$base" == "$ex" ]]; then
      skip=1
      break
    fi
  done
  if [[ "$skip" -eq 0 ]]; then
    CORE_OBJS+=("$obj")
  fi
done

echo "[3/3] Linking $OUT_DYLIB (${#CORE_OBJS[@]} core objects + bridge)..."
clang++ $ARCH_FLAG -mmacosx-version-min=14.0 \
  -dynamiclib \
  -install_name "@rpath/libsevenzip.dylib" \
  -Wl,-current_version,26.6 -Wl,-compatibility_version,26.0 \
  -Wl,-exported_symbol,'_sz_*' \
  "$BRIDGE_OBJ" \
  "${CORE_OBJS[@]}" \
  -lpthread -ldl \
  -o "$OUT_DYLIB"

rm -f "$BRIDGE_OBJ"
LIB_SLICES+=("$OUT_DYLIB")
done
OUT_DYLIB="$OUT_LIB_DIR/libsevenzip.dylib"
if [[ ${#LIB_SLICES[@]} -eq 1 ]]; then
  cp "${LIB_SLICES[0]}" "$OUT_DYLIB"
else
  lipo -create "${LIB_SLICES[@]}" -output "$OUT_DYLIB"
fi
for REQUIRED_ARCH in "${BUILD_ARCHS[@]}"; do
  case " $(lipo -archs "$OUT_DYLIB") " in
    *" $REQUIRED_ARCH "*) ;;
    *) echo "Missing $REQUIRED_ARCH slice in ""$OUT_DYLIB" >&2; exit 1 ;;
  esac
done
echo "Built $OUT_DYLIB ($(du -h "$OUT_DYLIB" | awk '{print $1}'))"
