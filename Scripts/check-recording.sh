#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Release/Teleprompter.app"
if [[ ! -d "$app" ]]; then
    echo "Build Teleprompter first: bash Scripts/build.sh"
    exit 1
fi
report_dir=$(mktemp -d /private/tmp/teleprompter-recording-check.XXXXXX)
echo "This check records about six seconds of camera and microphone into a private temporary folder."
echo "Allow macOS permission prompts to proceed. Your saved draft and settings are preserved."
open -n -W --stdout "$report_dir/report.log" --stderr "$report_dir/system.log" "$app" --args --capture-check --with-speech
cat "$report_dir/report.log"
echo "Diagnostic logs: $report_dir"
grep -q '^PASS:' "$report_dir/report.log"
