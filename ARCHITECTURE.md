# Architecture

## Targets and isolation

`Teleprompter.xcodeproj` builds the macOS app from `App/`, linking the local `TeleprompterKit` Swift package. The package also contains deterministic tests and the `MediaProbe` executable. There are no remote packages.

The local `CaptureDeviceBridge` Objective-C target contains the camera configuration exception boundary. AVFoundation can raise Objective-C exceptions for rejected format or frame-duration assignments; those are converted to `NSError` before returning to Swift.

- **AppModel:** main-actor observable coordinator for preparation, countdown, recording, finalization, reading mode, draft persistence, and user-facing errors.
- **CaptureService:** one serial capture queue owns AVCaptureSession configuration, sample callbacks, and the active MovieRecorder. Preview is delivered by AVCaptureVideoPreviewLayer. Filesystem health polling uses a separate utility queue.
- **MovieRecorder:** receives original capture timestamps, encodes H.264/AAC, periodically writes MP4 fragments, and verifies the finalized asset before renaming it. Ownership transfers out of the capture queue only after sample delivery to that writer has ceased.
- **SpeechService:** actor managing model assets, AVAudioConverter, SpeechAnalyzer, recognition revisions, and cancellation. Bounded input streams isolate speech work from recording.
- **ScriptAligner:** pure Sendable value type; no microphone, filesystem, or UI dependencies.
- **LocalStore:** atomic, versioned local draft writes and security-scoped destination bookmarks. An unreadable draft is preserved before the user enables a replacement.

The two `@unchecked Sendable` media wrappers document their ownership rules. Retained CMSampleBuffers are immutable across the capture-to-speech handoff; the speech branch copies their PCM data. The converter-input box is private to a synchronous conversion callback. Mutable capture and writer objects are never concurrently accessed by their owning components.

## Data flow

```text
Camera ─────┐
            ├─ AVCaptureSession ─ video/audio callbacks ─ MovieRecorder ─ .partial.mp4
Microphone ─┘                                      │                         │
                                                   │                      verify + rename
                                                   │                         │
                                                   │                     completed.mp4
                                                   └─ bounded audio stream
                                                        │
                                                   copied + converted PCM
                                                        │
                                                   SpeechAnalyzer
                                                        │
                                                   SpeechEvent revisions
                                                        │
                                                   ScriptAligner
                                                        │
                                                   token index + status
                                                        │
                                                   AppKit reading panel
```

The recording branch retains the original audio/video timestamps. The speech branch counts converted output frames to provide a contiguous analyzer timeline: reusing source timestamps after resampling can introduce overlaps from rounding and converter buffering. A discontinuity over 250 ms causes voice following to pause and request a fresh synchronization.

No speech sample buffers are subscribed until the model is ready. Overflow finishes that speech stream and pauses following; it does not block capture or stop video recording. Manual seeking changes the alignment generation and restarts the speech stream so earlier hypotheses cannot move the new cursor.

## Alignment and presentation

The script stores original UTF-16 ranges and sentence IDs. Normalization expands common contractions and numeric spellings; source text remains untouched. A compact display representation collapses whitespace with a separate exact word-range mapping, so blank paragraphs do not consume the three visible reading lines.

The aligner replaces overlapping ASR intervals and rejects revisions older than finalized audio. It retains at most eight intervals, uses at most eight seconds of context and sixteen normalized words, and searches the previous two/next three sentences within 180 source tokens. Weighted edit alignment allows insertions, omissions, and substitutions. Short evidence is restricted to nearby words. Distant or backward movement requires a distinctive finalized multiword phrase or multiple evolving hypotheses; duplicate hypotheses cannot count as additional confirmation.

The panel is an AppKit nonactivating floating NSPanel with Spaces/full-screen auxiliary behavior. TextKit computes actual line bounds; scrolling keeps the matched word’s line nearest the camera. Animation respects Reduce Motion. Its location is derived from NSScreen safe-area and visible-frame geometry, with a reset when screen configuration changes.

`PrompterAura` confines its conic gradients and halo masks to separate Core Animation layers. An 18-second compositor animation rotates only the light, independently of text layout and media processing. Microphone levels change halo opacity through short interpolations. Hidden/inactive panels remove their continuous animations; Reduce Motion disables motion, and Reduce Transparency removes the halo and makes the reading surface opaque.

## Capture and lifecycle

Camera profiles preserve native dimensions and are sorted by pixel area, then frame rate. H.264 encoder availability is checked for each dimension set; recommended AVFoundation settings and writer capability checks validate the selected profile before capture-to-file begins. Common lower frame rates are offered as explicit alternatives. No profile changes occur during a take.

Each candidate retains its exact `CMTime` frame duration from discovery to configuration. Floating-point FPS is used for display and ranking, never to reconstruct camera timing. Lower choices use exact rational durations validated against every supported interval. Configuration locks the device, rechecks availability and timing, disables automatic frame rate when supported, and orders the minimum/maximum assignments so their intermediate range stays valid.

On macOS the session preset can overwrite an active format assigned before startup. The selected device format is therefore applied after `startRunning()`, followed by explicit native data-output dimensions and a final application of exact frame timing. AppModel owns one persistent preview layer; SwiftUI never reassigns its session on state changes, which could otherwise reset device timing. Readiness requires three consistent video buffers, recent microphone audio, and agreement between the active source dimensions/frame-rate limits, delivered dimensions, and selected profile. These checks run before the countdown and again before creating a writer. Waiting for samples suspends outside the capture queue.

Writer and disk failures use a separate event from capture-device failures. Stopping an unsuccessful take does not tear down a healthy camera preview. The recorder retains its first append error so finalization cannot overwrite a format/encoder error with a generic missing-frames message. Failed camera preparation does stop the capture session.

The file orientation is fixed at take start from the camera rotation coordinator. Preview mirroring does not mirror saved video. A camera dimension change or loss of audio causes orderly interruption, rather than silent output conversion or a silent take.

Recording phases are idle, preparing, countdown, recording, and finishing. Cancellation during preparation/countdown is checked across async boundaries. The prompter freezes during countdown and resumes after writing starts. Camera/format changes and editor mutations are disabled during a take. Quit waits for finalization; idle sleep is prevented while recording, and explicit sleep requests shutdown without auto-resuming after wake.

Disk checks reserve at least 512 MiB plus thirty seconds at the selected bitrate. MP4 fragments are requested after the first second and every ten seconds thereafter. Recovery validates tracks and uses passthrough export into a separate file. Recovery cannot guarantee data that the OS or storage device never flushed.

## Deliberate boundaries

English, Apple silicon, macOS 26+, SDR H.264/AAC, one camera and one microphone per take. No screen capture, HDR, automatic camera switching, video pause/resume, editing, cloud recognizer, third-party model fallback, or distribution/update service. Broader phrase jumps require manual navigation. Live human speech quality and long-duration hardware operation require the acceptance checks in VALIDATION.md.
