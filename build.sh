#!/bin/bash
# Builds "build/Cablebay.app" (universal: Apple Silicon + Intel, ad-hoc signed).
#   ./build.sh            build the app
#   ./build.sh --install  also copy it to /Applications and launch it
#   ./build.sh --dmg      also make dist/Cablebay-<version>.dmg (drag-to-Applications installer)
set -euo pipefail
cd "$(dirname "$0")"

NAME="Cablebay"
APP="build/$NAME.app"
SDK="$(xcrun --show-sdk-path)"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  xcrun swiftc -O -target "$ARCH-apple-macos14.2" -sdk "$SDK" Sources/*.swift -o "build/obj/$NAME-$ARCH"
done
lipo -create "build/obj/$NAME-arm64" "build/obj/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Mixer Stream virtual audio driver
DRV="$APP/Contents/Resources/MixerStream.driver"
mkdir -p "$DRV/Contents/MacOS"
xcrun clang -O2 -Wall -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.2 \
  Driver/MixerStream.c -framework CoreFoundation -framework CoreAudio \
  -o "$DRV/Contents/MacOS/MixerStream"
cp Driver/Info.plist "$DRV/Contents/Info.plist"
codesign --force --sign - "$DRV"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$NAME"))"

if [[ "${1:-}" == "--install" ]]; then
  # Quit the running copy (and Volume Mixer, the app's old name) and wait for it to exit.
  pkill -x "$NAME" 2>/dev/null || true
  pkill -x VolumeMixer 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -x "$NAME" >/dev/null || pgrep -x VolumeMixer >/dev/null || break
    sleep 0.1
  done
  rm -rf "/Applications/$NAME.app" "/Applications/Volume Mixer.app"
  cp -R "$APP" /Applications/
  open "/Applications/$NAME.app"
  echo "Installed to /Applications"
fi

if [[ "${1:-}" == "--dmg" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
  STAGE="build/dmg"
  rm -rf "$STAGE" && mkdir -p "$STAGE" dist
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "Installer/Read Me First.txt" "$STAGE/"
  DMG="dist/$NAME-$VERSION.dmg"
  rm -f "$DMG"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  echo "Made $DMG"
fi
