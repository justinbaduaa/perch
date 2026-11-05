#!/bin/sh
# Builds build/Perch.app. Signs with your first Apple Development identity so macOS keeps
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
echo "$APP"
