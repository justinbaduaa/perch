#!/bin/sh
# Builds build/Perch.app and build/Perch.dmg. Signs with your first Apple Development identity so macOS keeps
# Full Disk Access and Automation grants across rebuilds (ad-hoc signing resets them).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Perch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Perch "$APP/Contents/MacOS/Perch"
cp Info.plist "$APP/Contents/Info.plist"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
codesign --force --sign "${IDENTITY:--}" "$APP"

# Drag-to-Applications disk image.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f build/Perch.dmg
hdiutil create -quiet -volname Perch -srcfolder "$STAGE" -format UDZO build/Perch.dmg
rm -rf "$STAGE"
codesign --force --sign "${IDENTITY:--}" build/Perch.dmg
echo "$APP"
echo build/Perch.dmg
