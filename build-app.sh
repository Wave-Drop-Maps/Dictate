#!/bin/zsh
# Builds SpeakFn.app and installs it to /Applications
set -e
cd "${0:A:h}"
swift build -c release --product SpeakFn
APP=build/SpeakFn.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpeakFn "$APP/Contents/MacOS/SpeakFn"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/SpeakFn.icns "$APP/Contents/Resources/SpeakFn.icns"
cp sounds/*.wav "$APP/Contents/Resources/"
for b in .build/release/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
# Ad-hoc signature with a stable identity so macOS permissions survive updates
codesign --force --deep --sign - --identifier local.dictate -r='designated => identifier "local.dictate"' "$APP"
rm -rf /Applications/SpeakFn.app
cp -R "$APP" /Applications/
touch /Applications/SpeakFn.app   # refresh Finder's icon cache
echo "Installed /Applications/SpeakFn.app"
