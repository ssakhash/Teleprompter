#!/bin/bash
# Render the application's fixture views without accessing a camera or microphone.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Release/Teleprompter.app"
[[ -d "$app" ]] || { echo "Run bash Scripts/build.sh first." >&2; exit 2; }
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
logs=$(mktemp -d /private/tmp/teleprompter-screenshots.XXXXXX)
output="$HOME/Library/Containers/$bundle_id/Data/tmp/$(basename "$logs").png"
open -n -W --stdout "$logs/result.log" --stderr "$logs/system.log" "$app" --args --snapshot "$output"
cat "$logs/result.log"
grep -q '^PASS:' "$logs/result.log"
mkdir -p docs/images
cp "$output" docs/images/studio.png
cp "$output.prompter.png" docs/images/prompter.png
rm -f "$output" "$output.prompter.png" "$output.prompter-later.png"
echo "Screenshots: docs/images/; render diagnostics: $logs"
