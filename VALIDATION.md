# Validation record

Environment: Apple silicon, macOS 26.5.2, Xcode 26.6. Tests run on September 6, 2026.

## Automated and inspected

| Check | Result |
| --- | --- |
| Release app build | Version 1.0.2 (3) passed; Apple Development signing with App Sandbox and hardened runtime |
| Swift core/integration tests | 32 passed; alignment, source mapping, serialization, profile ranking, exact frame timing, sample readiness, stale/missing audio, changed dimensions, and preservation of first-frame errors through finalization |
| Frame-rate metadata regression | All 14 built-in and 20 Continuity Camera choices are inside their exact advertised timing ranges; the previous rounding would invalidate 7 and 8 choices respectively |
| Native camera configuration regression | Built-in camera passed all 7 advertised format/range configurations, slow/fast switching, and safe invalid-input rejection; original settings restored; no capture session started. Continuity Camera was unavailable for this separate check |
| Built-in camera recording regression | Final workflow produced a 6.35-second H.264/AAC MP4 with speech following enabled: native 1552 × 1552, selected 30 fps, measured nominal 29.84 fps, zero reported dropped frames, 0 ms start skew and 14 ms end skew; preview remained running after save |
| Bubble motion and accessibility | Fixture renders inspected; compositor rotation progressed between samples; Reduce Motion removed the continuous rotation; Reduce Transparency rendered an opaque surface |
| Synthetic MP4 | 1280 × 720, 30 fps, 3.0 seconds, H.264/AAC, 90 frames, zero dropped; A/V endpoint skew below 100 ms |
| Abrupt writer exit | Generated 12-second take, intentionally exited without finalization, recovered playable fragments through passthrough MP4 export |
| UI render inspection | Studio and floating panel rendered with fixture text; inspected layout, editor, controls, and token highlight |
| Read-only hardware discovery | Built-in camera and iPhone Continuity Camera both discovered; SpeechTranscriber available; English models installed |
| Live-style synthetic speech | Passed three consecutive runs: full 76-word English fixture tracked to the end; p95 recognition-result-end delay 0.411 seconds on the final source version |

The only Xcode build warning is skipped App Intents metadata extraction because this app has no AppIntents dependency. Restricted-shell SwiftPM cache warnings do not affect the tests; the scripts redirect build/module caches into the workspace.

The speech fixture is approximately 24 seconds of generated English audio streamed in real time. The timing figure measures result delivery relative to the end of its audio interval; it is **not** an independently annotated spoken-word or UI latency measurement. Initial integration runs exposed resampling timestamp overlaps; the speech branch now uses a contiguous output-frame clock. Three subsequent full-fixture runs passed. Human accents, improvisation, cold starts, and prolonged sessions still need the gates below.

Read-only discovery reported a maximum advertised built-in camera format of 1552 × 1552 at 30 fps, and a Continuity Camera format of 1920 × 1440 at 60 fps. The built-in format has now passed a short real recording. Continuity Camera capture and 30-minute sustained recording remain outstanding; neither device advertisements nor a short take establish endurance.

## Version 1.0.2 recording regression

Reproduced the reported failure using the real app workflow: prepare, preview, three-second countdown, record, and stop. The selected profile was 1552 × 1552, but session startup applied the default high-quality preset and changed the camera's active format to 1920 × 1080. The writer rejected the first frame; finalization then replaced that error with the misleading “No camera frames were received” message and the coordinator stopped the preview.

The selected native format now applies after session startup. The video data output explicitly requests those dimensions, then exact frame timing is pinned after output negotiation. A persistent preview layer prevents SwiftUI updates from reconnecting the session and resetting the camera's timing. Readiness checks the active camera format and frame-rate limits, three consistent delivered video frames, and recent audio before counting down and before writing. Failed writer operations preserve their original error and leave a healthy preview running. The corrected workflow completed the actual recording reported above, with both selected and delivered dimensions verified as 1552 × 1552.

The measured local build used a stable Apple Development identity. Shared project settings default to ad-hoc signing; a Git-ignored `Config/Local.xcconfig` supplies each developer's team and certificate. Changing from ad-hoc to development signing required renewed app-container, camera, and microphone grants on the test Mac. No privacy database was modified.

Evidence: `build/capture-startup-reproduction.log`, `build/capture-startup-fixed.log`, `build/recording-regression-tests.log`, `build/ui-animation-results.log`, and `build/ui-reduced-motion-results.log`. These diagnostics contain metadata and fixture text only; test recordings stay in the app's private temporary folder.

## Version 1.0.1 crash regression

The reported version 1.0.0 crash occurred in `setActiveVideoMinFrameDuration:` during camera preparation. Converting 30 fps to nanoseconds produced `33333333/1000000000`, slightly shorter than the camera's exact minimum of `1000000/30000000`. AVFoundation rejected that out-of-range value with an Objective-C exception, which Swift error handling cannot catch.

Profiles now carry the camera's exact rational frame duration through configuration. Lower frame-rate choices use exact rational values and must fall inside an advertised interval. A narrow Objective-C boundary validates the choice, applies minimum/maximum timing in a valid order, releases the device lock on every exit, and translates native exceptions into an app-visible error. Native configuration checks exercise the corrected setters but do not replace end-to-end preview or recording acceptance.

Evidence: `build/frame-rate-test-results.log`, `build/camera-configuration-results.log`, and `build/xcode-build.log`.

## Repository and packaging verification

The publication check repeated all 32 Swift tests and the synthetic three-second MP4 check successfully. A Release build with the local development certificate passed signature and ZIP checksum verification. A fresh export of only the staged repository files also built and packaged successfully using the shared ad-hoc signing defaults, without a local signing configuration or previous build products.

The studio and floating-panel screenshots were regenerated from fixture views and visually inspected. The perimeter's presentation angle advanced from 0.376 to 1.107 radians across the two-second check. Shell syntax, workflow YAML, project/property-list syntax, and local documentation links passed inspection. Private signing settings, recordings, and local diagnostics are excluded from source control.

The Developer ID/notarization script has passed syntax and preflight inspection only. A notarized distribution and clean-machine installation remain unverified and require the release prerequisites in [docs/RELEASING.md](docs/RELEASING.md).

## Version 1.0.3 compact layout — September 17, 2026

On macOS 26.6.2 with Xcode 27.0, the signed Release build, all 32 existing Swift tests, and the three-second synthetic MP4 check passed. The default panel render is 702 × 254 pixels on a 2× display, compared with the previous 1168 × 422 pixels; native window sizing rounds fractional dimensions. The reading surface is 336 points wide and the font is 16.8 points, both 60% of their prior defaults.

Fixture renders confirmed three visible reading lines, word highlighting, and perimeter animation at the compact size. A second render at the minimum 228-point reading width retained every control and the simulated recording timer; the tracking status truncates to fit. These renders use fixture text and do not start camera or microphone capture. Saved preference values retain their original units, with the 60% scale applied only for presentation and reversed when editing size controls, so relaunches do not compound the reduction.

Evidence: `build/compact-panel-build.log`, `build/compact-panel-tests.log`, and `build/compact-recording-preview.png`. No additional physical-camera or endurance acceptance is claimed for this UI change.

## Studio Bento layout — September 24, 2026

On macOS 26.6.2 with Xcode 27.0, the signed Release build and package verification passed. All 32 existing Swift tests passed, followed by a synthetic three-second H.264/AAC recording with 90 frames and zero dropped frames. The restricted-shell encoder check required access to macOS media services; it passed when run with that access.

The native Studio fixture matrix passed in Light and Dark Mode at 940 × 650, 1120 × 790, and 1440 × 1000 points, with a second run using reduced transparency and motion. Render inspection covered both ends of the dashboard scroll area, empty and long scripts, long folder and device names, draft recovery, downloads, notices, and each recording phase. The small utility cards stack at the narrow size, and long device names wrap outside the native menu title rather than truncating.

Keyboard input checks confirmed editing while idle and blocked script changes during preparation, countdown, recording, finalization, rehearsal, and speech loading. These checks exposed a focused macOS TextEditor continuing to accept input after being disabled; the Studio now releases editor focus when the script locks. Resizing and appearance changes preserve editor identity, focus, selection, draft text, preview-view identity, and the model's preview session.

The existing floating-panel fixtures also passed: its compositor orbit advanced normally and remained stationary with Reduce Motion. Floating-panel, model, persistence, and media-service source files were not changed. All new UI checks use fixture data and an idle preview session; no physical camera or microphone recording was performed for this layout change.

Evidence: `build/bento-build.log`, `build/bento-tests.log`, `build/bento-studio.log`, `build/bento-accessibility.log`, `build/studio-check-standard/`, `build/studio-check/`, and `build/panel-check/`. The paired Studio renders are published in `docs/images/studio.png` and `docs/images/studio-light.png`.

## Reproduce

```sh
bash Scripts/build.sh
bash Scripts/test.sh

# Read device metadata and model availability; does not start capture.
build/swift-package/debug/MediaProbe capabilities
build/swift-package/debug/MediaProbe frame-rates

# Exercise native camera configuration; skips cameras in use and restores settings.
# Does not start capture or record media. Continuity Camera must be available.
bash Scripts/check-camera-configuration.sh

# Explicit hardware test: records approximately six seconds of camera + microphone
# into the app's private temporary folder, with local speech following enabled.
bash Scripts/check-recording.sh

# Generated speech, streamed at real-time pace; no microphone recording.
say -v Samantha -r 160 -f Fixtures/reading-script.txt -o build/reading-fixture.aiff
build/swift-package/debug/MediaProbe speech build/reading-fixture.aiff Fixtures/reading-script.txt

# Recovery test. Exit code 93 is intentional; note the printed partial path.
build/swift-package/debug/MediaProbe crash build/recovery-check 12
build/swift-package/debug/MediaProbe recover '<printed partial path>'
build/swift-package/debug/MediaProbe inspect '<recovered MP4 path>'
```

`MediaProbe` generates color frames and an audible 440 Hz test tone. It never starts a camera or microphone. `speech` prints token positions and timing metrics; `--verbose` additionally prints the fixture's hypotheses and should only be used with nonprivate test material. Speech asset installation is managed by macOS if required.

## Outstanding production acceptance gates

These require an interactive, permission-authorized session and have **not** been claimed as passed:

1. **First run:** allow/deny camera and microphone separately; recover through System Settings; check folder selection, bookmark restoration after relaunch, and an offline launch with/without English assets.
2. **Built-in camera endurance:** record a full 30-minute spoken take at its maximum selected profile. Inspect the resulting MP4 and confirm audio/video drift <100 ms, dropped frames <1%, correct native dimensions/frame rate, and stable memory/thermal behavior.
3. **Continuity Camera endurance:** repeat the full 30-minute check with the iPhone. Confirm orientation, saved-video mirroring, device choice, and disconnected/locked-phone behavior. Device discovery alone does not verify capture.
4. **Natural speech:** read annotated scripts at 100, 140, and 180 wpm using the intended microphone and accent. Include names, numbers, technical terms, fillers, nearby sentence restarts/skips, repeated phrases, and a ten-second tangent. Target p95 delay ≤1 second, correct sentence ≥95% of voiced checkpoints, and recovery ≤2 seconds after a distinctive matching phrase. Generated voice is only an integration test.
5. **Desktop behavior:** check the panel under the physical notch, scaled resolutions, external displays, Spaces, supported full-screen apps, manual dragging, registered hotkeys while another app is active, VoiceOver navigation, and Reduce Motion.
6. **Interruption behavior:** disconnect camera/microphone, rotate the iPhone, deny destination access, exhaust a dedicated test volume, sleep/wake, quit while writing, and interrupt finalization. Verify clear completed/recovered/incomplete status and that failed speech never interrupts video.

Do not certify the app as production validated until these gates have been measured and their results recorded. There is no artificial 30-minute cutoff; 30 minutes is the required validation duration.
