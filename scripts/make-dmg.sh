#!/bin/bash
# Packages build/Purrch.app as build/Purrch.dmg. The app is ad-hoc signed, not notarized.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R build/Purrch.app "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Purrch -srcfolder "$staging" -ov -format UDZO build/Purrch.dmg
echo "Built build/Purrch.dmg"
