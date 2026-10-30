#!/bin/zsh
# Builds SlopCaffeinate.app. With --install, also copies it to ~/Applications and launches it.
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
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/SlopCaffeinate" Sources/main.swift
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x SlopCaffeinate || true
    rm -rf ~/Applications/SlopCaffeinate.app
    mkdir -p ~/Applications
    cp -R "$APP" ~/Applications/
    open ~/Applications/SlopCaffeinate.app
    echo "Installed ~/Applications/SlopCaffeinate.app"
fi
