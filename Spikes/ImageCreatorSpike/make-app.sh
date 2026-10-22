#!/bin/bash
# Builds the spike executable and wraps it in a minimal, ad hoc signed app bundle.
# Usage: ./make-app.sh [bundle-identifier] [LSUIElement true|false]
set -euo pipefail

cd "$(dirname "$0")"
identifier="${1:-com.example.preowned.ImageCreatorSpike}"
ui_element="${2:-true}"
app="build/ImageCreatorSpike.app"

swift build -c release
binary="$(swift build -c release --show-bin-path)/ImageCreatorSpike"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/ImageCreatorSpike"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${identifier}</string>
    <key>CFBundleName</key>
    <string>ImageCreatorSpike</string>
    <key>CFBundleExecutable</key>
    <string>ImageCreatorSpike</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <${ui_element}/>
</dict>
</plist>
PLIST

if ! codesign --force --sign - "$app"; then
    echo "codesign failed" >&2
    exit 1
fi
codesign --display --verbose=2 "$app" 2>&1 | grep -E "Identifier|Signature|Format"
echo "built $app"
