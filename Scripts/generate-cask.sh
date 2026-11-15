#!/usr/bin/env bash
set -euo pipefail

# No remote is assumed: always require an explicit GitHub repository.
if [[ $# -ne 3 ]]; then
  echo "Usage: bash Scripts/generate-cask.sh VERSION OWNER/REPO PATH_TO_DMG" >&2
  exit 1
fi
VERSION="$1"
REPOSITORY="$2"
DMG="$3"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Version must be stable MAJOR.MINOR.PATCH without a v prefix." >&2
  exit 1
fi
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "Repository must be an explicit GitHub OWNER/REPO." >&2
  exit 1
fi
if [[ ! -f "$DMG" || "$(basename "$DMG")" != "Arkvello-$VERSION-universal.dmg" ]]; then
  echo "Expected an existing Arkvello-$VERSION-universal.dmg." >&2
  exit 1
fi
CHECKSUM="$(shasum -a 256 "$DMG" | awk '{print $1}')"
cat <<EOF
cask "arkvello" do
  version "$VERSION"
  sha256 "$CHECKSUM"

  url "https://github.com/$REPOSITORY/releases/download/v#{version}/Arkvello-#{version}-universal.dmg"
  name "Arkvello"
  desc "Native archive manager powered by 7-Zip"
  homepage "https://github.com/$REPOSITORY"

  depends_on macos: :sonoma

  app "Arkvello.app"

  caveats <<~EOS
    Arkvello is ad-hoc signed, without Developer ID or Apple notarization.
    If macOS blocks it, try opening it once, then use System Settings >
    Privacy & Security > Open Anyway, if you trust this release.
    See https://support.apple.com/en-us/102445
  EOS
end
EOF
