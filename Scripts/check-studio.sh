#!/bin/bash
# Render Studio fixtures and verify editing/preview identity. Never starts camera or microphone capture.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Release/Teleprompter.app"
[[ -d "$app" ]] || { echo "Run bash Scripts/build.sh first." >&2; exit 2; }
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
logs=$(mktemp -d /private/tmp/teleprompter-studio.XXXXXX)
output="$HOME/Library/Containers/$bundle_id/Data/tmp/$(basename "$logs")"
open -n -W --stdout "$logs/result.log" --stderr "$logs/system.log" "$app" --args --snapshot "$output" --studio-matrix "$@"
cat "$logs/result.log"
# Copy even failed fixtures to help diagnose a layout regression.
mkdir -p build/studio-check
[[ ! -d "$output" ]] || ditto "$output" build/studio-check
cp "$logs/result.log" "$logs/system.log" build/studio-check/
grep -q '^PASS: Studio appearance' "$logs/result.log"
rm -rf "$output"
echo "Studio renders and diagnostics: build/studio-check/"
