# Changelog

## 1.0.2 — Release candidate

- Preserve native camera dimensions and frame timing through preview, countdown, and recording startup.
- Require fresh video and microphone samples before starting a take, and retain the original writer error when recording fails.
- Keep a healthy preview running after a recording error.
- Add a voice-responsive multicolor perimeter to the floating prompter, with reduced-motion and reduced-transparency support.
- Add portable signing configuration, continuous integration, reproducible screenshots, and a documented notarized release process.

## 1.0.1

- Preserve exact rational camera frame durations and validate timing before configuring AVFoundation.
- Convert native camera-configuration exceptions into recoverable application errors.

## 1.0.0

- Add native script editing, local drafts, and a floating prompter with speech, fixed-speed, and manual reading modes.
- Add on-device English speech tracking and nearby sentence recovery.
- Add camera and microphone selection, H.264/AAC MP4 recording, countdown, and interrupted-take recovery.

See [VALIDATION.md](VALIDATION.md) for measured results and remaining acceptance gates. These entries describe development versions; they do not imply public binary releases.
