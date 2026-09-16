#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Ties.xcodeproj -scheme Ties -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build | tail -5
APP=build/DerivedData/Build/Products/Release/Ties.app
rm -rf build/dmg && mkdir -p build/dmg && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -volname Ties -srcfolder build/dmg -ov -format UDZO build/Ties.dmg
echo "built build/Ties.dmg"
