# Release procedure

Source publication, a local testing build, and a distributable app are separate deliverables. `Scripts/build.sh` produces a local Release configuration. CI uses ad-hoc signing and never publishes a GitHub Release. Public binary distribution requires a Developer ID Application certificate, notarization, and the hardware acceptance checks in [VALIDATION.md](../VALIDATION.md).

## Prerequisites

- Use an Apple silicon Mac with macOS 26+ and Xcode 26.6. CI pins the same Xcode version on the [macOS 26 ARM64 runner](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
- Complete and record all production acceptance gates for the exact release revision. Keep private recordings and detailed device logs outside the repository.
- Install the Developer ID Application certificate and its private key in the release operator's Keychain. Apple Development and ad-hoc identities are only for local testing.
- Store notarization credentials with `xcrun notarytool store-credentials Teleprompter-Notary`, using its interactive prompts. Never put passwords, private keys, or certificates in source control. Consult [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Prepare the revision

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Config/Info.plist`.
2. Update [CHANGELOG.md](../CHANGELOG.md), the validation record, and screenshots if the interface changed.
3. Run `bash Scripts/test.sh` and `bash Scripts/build.sh`. Confirm CI passes and review the complete source diff.
4. Commit the release revision and create an annotated tag matching the version, for example `git tag -a v1.0.2 -m 'Release 1.0.2'`. The release script requires a clean checkout and a matching tag. Do not move an already published tag.

## Sign, notarize, and package

```sh
export DEVELOPER_ID_IDENTITY='Developer ID Application: Your Name (YOUR_TEAM_ID)'
export DEVELOPMENT_TEAM='YOUR_TEAM_ID'
export NOTARY_KEYCHAIN_PROFILE='Teleprompter-Notary'
bash Scripts/release.sh
```

The script reruns tests, creates a fresh Xcode archive, verifies the Developer ID signature and hardened runtime, submits a temporary ZIP to Apple's notary service, requires an Accepted result, staples and validates the ticket, and checks Gatekeeper. Only then does it create versioned files under `build/Distribution/<version>-<build>/publish/`, including SHA-256 checksums and the source revision. An existing version directory is never overwritten. Failed work stays in a staging directory for diagnosis; it is not a release artifact.

For a rejected or timed-out submission, inspect `notarization.plist` and use its submission ID with `xcrun notarytool info` or `log`. Keep those diagnostics private. A timeout does not establish rejection or acceptance.

## Verify and publish

1. Extract the final ZIP into a new folder and run `shasum -a 256 -c SHA256SUMS` from its publication directory. Verify the extracted app with `codesign --verify --deep --strict`, `xcrun stapler validate`, and `spctl --assess --type execute`.
2. Download and install the candidate on a separate Mac or clean user account. Confirm Gatekeeper, first-run permissions, sandbox folder access, camera preview, speech assets, a recorded take, and upgrade preservation of drafts/settings.
3. Push the reviewed commit and annotated tag. Create a draft GitHub Release for that tag and attach **only** the files in `publish/`. Never upload the Xcode archive, temporary submission ZIP, local testing ZIP, certificates, recordings, or raw diagnostic logs.
4. Check release notes, requirements, checksums, installation instructions, and outstanding limitations before publishing the release. Keep the preceding tested release available for rollback; publish fixes with a new version and build number.

No notarized public binary has been validated yet. The current hardware acceptance gaps are listed in [VALIDATION.md](../VALIDATION.md).
