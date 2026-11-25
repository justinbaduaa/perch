#!/bin/sh
# Builds build/Perch.app and build/Perch.dmg, signed with Perch's own certificate so macOS keeps Full Disk Access
# and the other grants across updates (a different signature resets them). The certificate lives outside the repo,
# in ~/.config/perch/perch.p12 or $PERCH_P12; CI writes it from a secret. Without it the build is ad-hoc signed.
set -e
cd "$(dirname "$0")"
# platform-imessage keeps only its Node bridge binaries in Git LFS; Perch doesn't need them.
GIT_LFS_SKIP_SMUDGE=1 swift build -c release
APP=build/Perch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Perch "$APP/Contents/MacOS/Perch"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"  # Icon/make.sh redraws it from Icon/Perch.svg

P12=${PERCH_P12:-$HOME/.config/perch/perch.p12}
if [ -f "$P12" ]; then
    # A throwaway keychain, so signing never asks for your login keychain. The file is the secret; macOS just
    # won't import a .p12 without a password.
    KEYCHAIN=$(mktemp -d)/perch.keychain-db
    trap 'security delete-keychain "$KEYCHAIN"' EXIT  # also takes it off the search list
    security create-keychain -p perch "$KEYCHAIN"
    # macOS 26's codesign won't find an identity in a keychain that isn't on the search list.
    security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
    security unlock-keychain -p perch "$KEYCHAIN"
    security import "$P12" -k "$KEYCHAIN" -P perch -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k perch "$KEYCHAIN" >/dev/null
    sign() { codesign --force --keychain "$KEYCHAIN" --sign Perch "$1"; }
else
    echo "No $P12: ad-hoc signing, so every build asks for permissions again." >&2
    sign() { codesign --force --sign - "$1"; }
fi
sign "$APP"

# Drag-to-Applications disk image.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f build/Perch.dmg
hdiutil create -quiet -volname Perch -srcfolder "$STAGE" -format UDZO build/Perch.dmg
rm -rf "$STAGE"
sign build/Perch.dmg
echo "$APP"
echo build/Perch.dmg
