#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/ModuleCache" \
  -mmacosx-version-min=26.0 -framework AVFoundation -framework Foundation -framework CoreMedia \
  -I Sources/CaptureDeviceBridge/include Sources/CaptureDeviceBridge/CaptureDeviceBridge.m \
  Tools/CameraConfigurationProbe/main.m -o build/CameraConfigurationProbe
build/CameraConfigurationProbe
