import AppKit
import AVFoundation
import TeleprompterKit

/// Explicit opt-in hardware check. Uses fixture text and a private temporary folder;
/// never loads or changes the user's draft, settings, or destination bookmark.
@MainActor enum CaptureCheck {
    static func run(model: AppModel) async {
        setbuf(stdout, nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TeleprompterCaptureCheck-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            model.recordingFolder = folder
            model.settings.mode = CommandLine.arguments.contains("--with-speech") ? .speech : .manual
            print("PERMISSIONS: camera=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            print("CHECK: Preparing camera; diagnostic takes remain local at \(folder.path)")
            guard await model.prepareCamera() else {
                throw TeleprompterError.message(model.notice ?? "Camera preparation failed.")
            }
            try await Task.sleep(for: .seconds(2))
            print("PREVIEW: \(try await model.capture.diagnosticSnapshot())")
            model.toggleRecording()
            let deadline = Date().addingTimeInterval(45)
            var started: Date?
            var lastState = ""
            while Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
                let state = "\(model.phase) notice=\(model.notice ?? "none")"
                if state != lastState { print("STATE: \(state)"); lastState = state }
                if model.phase == .recording {
                    if started == nil { started = Date(); print("RECORDING: \(try await model.capture.diagnosticSnapshot())") }
                    if let started, Date().timeIntervalSince(started) >= 6 {
                        await model.stopRecording()
                        break
                    }
                } else if model.phase == .idle { break }
            }
            if model.phase == .recording { await model.stopRecording() }
            print("FINAL: \(try await model.capture.diagnosticSnapshot())")
            guard let take = model.lastTake else { throw TeleprompterError.message(model.notice ?? "No take completed.") }
            let media = try await MovieRecorder.inspect(take)
            print("PASS: \(media.width)x\(media.height), \(media.fps) fps, \(media.duration)s, \(model.droppedFrames) dropped, A/V skew \(media.startSkew)s / \(media.endSkew)s")
            print("TAKE: \(take.path)")
            await model.shutdown()
            exit(0)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            await model.shutdown()
            exit(1)
        }
    }
}
