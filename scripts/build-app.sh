#!/bin/bash
# Builds build/Purrch.app with SwiftPM, so only the Command Line Tools are required.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

app=build/Purrch.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Purrch" "$app/Contents/MacOS/Purrch"
cp -R Resources/widgets "$app/Contents/Resources/widgets"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

echo "Built $app"
