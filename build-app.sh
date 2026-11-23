#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
archive="${1:?Pass the official Xray-macos-arm64-v8a.zip archive}"
app="${2:?Pass the path for the new .app bundle}"
checksum="0a05dca3bd311b0bc5a89c7ce56350cab1e829e131e4b2bcd48eb304fac07e9a"

if [[ -e "$app" ]]; then
    echo "Choose a new bundle path or move the previous build first." >&2
    exit 1
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
mkdir -p "$project/build/module-cache" "$(dirname "$app")"
stage="$(mktemp -d "$(dirname "$app")/.codex-proxy-build.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
bundle="$stage/$(basename "$app")"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

/usr/bin/unzip -p "$archive" xray > "$bundle/Contents/MacOS/xray"
/usr/bin/unzip -p "$archive" LICENSE > "$bundle/Contents/Resources/Xray-LICENSE.txt"
chmod 755 "$bundle/Contents/MacOS/xray"
printf '%s\n' 'Xray-core v26.10.31' \
    'https://github.com/XTLS/Xray-core/tree/v26.10.31' > "$bundle/Contents/Resources/Xray-SOURCE.txt"
cp "$project/Info.plist" "$bundle/Contents/Info.plist"
/usr/bin/xcrun swiftc -module-cache-path "$project/build/module-cache" \
    -o "$stage/generate-icon" "$project/Resources/GenerateAppIcon.swift"
"$stage/generate-icon" "$stage/AppIcon.iconset"
/usr/bin/iconutil -c icns -o "$bundle/Contents/Resources/AppIcon.icns" "$stage/AppIcon.iconset"
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -O -warnings-as-errors \
    -target arm64-apple-macos14.0 -module-cache-path "$project/build/module-cache" \
    -o "$bundle/Contents/MacOS/RouteFork" "$project"/Sources/*.swift
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$bundle/Contents/MacOS/xray"
/usr/bin/codesign --force --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
mv "$bundle" "$app"
