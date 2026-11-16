#!/bin/sh
# Rebuilds AppIcon.icns from Perch.svg. build.sh copies the .icns into the app.
set -e
cd "$(dirname "$0")"
rm -rf AppIcon.iconset
swift render.swift Perch.svg AppIcon.iconset
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
