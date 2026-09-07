#!/bin/bash
# Build and notarize a tagged revision. Credentials remain in the macOS Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: DEVELOPER_ID_IDENTITY='Developer ID Application: …' DEVELOPMENT_TEAM=… NOTARY_KEYCHAIN_PROFILE=… bash Scripts/release.sh"
    echo "Requires a clean checkout tagged v<app version>. See docs/RELEASING.md."
    exit 0
fi
[[ $# -eq 0 ]] || { echo "Unexpected arguments. Use --help." >&2; exit 2; }
: "${DEVELOPER_ID_IDENTITY:?Set the Developer ID Application identity name.}"
: "${DEVELOPMENT_TEAM:?Set the Apple Developer team ID.}"
: "${NOTARY_KEYCHAIN_PROFILE:?Set an existing notarytool Keychain profile.}"
[[ "$DEVELOPER_ID_IDENTITY" == "Developer ID Application: "* ]] || {
    echo "Public releases require a Developer ID Application certificate." >&2; exit 2;
}
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or remove local source changes before releasing." >&2; exit 2; }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Config/Info.plist)
build_number=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Config/Info.plist)
[[ "$(git rev-parse "v$version^{commit}")" == "$(git rev-parse HEAD)" ]] || {
    echo "HEAD must match the v$version release tag." >&2; exit 2;
}
destination="$PWD/build/Distribution/$version-$build_number"
[[ ! -e "$destination" ]] || { echo "Release output already exists: $destination" >&2; exit 2; }

bash Scripts/test.sh
mkdir -p build/Distribution
staging=$(mktemp -d "$PWD/build/Distribution/staging.XXXXXX")
# Retain failed notarization logs and archives for diagnosis; never publish them.
trap 'echo "Unpublished release work: $staging" >&2' ERR
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
xcodebuild -project Teleprompter.xcodeproj -scheme Teleprompter -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/DistributionDerivedData \
    -archivePath "$staging/Teleprompter.xcarchive" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp archive

app="$staging/Teleprompter.xcarchive/Products/Applications/Teleprompter.app"
codesign --verify --deep --strict "$app"
codesign -d --verbose=4 "$app" 2> "$staging/signature.txt"
grep -q '^Authority=Developer ID Application:' "$staging/signature.txt"
grep -q "^TeamIdentifier=$DEVELOPMENT_TEAM$" "$staging/signature.txt"
grep -q 'flags=.*runtime' "$staging/signature.txt"
grep -q '^Timestamp=' "$staging/signature.txt"
codesign -d --entitlements :- "$app" > "$staging/entitlements.plist" 2>/dev/null
if /usr/libexec/PlistBuddy -c 'Print com.apple.security.get-task-allow' "$staging/entitlements.plist" 2>/dev/null | grep -q true; then
    echo "A distribution build must not allow debugger attachment." >&2; exit 2
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/notarization-upload.zip"
xcrun notarytool submit "$staging/notarization-upload.zip" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait --timeout 20m \
    --output-format plist > "$staging/notarization.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print status' "$staging/notarization.plist")" == Accepted ]] || {
    echo "Notarization was not accepted; inspect $staging/notarization.plist." >&2; exit 1;
}
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

mkdir "$staging/publish"
archive="Teleprompter-$version-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/publish/$archive"
git rev-parse HEAD > "$staging/publish/source-revision.txt"
xcodebuild -version > "$staging/publish/toolchain.txt"
(
    cd "$staging/publish"
    shasum -a 256 "$archive" source-revision.txt toolchain.txt > SHA256SUMS
)
mv "$staging" "$destination"
trap - ERR
echo "Verified distribution files: $destination/publish"
echo "Complete the clean-machine installation check in docs/RELEASING.md before uploading."
