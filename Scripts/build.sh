#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
xcodebuild -project Teleprompter.xcodeproj -scheme Teleprompter -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages build "$@"

# Package from a fresh directory so removed resources cannot survive a rebuild.
package_dir=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$package_dir"' EXIT
ditto build/DerivedData/Build/Products/Release/Teleprompter.app "$package_dir/Teleprompter.app"
codesign --verify --deep --strict "$package_dir/Teleprompter.app"
ditto -c -k --sequesterRsrc --keepParent "$package_dir/Teleprompter.app" "$package_dir/Teleprompter-macOS.zip"
(
    cd "$package_dir"
    shasum -a 256 Teleprompter-macOS.zip > SHA256SUMS
)
mkdir -p build/Release
rm -rf build/Release/Teleprompter.app
mv "$package_dir/Teleprompter.app" build/Release/
mv "$package_dir/Teleprompter-macOS.zip" "$package_dir/SHA256SUMS" build/Release/
echo "Local Release app: $PWD/build/Release/Teleprompter.app"
echo "For public distribution, use Scripts/release.sh after completing docs/RELEASING.md."
