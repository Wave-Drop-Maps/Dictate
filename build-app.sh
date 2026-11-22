#!/bin/zsh
# Builds Dictate.app and installs it to /Applications
set -e
cd "${0:A:h}"
swift build -c release --product Dictate
APP=build/Dictate.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dictate "$APP/Contents/MacOS/Dictate"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/Dictate.icns "$APP/Contents/Resources/Dictate.icns"
cp sounds/*.wav "$APP/Contents/Resources/"
for b in .build/release/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
# Ad-hoc signature with a stable identity so macOS permissions survive updates
codesign --force --deep --sign - --identifier local.dictate -r='designated => identifier "local.dictate"' "$APP"
rm -rf /Applications/Dictate.app
cp -R "$APP" /Applications/
touch /Applications/Dictate.app   # refresh Finder's icon cache
echo "Installed /Applications/Dictate.app"
