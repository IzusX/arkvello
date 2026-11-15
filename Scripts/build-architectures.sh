#!/usr/bin/env bash
# Shared by build scripts; ARCHS accepts one or both supported architectures.
ARCHS="${ARCHS:-${ARCH:-$(uname -m)}}"
BUILD_ARCHS=()
for build_arch in $ARCHS; do
  case "$build_arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $build_arch" >&2; exit 1 ;;
  esac
  for existing_arch in "${BUILD_ARCHS[@]+${BUILD_ARCHS[@]}}"; do
    [[ "$existing_arch" != "$build_arch" ]] || { echo "Duplicate architecture: $build_arch" >&2; exit 1; }
  done
  BUILD_ARCHS+=("$build_arch")
done
[[ ${#BUILD_ARCHS[@]} -gt 0 ]] || { echo 'ARCHS must not be empty' >&2; exit 1; }
export APP_VERSION="${APP_VERSION:-0.1.0}"
export BUILD_NUMBER="${BUILD_NUMBER:-2606}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'APP_VERSION must be X.Y.Z' >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be numeric' >&2; exit 1; }
