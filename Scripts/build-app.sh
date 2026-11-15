#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="7-Zip"
EXEC_NAME="SevenZipMac"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DYLIB_PATH="$ROOT_DIR/Vendor/lib/libsevenzip.dylib"

if [[ ! -f "$DYLIB_PATH" ]]; then
  "$ROOT_DIR/Scripts/build-7zip.sh"
fi

echo "[1/4] Building release binary ($EXEC_NAME)..."
mkdir -p "$ROOT_DIR/.tmp" "$ROOT_DIR/.modcache" "$ROOT_DIR/.cache" "$ROOT_DIR/.scratch"
TMPDIR="$ROOT_DIR/.tmp" \
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.modcache" \
swift build -c release \
  --disable-sandbox \
  --cache-path "$ROOT_DIR/.cache" \
  --scratch-path "$ROOT_DIR/.scratch"

BIN_DIR="$(TMPDIR="$ROOT_DIR/.tmp" CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.modcache" swift build -c release --show-bin-path --disable-sandbox --cache-path "$ROOT_DIR/.cache" --scratch-path "$ROOT_DIR/.scratch")"
BIN_PATH="$BIN_DIR/$EXEC_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Error: compiled binary $EXEC_NAME not found at $BIN_PATH" >&2
  exit 1
fi

echo "[2/4] Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp "$DYLIB_PATH" "$APP_BUNDLE/Contents/Frameworks/libsevenzip.dylib"
cp "$ROOT_DIR/THIRD_PARTY_LICENSES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_LICENSES.md"

# Remove build-machine absolute rpath so bundle is portable across Macs
install_name_tool -delete_rpath "$ROOT_DIR/Vendor/lib" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true

echo "[3/4] Generating app icon and Info.plist..."
ICONSET_DIR="$ROOT_DIR/.tmp/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

TMPDIR="$ROOT_DIR/.tmp" swift -module-cache-path "$ROOT_DIR/.modcache" - "$ICONSET_DIR" <<'SWIFT_ICON'
import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225

    // Dark graphite squircle base
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        CGColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1.0),
        CGColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1.0)
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: s * 0.5, y: s), end: CGPoint(x: s * 0.5, y: 0), options: [])

    // Vertical zipper track on right third
    let zipperX = s * 0.72
    let toothW = max(2.0, s * 0.055)
    let toothH = max(1.5, s * 0.032)
    let step = s * 0.062
    for idx in 0..<11 {
        let y = rect.minY + s * 0.14 + CGFloat(idx) * step
        let offset = (idx % 2 == 0) ? -toothW * 0.45 : toothW * 0.05
        let tRect = CGRect(x: zipperX + offset, y: y, width: toothW, height: toothH)
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.68, blue: 0.20, alpha: 0.92))
        ctx.fill(tRect.insetBy(dx: 0, dy: 0))
    }

    // Bold "7z" mark on left
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.34, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    let str = NSAttributedString(string: "7z", attributes: attrs)
    let strSize = str.size()
    str.draw(at: NSPoint(x: rect.minX + s * 0.11, y: (s - strSize.height) * 0.5))

    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: outDir.appendingPathComponent(filename))
    }
}
SWIFT_ICON

iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleDisplayName</key>
    <string>7-Zip</string>
    <key>CFBundleExecutable</key>
    <string>SevenZipMac</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.izusx.sevenzipmac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>7-Zip</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>2606</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Archive</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>7z</string>
                <string>zip</string>
                <string>zipx</string>
                <string>rar</string>
                <string>tar</string>
                <string>tgz</string>
                <string>tbz2</string>
                <string>txz</string>
                <string>tzst</string>
                <string>gz</string>
                <string>bz2</string>
                <string>xz</string>
                <string>zst</string>
                <string>cab</string>
                <string>iso</string>
                <string>dmg</string>
                <string>wim</string>
                <string>xar</string>
                <string>pkg</string>
                <string>rpm</string>
                <string>deb</string>
                <string>cpio</string>
                <string>001</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Declare imported archive UTIs and services without changing any default handlers.
TMPDIR="$ROOT_DIR/.tmp" swift -module-cache-path "$ROOT_DIR/.modcache" - \
  "$ROOT_DIR/Resources/FinderIntegration.json" "$APP_BUNDLE/Contents/Info.plist" <<'SWIFT_PLIST'
import Foundation
let configurationURL = URL(fileURLWithPath: CommandLine.arguments[1])
let plistURL = URL(fileURLWithPath: CommandLine.arguments[2])
let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: configurationURL)) as! [String: Any]
var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
let archiveTypes = configuration["archiveTypes"] as! [[Any]]
let identifiers = archiveTypes.map { $0[0] as! String }
plist["UTImportedTypeDeclarations"] = archiveTypes.map { item -> [String: Any] in
    let identifier = item[0] as! String
    let diskImage = identifier == "public.iso-image" || identifier == "com.apple.disk-image-udif"
    return ["UTTypeIdentifier": identifier, "UTTypeDescription": item[1],
            "UTTypeConformsTo": [diskImage ? "public.disk-image" : "public.archive"],
            "UTTypeTagSpecification": ["public.filename-extension": item[2], "public.mime-type": item[3]]]
}
plist["CFBundleDocumentTypes"] = [["CFBundleTypeName": "Archive", "CFBundleTypeRole": "Editor",
    "LSHandlerRank": "Alternate", "LSItemContentTypes": identifiers]]
plist["NSServices"] = (configuration["services"] as! [[String]]).map { service -> [String: Any] in
    ["NSMessage": service[0], "NSMenuItem": ["default": service[1]], "NSPortName": "SevenZipMac",
     "NSSendTypes": ["public.file-url"],
     "NSRequiredContext": ["NSApplicationIdentifier": "com.apple.finder"], "NSTimeout": "120000"]
}
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
SWIFT_PLIST
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

echo "[4/4] Building Quick Look extension and signing inside out..."
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/libsevenzip.dylib"
bash "$ROOT_DIR/Scripts/build-quicklook.sh" "$APP_BUNDLE/Contents/PlugIns/SevenZipQuickLook.appex"
codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "Ready: $APP_BUNDLE ($(du -sh "$APP_BUNDLE" | awk '{print $1}'))"
