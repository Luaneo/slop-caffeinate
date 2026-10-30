#!/bin/zsh
# Builds SlopCaffeinate.app. With --install, also copies it to /Applications and launches it.
set -euo pipefail
cd "${0:A:h}"

APP=build/SlopCaffeinate.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.luaneo.SlopCaffeinate</string>
    <key>CFBundleName</key><string>SlopCaffeinate</string>
    <key>CFBundleExecutable</key><string>SlopCaffeinate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Universal binary. Without an explicit -target, swiftc would require the macOS version of the build machine.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -o "build/SlopCaffeinate-$arch" Sources/main.swift
done
lipo -create build/SlopCaffeinate-arm64 build/SlopCaffeinate-x86_64 -output "$APP/Contents/MacOS/SlopCaffeinate"
rm build/SlopCaffeinate-arm64 build/SlopCaffeinate-x86_64
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x SlopCaffeinate || true
    rm -rf /Applications/SlopCaffeinate.app
    cp -R "$APP" /Applications/
    open /Applications/SlopCaffeinate.app
    echo "Installed /Applications/SlopCaffeinate.app"
fi
