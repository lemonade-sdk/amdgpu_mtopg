#!/bin/bash
# Build amdgpu_mtopg.app — the SwiftUI 2D companion to the terminal monitor.
#
# Usage: ./build.sh [--clean]
#
# Produces build/amdgpu_mtopg.app, adhoc-signed, no
# entitlements (an IOKit user-client read needs none). Launch with:
#   open build/amdgpu_mtopg.app
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/amdgpu_mtopg.app"

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf "$BUILD"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SDK="$(xcrun --sdk macosx --show-sdk-path)"

xcrun swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    -O \
    -framework SwiftUI -framework AppKit -framework IOKit -framework CoreFoundation \
    "$ROOT/Sources/GPUDriver.swift" \
    "$ROOT/Sources/GPUMetricsLayout.swift" \
    "$ROOT/Sources/LinuxDriver.swift" \
    "$ROOT/Sources/LinuxModel.swift" \
    "$ROOT/Sources/LinuxViews.swift" \
    "$ROOT/Sources/MonitorModel.swift" \
    "$ROOT/Sources/Views.swift" \
    "$ROOT/Sources/App.swift" \
    -o "$APP/Contents/MacOS/amdgpu_mtopg"

cp "$ROOT/assets/amdgpu_mtopg.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>amdgpu_mtopg</string>
    <key>CFBundleDisplayName</key>
    <string>amdgpu_mtopg</string>
    <key>CFBundleExecutable</key>
    <string>amdgpu_mtopg</string>
    <key>CFBundleIdentifier</key>
    <string>com.geramyloveless.amdgpu-mtopg</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.2</string>
    <key>CFBundleVersion</key>
    <string>207</string>
    <key>CFBundleIconFile</key>
    <string>amdgpu_mtopg</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"

echo "built $APP"
echo "launch: open '$APP'"
